"""M1-Szenarien: Verbindung, Initialisierung, Anhängen, Trennen.

Aufruf aus dem Repo-Wurzelverzeichnis:
    python3 -m unittest discover -s tests/scenarios -v
Interpreter über LJDAP_INTERPS (durch ';' getrennt), Vorgabe "luajit;lua5.1".
Beispiel Windows unter Wine:
    LJDAP_INTERPS="wine /pfad/luajit.exe" python3 -m unittest …
"""

import os
import shlex
import socket
import subprocess
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from harness import (ROOT, INTERPS, DEV_PATH, Program, attach_args,  # noqa: E402
                     DapError)


def handshake(t, c, nulls, interp="luajit"):
    """initialize … configurationDone wie ein Editor; liefert die Capabilities."""
    r = c.request("initialize", {"clientID": "test", "adapterID": "ljdap", "linesStartAt1": True,
                                 "columnsStartAt1": True, "pathFormat": "path"},
                  nulls=["locale", "supportsVariableType"] if nulls else None)
    caps = r["body"]
    t.assertTrue(caps.get("supportsConfigurationDoneRequest"))
    t.assertEqual([f["filter"] for f in caps.get("exceptionBreakpointFilters")], ["uncaught", "raised"])
    c.event("initialized")
    c.request("attach", attach_args(interp), nulls=["__restart", "host"] if nulls else None)
    out = c.event("output")["body"]["output"]
    t.assertIn("ljdap 0.1.0-dev", out)
    bp = {"line": 3}
    if nulls:
        bp.update(condition=None, hitCondition=None, logMessage=None)
    # Datei existiert nicht: Antwort unverified, das Programm hält nicht an
    r = c.request("setBreakpoints", {"source": {"path": os.path.join(ROOT, "tests/fixtures/fehlt.lua")},
                                     "breakpoints": [bp], "lines": [3]},
                  nulls=["sourceModified"] if nulls else None)
    bps = r["body"]["breakpoints"]
    t.assertEqual(len(bps), 1)
    t.assertFalse(bps[0]["verified"])
    t.assertEqual(bps[0]["line"], 3)
    c.request("setExceptionBreakpoints", {"filters": []}, nulls=["filterOptions"] if nulls else None)
    c.request("configurationDone")
    return caps


