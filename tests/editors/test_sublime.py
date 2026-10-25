"""Tests für editors/sublime/ljdap_adapter.py.

1. Mit nachgebildetem Debugger-Paket: Registrierung, Vorlagen, Transport.
2. Gegen den echten Quelltext des Debugger-Pakets (Umgebungsvariable
   SUBLIME_DEBUGGER_SRC = Klon von github.com/daveleroy/SublimeDebugger):
   prüft, dass die genutzte interne API noch existiert (Konzept 13).
"""

import ast
import asyncio
import importlib.util
import os
import sys
import types
import unittest
from dataclasses import dataclass

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PLUGIN = os.path.join(ROOT, "editors", "sublime", "ljdap_adapter.py")


def make_fake_debugger():
    registry = {}

    class Registry(type):
        def __new__(mcs, name, bases, dct):
            cls = type.__new__(mcs, name, bases, dct)
            if bases:
                inst = cls()
                registry[inst.type] = inst
            return cls

    class Adapter(metaclass=Registry):
        type = None

    class AdapterInstaller:
        def installed_version(self):
            return "1.0.0"

    @dataclass
    class SocketTransport:
        host: str = "localhost"
        port: int = 0
        timeout: int = 5

    dap = types.ModuleType("Debugger.modules.dap")
    dap.Adapter, dap.AdapterInstaller, dap.SocketTransport = Adapter, AdapterInstaller, SocketTransport
    pkg = types.ModuleType("Debugger")
    mods = types.ModuleType("Debugger.modules")
    mods.dap = dap
    pkg.modules = mods
    return {"Debugger": pkg, "Debugger.modules": mods, "Debugger.modules.dap": dap}, registry


def load_plugin():
    spec = importlib.util.spec_from_file_location("ljdap_adapter_test", PLUGIN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class SublimePlugin(unittest.TestCase):

    def setUp(self):
        self.saved = dict(sys.modules)
        sys.modules["sublime"] = types.ModuleType("sublime")

    def tearDown(self):
        sys.modules.clear()
        sys.modules.update(self.saved)

    def test_registers_adapter(self):
        fake, registry = make_fake_debugger()
        sys.modules.update(fake)
        mod = load_plugin()
        self.assertEqual(registry, {}, "beim Import noch nicht registriert")
        mod.plugin_loaded()
        self.assertIn("ljdap", registry)
        ad = registry["ljdap"]
        self.assertEqual(ad.installer.installed_version(), mod.VERSION)
        snip = ad.installer.configuration_snippets()
        self.assertEqual(snip[0]["body"]["type"], "ljdap")
        self.assertEqual(snip[0]["body"]["request"], "attach")
        self.assertIn("attach", ad.installer.configuration_schema())
        t = asyncio.run(ad.start(None, {"port": "5000"}))
        self.assertEqual((t.host, t.port, t.timeout), ("127.0.0.1", 5000, 5))
        t = asyncio.run(ad.start(None, {"host": "10.0.0.2", "port": 4712, "timeout": 9}))
        self.assertEqual((t.host, t.port, t.timeout), ("10.0.0.2", 4712, 9))

    def test_without_debugger_package(self):
        mod = load_plugin()
        sys.modules.pop("Debugger", None)
        mod.plugin_loaded()  # darf nicht werfen
        self.assertEqual(mod._registered, [])

    def test_version_matches_lua(self):
        with open(os.path.join(ROOT, "src", "ljdap", "version.lua"), encoding="utf-8") as f:
            lua_version = f.read().split('"')[1]
        self.assertEqual(load_plugin().VERSION, lua_version)

    def test_python_version_file(self):
        with open(os.path.join(ROOT, "editors", "sublime", ".python-version")) as f:
            self.assertEqual(f.read().strip(), "3.8")


@unittest.skipUnless(os.environ.get("SUBLIME_DEBUGGER_SRC"), "SUBLIME_DEBUGGER_SRC nicht gesetzt")
class RealDebuggerApi(unittest.TestCase):
    """Prüft die im Plugin genutzte interne API am echten Quelltext."""

    src = os.environ.get("SUBLIME_DEBUGGER_SRC", "")

    def parse(self, rel):
        with open(os.path.join(self.src, rel), encoding="utf-8") as f:
            return ast.parse(f.read())

    def test_dap_exports(self):
        names = set()
        for node in ast.walk(self.parse("modules/dap/__init__.py")):
            if isinstance(node, ast.ImportFrom):
                for a in node.names:
                    names.add(a.asname or a.name)
        for n in ("Adapter", "AdapterInstaller", "SocketTransport"):
            self.assertIn(n, names, f"dap.{n} fehlt im Debugger-Paket")

    def test_socket_transport_fields(self):
        tree = self.parse("modules/dap/transports.py")
        cls = next(n for n in ast.walk(tree) if isinstance(n, ast.ClassDef) and n.name == "SocketTransport")
        fields = {n.target.id for n in cls.body if isinstance(n, ast.AnnAssign)}
        self.assertTrue({"host", "port", "timeout"} <= fields, fields)

    def test_installer_methods(self):
        tree = self.parse("modules/dap/adapter_installer.py")
        cls = next(n for n in ast.walk(tree) if isinstance(n, ast.ClassDef) and n.name == "AdapterInstaller")
        meths = {n.name for n in cls.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
        for m in ("installed_version", "installable_versions", "configuration_snippets", "configuration_schema"):
            self.assertIn(m, meths)

    def test_adapter_registry_and_start(self):
        tree = self.parse("modules/dap/adapter.py")
        cls = next(n for n in ast.walk(tree) if isinstance(n, ast.ClassDef) and n.name == "Adapter")
        self.assertTrue(any(getattr(k.value, "id", None) == "AdapterRegistery" for k in cls.keywords),
                        "Adapter nutzt keine Registrier-Metaklasse mehr")
        meths = {n.name for n in cls.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
        self.assertIn("start", meths)

    def test_python_host(self):
        with open(os.path.join(self.src, ".python-version")) as f:
            self.assertEqual(f.read().strip(), "3.8", "Debugger-Paket wechselt den Plugin-Host")


if __name__ == "__main__":
    unittest.main()
