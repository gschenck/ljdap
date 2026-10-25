"""ljdap-Adapter für das Sublime-Text-Paket „Debugger“ (daveleroy).

Verbindet den Debugger per TCP mit ljdap im Lua-Programm; ljdap ist selbst
der DAP-Server.
  attach  verbindet sich mit einem laufenden Programm (LJDAP=… / -l ljdap)
  launch  startet `lua ljdap.lua --port P skript.lua args…` selbst (Starter-
          Modus) und leitet stdout/stderr in die Debugger-Konsole; ljdap.lua
          liegt im Paket (Release) oder wird über das Feld "ljdap" angegeben

Installation: Ordner editors/sublime als Packages/ljdap/ kopieren
(Preferences → Browse Packages…). Die Datei .python-version muss mit:
das Debugger-Paket läuft im Python-3.8-Plugin-Host, und Plugins in
verschiedenen Hosts sehen sich nicht.

Konfiguration im .sublime-project:

    "debugger_configurations": [
        { "name": "ljdap", "type": "ljdap", "request": "attach",
          "host": "127.0.0.1", "port": 4711 },
        { "name": "Skript", "type": "ljdap", "request": "launch",
          "program": "${file}", "lua": "luajit" }
    ]

Registrierung erst in plugin_loaded(): Das Debugger-Paket löscht beim
(Neu-)Laden seine Untermodule aus sys.modules; ein früher registrierter
Adapter ginge dabei verloren.
"""

import os
import socket

import sublime

VERSION = "0.1.0-dev"
DOCS = "https://github.com/gschenck/ljdap"

SNIPPETS = [
    {
        "label": "ljdap: Lua-Skript starten",
        "body": {
            "name": "ljdap: Skript",
            "type": "ljdap",
            "request": "launch",
            "program": "${file}",
            "lua": "luajit",
        },
    },
    {
        "label": "ljdap: an Lua-Programm anhängen",
        "body": {
            "name": "ljdap",
            "type": "ljdap",
            "request": "attach",
            "host": "127.0.0.1",
            "port": 4711,
        },
    },
]

SCHEMA = {
    "launch": {
        "properties": {
            "program": {"type": "string", "description": "Lua-Skript, z. B. ${file}"},
            "args": {"type": "array", "items": {"type": "string"}, "description": "Argumente des Skripts"},
            "cwd": {"type": "string", "description": "Arbeitsverzeichnis (Vorgabe: Projektordner)"},
            "lua": {"type": "string", "default": "luajit", "description": "Interpreter (luajit, lua5.1, Pfad)"},
            "env": {"type": "object", "description": "zusätzliche Umgebungsvariablen"},
            "port": {"type": "number", "description": "TCP-Port (Vorgabe: frei gewählt)"},
            "ljdap": {"type": "string", "description": "Pfad zu ljdap.lua (Vorgabe: aus dem Paket)"},
            "stopOnEntry": {"type": "boolean", "default": False, "description": "an der ersten Zeile anhalten"},
            "timeout": {"type": "number", "default": 5},
        },
        "required": ["program"],
    },
    "attach": {
        "properties": {
            "host": {"type": "string", "default": "127.0.0.1",
                     "description": "Adresse, an der ljdap im Programm lauscht"},
            "port": {"type": "number", "default": 4711,
                     "description": "Port von ljdap (LJDAP=\"port=…\")"},
            "timeout": {"type": "number", "default": 5,
                        "description": "Sekunden, die auf die Verbindung gewartet wird"},
            "stopOnEntry": {"type": "boolean", "default": False,
                            "description": "Mit wait=1: an der ersten Zeile anhalten"},
            "pathMappings": {
                "type": "array",
                "description": "Pfadzuordnung Editor ↔ Programm (z. B. Programm auf einem Server)",
                "items": {
                    "type": "object",
                    "properties": {
                        "localRoot": {"type": "string"},
                        "remoteRoot": {"type": "string"},
                    },
                },
            },
        },
    },
}

_registered = []


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def bundled_ljdap():
    """ljdap.lua aus dem Paket in den Cache schreiben (Pakete sind oft Zip-Dateien)."""
    try:
        data = sublime.load_binary_resource("Packages/ljdap/ljdap.lua")
    except Exception:
        data = None
    if not data:
        raise Exception("ljdap.lua nicht im Paket gefunden – Feld \"ljdap\" in der Konfiguration "
                        "auf den Pfad von ljdap.lua setzen")
    d = os.path.join(sublime.cache_path(), "ljdap")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "ljdap.lua")
    try:
        with open(path, "rb") as f:
            same = f.read() == data
    except OSError:
        same = False
    if not same:
        with open(path, "wb") as f:
            f.write(data)
    return path


def launch_command(configuration, ljdap_path, port):
    """Befehlszeile für den Starter-Modus."""
    lua = configuration.get("lua") or "luajit"
    program = configuration.get("program")
    if not program:
        raise Exception("launch: Feld \"program\" fehlt")
    cmd = [lua, ljdap_path, "--port", str(port)]
    if configuration.get("log"):
        cmd += ["--log", configuration.get("log")]
    cmd += [program] + [str(a) for a in (configuration.get("args") or [])]
    return cmd


def _register(dap):
    """Erzeugt und registriert die Adapterklasse (Metaklasse des Debuggers)."""

    class LjdapInstaller(dap.AdapterInstaller):
        type = "ljdap"

        def installed_version(self):
            return VERSION

        async def installable_versions(self, log):
            return []

        def configuration_snippets(self, schema_type=None):
            return SNIPPETS

        def configuration_schema(self, schema_type=None):
            return SCHEMA

    class Ljdap(dap.Adapter):
        type = "ljdap"
        docs = DOCS
        installer = LjdapInstaller()

        async def start(self, console, configuration):
            timeout = int(configuration.get("timeout") or 5)
            request = getattr(configuration, "request", None) or configuration.get("request")
            if request == "launch":
                port = int(configuration.get("port") or free_port())
                ljdap_path = configuration.get("ljdap") or bundled_ljdap()
                command = launch_command(configuration, ljdap_path, port)
                env = None
                if configuration.get("env"):
                    env = dict(os.environ)
                    env.update({str(k): str(v) for k, v in configuration.get("env").items()})

                def stdout(data):
                    console.log("stdout", data)

                def stderr(data):
                    console.log("stderr", data)

                return dap.SocketTransport(host="127.0.0.1", port=port, timeout=timeout,
                                           command=command, cwd=configuration.get("cwd") or None,
                                           env=env, stdout=stdout, stderr=stderr)
            host = configuration.get("host") or "127.0.0.1"
            port = int(configuration.get("port") or 4711)
            return dap.SocketTransport(host=host, port=port, timeout=timeout)

    return Ljdap


def plugin_loaded():
    try:
        from Debugger.modules import dap
    except ImportError as e:
        print("ljdap: Paket „Debugger“ nicht gefunden oder anderer Plugin-Host:", e)
        return
    _registered.append(_register(dap))
    print("ljdap: Adapter „ljdap“ registriert (" + VERSION + ")")