class M1(unittest.TestCase):

    def test_wait_blocks_until_configuration_done(self):
        for interp in INTERPS:
            with self.subTest(interp=interp):
                for nulls in (False, True):
                    with self.subTest(nulls=nulls):
                        prog = Program(interp, "port={port},wait=1", args=["0"])
                        try:
                            c = prog.client(null_fields=nulls)
                            time.sleep(0.3)
                            self.assertIsNone(prog.p.poll(), "Programm darf vor configurationDone nicht enden")
                            handshake(self, c, nulls, interp)
                            code, out, err = prog.finish()
                            self.assertEqual(code, 0, err)
                            self.assertEqual(out.replace("\r", ""), "fixture: start\nfixture: ende true\n")
                            self.assertIn("warte auf DAP-Client", err)
                            self.assertTrue(c.closed_by_server(), "Programmende schließt die Verbindung")
                            c.close()
                        finally:
                            prog.kill()

    def test_requests_while_running_and_reconnect(self):
        for interp in INTERPS:
            with self.subTest(interp=interp):
                prog = Program(interp, "port={port},wait=1", args=["4", "poll"])
                try:
                    c = prog.client()
                    handshake(self, c, False, interp)
                    # Programm rechnet jetzt; Abfrage per Count-Hook (JIT bei Client aus).
                    # Nach dem Trennen ist der JIT wieder an: der zweite Client
                    # wird über ljdap.poll() in der Schleife angenommen.
                    r = c.request("threads", timeout=5)
                    self.assertEqual(r["body"]["threads"], [{"id": 1, "name": "main"}])
                    c.request("disconnect", {"terminateDebuggee": False})
                    self.assertTrue(c.closed_by_server(), "disconnect schließt die Verbindung")
                    c.close()
                    # zweiter Client verbindet sich, während das Programm weiterläuft
                    c2 = prog.client(timeout=5)
                    r = c2.request("initialize", {"adapterID": "ljdap"}, timeout=5)
                    self.assertTrue(r["body"]["supportsConfigurationDoneRequest"])
                    c2.request("disconnect", {})
                    c2.close()
                    code, out, err = prog.finish()
                    self.assertEqual(code, 0, err)
                    self.assertIn("fixture: ende true", out)
                finally:
                    prog.kill()

    def test_late_attach_with_poll_and_jit_off(self):
        # wait=0: Client verbindet sich später. Unter LuaJIT mit JIT braucht
        # das ljdap.poll() in der Schleife oder jit=off (Konzept 6).
        for interp in INTERPS:
            with self.subTest(interp=interp):
                for env, args in (("port={port},wait=0", ["3", "poll"]),
                                  ("port={port},wait=0,jit=off", ["3"])):
                    with self.subTest(env=env):
                        prog = Program(interp, env, args=args)
                        try:
                            time.sleep(0.5)
                            c = prog.client(timeout=5)
                            handshake(self, c, True, interp)
                            c.request("disconnect", {})
                            c.close()
                            code, out, err = prog.finish()
                            self.assertEqual(code, 0, err)
                            self.assertIn("fixture: ende true", out)
                        finally:
                            prog.kill()

    def test_bad_input_and_unknown_command(self):
        for interp in INTERPS:
            with self.subTest(interp=interp):
                prog = Program(interp, "port={port},wait=1", args=["0"])
                try:
                    c = prog.client()
                    c.send_raw(b"Content-Length: 5\r\n\r\n{nope")
                    ev = c.event("output")
                    self.assertEqual(ev["body"]["category"], "stderr")
                    self.assertIn("ungültiges JSON", ev["body"]["output"])
                    # Teilpakete: Kopf und Body in Stücken
                    body = b'{"seq":1,"type":"request","command":"gibtsnicht","arguments":{}}'
                    data = b"Content-Length: %d\r\n\r\n" % len(body) + body
                    for i in range(0, len(data), 7):
                        c.send_raw(data[i:i + 7])
                        time.sleep(0.01)
                    r = c.response(1, ok=False)
                    self.assertFalse(r["success"])
                    self.assertIn("nicht unterstützt", r["message"])
                    c.seq = 1
                    handshake(self, c, False, interp)
                    code, out, err = prog.finish()
                    self.assertEqual(code, 0, err)
                finally:
                    prog.kill()

    def test_configuration_done_and_disconnect_in_one_packet(self):
        # Regression: disconnect im selben Lesedurchgang wie configurationDone
        # ließ start{wait=true} für immer warten (unter Wine gefunden).
        for interp in INTERPS:
            with self.subTest(interp=interp):
                prog = Program(interp, "port={port},wait=1", args=["0"])
                try:
                    c = prog.client()
                    c.request("initialize", {"adapterID": "ljdap"})
                    c.request("attach", {})
                    data = b""
                    for seq, cmd in ((10, "configurationDone"), (11, "disconnect")):
                        body = b'{"seq":%d,"type":"request","command":"%s","arguments":{}}' % (seq, cmd.encode())
                        data += b"Content-Length: %d\r\n\r\n" % len(body) + body
                    c.send_raw(data)
                    c.response(10)
                    c.response(11)
                    code, out, err = prog.finish(timeout=20)
                    self.assertEqual(code, 0, err)
                    self.assertIn("fixture: ende true", out)
                finally:
                    prog.kill()

    def test_port_in_use_program_runs_without_debugger(self):
        for interp in INTERPS:
            with self.subTest(interp=interp):
                blocker = socket.socket()
                blocker.bind(("127.0.0.1", 0))
                blocker.listen(1)
                port = blocker.getsockname()[1]
                try:
                    prog = Program(interp, f"port={port},wait=1", args=["0"])
                    code, out, err = prog.finish()
                    self.assertEqual(code, 0, err)
                    self.assertIn("fixture: ende true", out)
                    self.assertIn("Start fehlgeschlagen", err)
                    self.assertIn("ohne Debugger", err)
                finally:
                    blocker.close()

    def test_require_without_env_does_not_start(self):
        for interp in INTERPS:
            with self.subTest(interp=interp):
                env = dict(os.environ, WINEDEBUG="-all")
                env.pop("LJDAP", None)
                code = ("package.path='src/?.lua;src/?/init.lua;'..package.path "
                        "local d = require('ljdap') io.write(d.state(), ' ', d.VERSION)")
                p = subprocess.run(shlex.split(interp) + ["-e", code], cwd=ROOT, env=env,
                                   capture_output=True, timeout=30)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(p.stdout.decode(), "idle 0.1.0-dev")

    def test_stdio_transport(self):
        for interp in INTERPS:
            with self.subTest(interp=interp):
                env = dict(os.environ, WINEDEBUG="-all", LJDAP="backend=stdio")
                cmd = shlex.split(interp) + ["-e", DEV_PATH, "-l", "ljdap", "tests/fixtures/quiet.lua"]
                p = subprocess.Popen(cmd, cwd=ROOT, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)

                def req(seq, command, args=None):
                    body = ('{"seq":%d,"type":"request","command":"%s","arguments":%s}'
                            % (seq, command, args or "{}")).encode()
                    p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)

                req(1, "initialize", '{"adapterID":"ljdap"}')
                req(2, "attach")
                req(3, "configurationDone")
                p.stdin.close()
                out = p.stdout.read()
                p.wait(timeout=30)
                self.assertEqual(p.returncode, 0, p.stderr.read())
                self.assertIn(b'"command":"initialize"', out)
                self.assertIn(b'"event":"initialized"', out)
                self.assertIn(b'"command":"configurationDone"', out)
                # Rahmen unverfälscht (Windows: Binärmodus, kein \r\r\n)
                self.assertNotIn(b"\r\r\n", out)
                self.assertTrue(out.startswith(b"Content-Length: "), out[:40])
                p.stderr.close()
                p.stdout.close()


if __name__ == "__main__":
    unittest.main()
