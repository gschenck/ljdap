"""Gemeinsame Teile der Szenariotests (Programmstart, Pfade, Interpreter)."""

import os
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from dap_client import DapClient, DapError, free_port  # noqa: E402,F401

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
INTERPS = [s.strip() for s in os.environ.get("LJDAP_INTERPS", "luajit;lua5.1").split(";") if s.strip()]
# LJDAP_SINGLE=1: gegen die Ein-Datei-Version ljdap.lua im Wurzelverzeichnis
# testen statt gegen die Module in src/
if os.environ.get("LJDAP_SINGLE"):
    DEV_PATH = "package.path='./?.lua;'..package.path"
else:
    DEV_PATH = "package.path='src/?.lua;src/?/init.lua;'..package.path"
DEBUG = os.environ.get("LJDAP_TEST_LOG")


def is_wine(interp):
    return shlex.split(interp)[0].endswith("wine") or shlex.split(interp)[0].endswith("wine64")


def is_luajit(interp):
    return "luajit" in interp


def fixture(name):
    """Pfad einer Fixture-Datei, wie ein Editor auf diesem Rechner ihn sendet."""
    return os.path.join(ROOT, "tests", "fixtures", name)


def attach_args(interp, **extra):
    """attach-Argumente; unter Wine mit pathMappings Linux-Editor ↔ Z:-Laufwerk."""
    args = {"name": "ljdap"}
    if is_wine(interp):
        args["pathMappings"] = [{"localRoot": ROOT, "remoteRoot": "Z:" + ROOT.replace("/", "\\")}]
    args.update(extra)
    return args


class Program:
    """Startet ein Fixture mit -l ljdap und den Optionen in LJDAP."""

    def __init__(self, interp, ljdap_env, fixture="count.lua", args=(), dash_l=True):
        self.port = free_port()
        env = dict(os.environ, WINEDEBUG="-all")
        env["LJDAP"] = ljdap_env.format(port=self.port)
        cmd = shlex.split(interp) + ["-e", DEV_PATH]
        if dash_l:
            cmd += ["-l", "ljdap"]
        cmd += ["tests/fixtures/" + fixture] + list(args)
        self.p = subprocess.Popen(cmd, cwd=ROOT, env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def client(self, null_fields=False, timeout=10):
        log = (lambda s: print("   ", s[:300], file=sys.stderr)) if DEBUG else None
        return DapClient.connect("127.0.0.1", self.port, timeout=timeout,
                                 null_fields=null_fields, log=log)

    def finish(self, timeout=30):
        out, err = self.p.communicate(timeout=timeout)
        return self.p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")

    def kill(self):
        if self.p.poll() is None:
            self.p.kill()
            self.p.communicate()
