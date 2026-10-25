"""M4-Szenarien: Starter-Modus (lua ljdap.lua … skript.lua), launch,
terminate, exited-Event.

Der Starter-Modus braucht die Ein-Datei-Version ljdap.lua (Wurzelverzeichnis).
"""

import os
import shlex
import subprocess
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from harness import ROOT, INTERPS, DapClient, free_port, attach_args, fixture, is_wine  # noqa: E402

STEPS = fixture("steps.lua")


class Starter:
    def __init__(self, interp, script, args=(), opts=()):
        self.port = free_port()
        env = dict(os.environ, WINEDEBUG="-all")
        env.pop("LJDAP", None)
        cmd = shlex.split(interp) + ["ljdap.lua", "--port", str(self.port)] + list(opts) \
            + ["tests/fixtures/" + script] + list(args)
        self.p = subprocess.Popen(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.c = DapClient.connect("127.0.0.1", self.port, timeout=15)

    def launch(self, interp, bps=None, exc=(), **extra):
        c = self.c
        c.request("initialize", {"adapterID": "ljdap"})
        c.event("initialized")
        c.request("launch", attach_args(interp, **extra))
        for path, lines in (bps or {}).items():
            c.request("setBreakpoints", {"source": {"path": path}, "breakpoints": [{"line": n} for n in lines]})
        c.request("setExceptionBreakpoints", {"filters": list(exc)})
        c.request("configurationDone")

    def finish(self, timeout=30):
        out, err = self.p.communicate(timeout=timeout)
        return self.p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")

    def close(self):
        self.c.close()
        if self.p.poll() is None:
            self.p.kill()
            self.p.communicate()


class M4(unittest.TestCase):

    def run_each(self, fn):
        for interp in INTERPS:
            with self.subTest(interp=interp):
                fn(interp)

    def test_cli_version_and_help(self):
        def body(interp):
            env = dict(os.environ, WINEDEBUG="-all")
            r = subprocess.run(shlex.split(interp) + ["ljdap.lua", "--version"], cwd=ROOT, env=env,
                               capture_output=True, timeout=30)
            self.assertEqual(r.returncode, 0)
            self.assertRegex(r.stdout.decode(), r"^ljdap \d+\.\d+\.\d+")
            r = subprocess.run(shlex.split(interp) + ["ljdap.lua"], cwd=ROOT, env=env,
                               capture_output=True, timeout=30)
            self.assertEqual(r.returncode, 2)
            self.assertIn("kein Skript", r.stderr.decode())
            r = subprocess.run(shlex.split(interp) + ["ljdap.lua", "--gibtsnicht", "x.lua"], cwd=ROOT,
                               env=env, capture_output=True, timeout=30)
            self.assertEqual(r.returncode, 2)
        self.run_each(body)

    def test_launch_breakpoint_and_exit_event(self):
        def body(interp):
            s = Starter(interp, "steps.lua")
            try:
                time.sleep(0.3)
                self.assertIsNone(s.p.poll(), "wartet auf den Editor")
                s.launch(interp, {STEPS: [13]})
                ev = s.c.event("stopped")["body"]
                self.assertEqual(ev["reason"], "breakpoint")
                f = s.c.request("stackTrace", {"threadId": 1})["body"]["stackFrames"][0]
                self.assertEqual((f["name"], f["line"], f["source"]["path"]), ("rechne", 13, STEPS))
                s.c.request("continue", {"threadId": 1})
                ex = s.c.event("exited")["body"]
                self.assertEqual(ex["exitCode"], 0)
                s.c.event("terminated")
                code, out, err = s.finish()
                self.assertEqual(code, 0, err)
                self.assertIn("steps: 16 Punkt 42", out)
            finally:
                s.close()
        self.run_each(body)

    def test_launch_args_like_interpreter(self):
        def body(interp):
            s = Starter(interp, "args.lua", args=["a", "b"])
            try:
                s.launch(interp)
                code, out, err = s.finish()
                self.assertEqual(code, 0, err)
                self.assertIn("args: args.lua 2 a,b a b", out)
            finally:
                s.close()
        self.run_each(body)

    def test_launch_uncaught_error_both_interpreters(self):
        # im Starter-Modus läuft das Skript unter xpcall: Halt auch unter Lua 5.1
        def body(interp):
            s = Starter(interp, "fehler.lua", args=["uncaught"])
            try:
                s.launch(interp, exc=["uncaught"])
                ev = s.c.event("stopped")["body"]
                self.assertEqual(ev["reason"], "exception")
                f = s.c.request("stackTrace", {"threadId": 1})["body"]["stackFrames"]
                self.assertEqual((f[0]["name"], f[0]["line"]), ("rechne", 12))
                self.assertEqual(len(f), 2, "keine Agentenrahmen")
                s.c.request("continue", {"threadId": 1})
                self.assertEqual(s.c.event("exited")["body"]["exitCode"], 1)
                code, out, err = s.finish()
                self.assertEqual(code, 1)
                self.assertIn("fehler.lua:12: in function 'rechne'", err)
                self.assertNotIn("ljdap", err.split("stack traceback:")[1], "Traceback ohne Agentenzeilen")
            finally:
                s.close()
        self.run_each(body)

    def test_launch_disconnect_terminates(self):
        def body(interp):
            s = Starter(interp, "count.lua", args=["20"])
            try:
                s.launch(interp)
                time.sleep(0.5)
                t0 = time.monotonic()
                s.c.request("disconnect", {})
                code, out, err = s.finish(timeout=15)
                self.assertLess(time.monotonic() - t0, 10, "Programm endet beim Trennen")
                self.assertNotEqual(code, 0)
                self.assertNotIn("fixture: ende", out)
            finally:
                s.close()
        self.run_each(body)

    def test_launch_disconnect_keep_running(self):
        def body(interp):
            s = Starter(interp, "count.lua", args=["1"])
            try:
                s.launch(interp)
                s.c.request("disconnect", {"terminateDebuggee": False})
                code, out, err = s.finish()
                self.assertEqual(code, 0, err)
                self.assertIn("fixture: ende true", out)
            finally:
                s.close()
        self.run_each(body)

    def test_terminate_request(self):
        def body(interp):
            s = Starter(interp, "count.lua", args=["20"])
            try:
                s.launch(interp, {STEPS: []})
                time.sleep(0.5)
                s.c.request("terminate", {})
                s.c.event("terminated")
                code, out, err = s.finish(timeout=15)
                self.assertNotEqual(code, 0)
            finally:
                s.close()
        self.run_each(body)

    def test_attach_with_dash_l_sends_exited(self):
        # -l ljdap: LuaJIT übernimmt das Skript (exited-Event); Lua 5.1 nicht
        def body(interp):
            from harness import Program
            prog = Program(interp, "port={port},wait=1", fixture="count.lua", args=["0"])
            try:
                c = prog.client()
                c.request("initialize", {"adapterID": "ljdap"})
                c.request("attach", attach_args(interp))
                c.request("configurationDone")
                if "luajit" in interp:
                    self.assertEqual(c.event("exited")["body"]["exitCode"], 0)
                code, out, err = prog.finish()
                self.assertEqual(code, 0, err)
                c.close()
            finally:
                prog.kill()
        self.run_each(body)


if __name__ == "__main__":
    unittest.main()
