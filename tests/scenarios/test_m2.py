"""M2-Szenarien: Haltepunkte, Stepping, Stack, Scopes, Variablen.

Zeilennummern beziehen sich auf tests/fixtures/steps.lua.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from harness import INTERPS, Program, attach_args, fixture, is_luajit  # noqa: E402

STEPS = fixture("steps.lua")


class Session:
    """Ein Fixture unter dem Debugger mit fertigem Handshake."""

    def __init__(self, t, interp, bps, fixture_name="steps.lua", args=(), nulls=False,
                 lines1=True, attach_extra=None, env="port={port},wait=1", exc=(), bp_extra=None):
        self.t = t
        self.prog = Program(interp, env, fixture=fixture_name, args=args)
        self.c = c = self.prog.client(null_fields=nulls)
        c.request("initialize", {"adapterID": "ljdap", "linesStartAt1": lines1, "columnsStartAt1": lines1},
                  nulls=["locale"] if nulls else None)
        c.event("initialized")
        c.request("attach", attach_args(interp, **(attach_extra or {})))
        self.bp_results = {}
        for path, lines in bps.items():
            items = []
            for ln in lines:
                b = {"line": ln}
                b.update((bp_extra or {}).get(ln, {}))
                if nulls:
                    b.update(condition=None, hitCondition=None, logMessage=None)
                items.append(b)
            r = c.request("setBreakpoints", {"source": {"path": path}, "breakpoints": items},
                          nulls=["sourceModified"] if nulls else None)
            self.bp_results[path] = r["body"]["breakpoints"]
        c.request("setExceptionBreakpoints", {"filters": list(exc)})
        c.request("configurationDone")

    def stopped(self, reason=None, timeout=10, thread=1):
        ev = self.c.event("stopped", timeout=timeout)["body"]
        if reason:
            self.t.assertEqual(ev["reason"], reason, ev)
        if thread is not None:
            self.t.assertEqual(ev["threadId"], thread)
        return ev

    def frames(self):
        return self.c.request("stackTrace", {"threadId": 1, "startFrame": 0, "levels": 20})["body"]

    def top(self):
        f = self.frames()["stackFrames"][0]
        return f["name"], f["line"]

    def scopes(self, frame_id=1):
        return {s["name"]: s for s in
                self.c.request("scopes", {"frameId": frame_id})["body"]["scopes"]}

    def variables(self, ref, **kw):
        args = {"variablesReference": ref}
        args.update(kw)
        return self.c.request("variables", args)["body"]["variables"]

    def locals(self, frame_id=1):
        return {v["name"]: v for v in self.variables(self.scopes(frame_id)["Lokal"]["variablesReference"])}

    def step(self, cmd, reason="step"):
        r = self.c.request(cmd, {"threadId": 1})
        self.t.assertTrue(r["body"].get("allThreadsContinued"))
        self.stopped(reason)
        return self.top()

    def finish(self):
        code, out, err = self.prog.finish()
        self.t.assertEqual(code, 0, err)
        return out

    def close(self):
        self.c.close()
        self.prog.kill()


class M2(unittest.TestCase):

    def run_each(self, fn):
        for interp in INTERPS:
            with self.subTest(interp=interp):
                fn(interp)

    def test_breakpoint_stack_scopes_variables(self):
        def body(interp):
            for nulls in (False, True):
                with self.subTest(nulls=nulls):
                    s = Session(self, interp, {STEPS: [13]}, nulls=nulls)
                    try:
                        res = s.bp_results[STEPS]
                        self.assertTrue(res[0]["verified"])
                        ev = s.stopped("breakpoint")
                        self.assertEqual(ev["hitBreakpointIds"], [res[0]["id"]])
                        st = s.frames()
                        frames = st["stackFrames"]
                        self.assertEqual([(f["name"], f["line"]) for f in frames[:2]],
                                         [("rechne", 13), ("Hauptchunk", 27)])
                        self.assertEqual(frames[0]["source"]["path"], STEPS)
                        self.assertEqual(frames[0]["source"]["name"], "steps.lua")
                        self.assertEqual(frames[0]["column"], 1)
                        self.assertEqual(st["totalFrames"], len(frames))
                        for f in frames:
                            path = f.get("source", {}).get("path", "").replace("\\", "/")
                            self.assertNotIn("/src/ljdap/", path, "keine Agentenrahmen im Stack")
                            self.assertFalse(path.endswith("/ljdap.lua"), "keine Agentenrahmen im Stack")
                        sc = s.scopes()
                        self.assertEqual(list(sc), ["Lokal", "Upvalues", "Global"])
                        self.assertTrue(sc["Global"]["expensive"])
                        loc = s.locals()
                        self.assertEqual(loc["a"]["value"], "3")
                        self.assertEqual(loc["b"]["value"], "4")
                        self.assertEqual(loc["a"]["type"], "number")
                        self.assertNotIn("summe", loc, "noch nicht deklariert")
                        up = {v["name"]: v for v in s.variables(sc["Upvalues"]["variablesReference"])}
                        self.assertIn("inc", up)
                        self.assertTrue(up["inc"]["value"].startswith("function "))
                        glob = {v["name"] for v in s.variables(sc["Global"]["variablesReference"])}
                        self.assertTrue({"print", "io", "string"} <= glob)
                        # Rahmen 2 (Hauptchunk): lokale Variable Punkt
                        loc2 = s.locals(frames[1]["id"])
                        self.assertIn("Punkt", loc2)
                        self.assertTrue(loc2["Punkt"]["value"].startswith("Punkt"), "__tostring")
                        s.c.request("continue", {"threadId": 1})
                        self.assertIn("steps: 16 Punkt 42", s.finish())
                    finally:
                        s.close()
        self.run_each(body)

    def test_step_over_in_out(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [13]})
            try:
                s.stopped("breakpoint")
                self.assertEqual(s.step("next"), ("rechne", 14))
                self.assertEqual(s.step("next"), ("rechne", 15))
                self.assertEqual(s.step("stepIn"), ("inc", 8))
                names = [f["name"] for f in s.frames()["stackFrames"][:3]]
                self.assertEqual(names, ["inc", "rechne", "Hauptchunk"])
                self.assertEqual(s.step("stepOut"), ("rechne", 16))
                self.assertEqual(s.step("next"), ("rechne", 19), "Kommentar- und Leerzeile übersprungen")
                # zurück im Hauptchunk: Zeile 27 läuft weiter, gemeldet wird die nächste neue Zeile
                self.assertEqual(s.step("stepOut"), ("Hauptchunk", 28))
                s.c.request("continue", {"threadId": 1})
                self.assertIn("steps: 16 Punkt 42", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_step_into_function_and_back(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [16]})
            try:
                s.stopped("breakpoint")
                self.assertEqual(s.step("stepIn"), ("inc", 8))
                self.assertEqual(s.step("next"), ("inc", 9))
                # Rücksprung: Zeile 16 wird nicht erneut gemeldet, nächste neue Zeile 19
                self.assertEqual(s.step("next"), ("rechne", 19))
                s.c.request("continue", {"threadId": 1})
                s.finish()
            finally:
                s.close()
        self.run_each(body)

    def test_breakpoint_shift_and_unverified(self):
        def body(interp):
            missing = fixture("fehlt.lua")
            s = Session(self, interp, {STEPS: [17, 18, 500], missing: [3]})
            try:
                r = s.bp_results[STEPS]
                self.assertEqual([(b["verified"], b["line"]) for b in r],
                                 [(True, 19), (True, 19), (False, 500)])
                self.assertIn("keine Codezeile", r[2]["message"])
                m = s.bp_results[missing][0]
                self.assertFalse(m["verified"])
                self.assertIn("nicht lesbar", m["message"])
                s.stopped("breakpoint")
                self.assertEqual(s.top(), ("rechne", 19))
                s.c.request("continue", {"threadId": 1})
                s.finish()
            finally:
                s.close()
        self.run_each(body)

    def test_table_children_paging_and_strings(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [19]})
            try:
                s.stopped("breakpoint")
                loc = s.locals()
                t = loc["t"]
                self.assertEqual(t["type"], "table")
                self.assertTrue(t["value"].endswith("[5]"), t["value"])
                kids = s.variables(t["variablesReference"])
                self.assertEqual([k["name"] for k in kids], ["[1]", "[2]", "nested", "x", "[true]"])
                self.assertEqual(kids[3]["value"], '"ä\\1\\xFF"')
                nested = s.variables(kids[2]["variablesReference"])
                self.assertEqual([(v["name"], v["value"]) for v in nested], [("tief", "42")])
                page = s.variables(t["variablesReference"], start=1, count=2)
                self.assertEqual([k["name"] for k in page], ["[2]", "nested"])
                self.assertEqual(loc["r"]["value"], "8")
                s.c.request("continue", {"threadId": 1})
                s.finish()
            finally:
                s.close()
        self.run_each(body)

    def test_varargs(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [23]})
            try:
                s.stopped("breakpoint")
                sc = s.scopes()
                if is_luajit(interp):
                    va = s.variables(sc["Varargs"]["variablesReference"])
                    self.assertEqual([(v["name"], v["value"]) for v in va],
                                     [("[1]", '"eins"'), ("[2]", "2"), ("[3]", "nil")])
                else:
                    self.assertNotIn("Varargs", sc, "Lua 5.1: debug.getlocal kennt keine Varargs")
                s.c.request("continue", {"threadId": 1})
                s.finish()
            finally:
                s.close()
        self.run_each(body)

    def test_stop_on_entry(self):
        def body(interp):
            s = Session(self, interp, {}, attach_extra={"stopOnEntry": True})
            try:
                s.stopped("entry")
                frames = s.frames()["stackFrames"]
                self.assertEqual((frames[0]["name"], frames[0]["line"]), ("Hauptchunk", 4))
                self.assertEqual(frames[0]["source"]["path"], STEPS)
                s.c.request("continue", {"threadId": 1})
                self.assertIn("steps: 16", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_breakpoint_set_while_running(self):
        def body(interp):
            count = fixture("count.lua")
            s = Session(self, interp, {}, fixture_name="count.lua", args=["3"])
            try:
                r = s.c.request("setBreakpoints", {"source": {"path": count}, "breakpoints": [{"line": 12}]})
                self.assertTrue(r["body"]["breakpoints"][0]["verified"])
                s.stopped("breakpoint")
                self.assertEqual(s.top(), ("work", 12))
                loc = s.locals()
                self.assertEqual(loc["n"]["value"], "100000")
                s.c.request("setBreakpoints", {"source": {"path": count}, "breakpoints": []})
                s.c.request("continue", {"threadId": 1})
                self.assertIn("fixture: ende true", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_disconnect_while_stopped(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [8]})
            try:
                s.stopped("breakpoint")
                s.c.request("disconnect", {"terminateDebuggee": False})
                # inc() läuft zweimal über Zeile 8; ohne Client kein weiterer Halt
                self.assertIn("steps: 16 Punkt 42", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_breakhere(self):
        def body(interp):
            s = Session(self, interp, {}, fixture_name="breakhere.lua")
            try:
                ev = s.stopped("pause")
                self.assertIn("breakhere", ev.get("description", ""))
                self.assertEqual(s.top(), ("arbeite", 6))
                self.assertEqual(s.locals()["doppelt"]["value"], "42")
                self.assertEqual(s.step("next"), ("arbeite", 7))
                s.c.request("continue", {"threadId": 1})
                self.assertIn("breakhere: true 42", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_breakhere_without_client(self):
        def body(interp):
            prog = Program(interp, "port={port},wait=0", fixture="breakhere.lua")
            code, out, err = prog.finish()
            self.assertEqual(code, 0, err)
            self.assertIn("breakhere: false 42", out)
        self.run_each(body)

    def test_lines_start_at_zero(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [12]}, lines1=False)
            try:
                self.assertEqual(s.bp_results[STEPS][0]["line"], 12)
                s.stopped("breakpoint")
                f = s.frames()["stackFrames"][0]
                self.assertEqual((f["line"], f["column"]), (12, 0))
                s.c.request("continue", {"threadId": 1})
                s.finish()
            finally:
                s.close()
        self.run_each(body)

    def test_requests_need_stop(self):
        def body(interp):
            s = Session(self, interp, {}, fixture_name="count.lua", args=["2"])
            try:
                r = s.c.request("stackTrace", {"threadId": 1}, ok=False)
                self.assertFalse(r["success"])
                self.assertIn("nicht angehalten", r["message"])
                s.c.request("disconnect", {})
                s.finish()
            finally:
                s.close()
        self.run_each(body)

    def test_single_file_next_to_script(self):
        # ljdap.lua im selben Verzeichnis wie das Skript: Haltepunkte und
        # Stepping im Skript dürfen nicht als Agentencode übersprungen werden.
        import shutil
        import subprocess
        import tempfile
        from harness import ROOT, DapClient, free_port, is_wine
        def body(interp):
            if is_wine(interp):
                self.skipTest("Pfadzuordnung für Temp-Verzeichnis unter Wine nicht nötig")
            d = tempfile.mkdtemp(prefix="ljdap-single-")
            try:
                shutil.copy(os.path.join(ROOT, "ljdap.lua"), d)
                shutil.copy(STEPS, d)
                script = os.path.join(d, "steps.lua")
                port = free_port()
                env = dict(os.environ, LJDAP=f"port={port},wait=1")
                p = subprocess.Popen(interp.split() + ["-e", "package.path='./?.lua;'..package.path",
                                                       "-l", "ljdap", "steps.lua"],
                                     cwd=d, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                c = DapClient.connect("127.0.0.1", port)
                try:
                    c.request("initialize", {"adapterID": "ljdap"})
                    c.request("attach", {"stopOnEntry": True})
                    r = c.request("setBreakpoints", {"source": {"path": script}, "breakpoints": [{"line": 13}]})
                    self.assertTrue(r["body"]["breakpoints"][0]["verified"])
                    c.request("configurationDone")
                    self.assertEqual(c.event("stopped")["body"]["reason"], "entry")
                    f = c.request("stackTrace", {"threadId": 1})["body"]["stackFrames"][0]
                    self.assertEqual((f["name"], f["line"], os.path.realpath(f["source"]["path"])),
                                     ("Hauptchunk", 4, os.path.realpath(script)))
                    c.request("continue", {"threadId": 1})
                    self.assertEqual(c.event("stopped")["body"]["reason"], "breakpoint")
                    c.request("continue", {"threadId": 1})
                    out, err = p.communicate(timeout=30)
                    self.assertEqual(p.returncode, 0, err)
                    self.assertIn(b"steps: 16 Punkt 42", out)
                finally:
                    c.close()
                    if p.poll() is None:
                        p.kill()
                        p.communicate()
            finally:
                shutil.rmtree(d, ignore_errors=True)
        self.run_each(body)


if __name__ == "__main__":
    unittest.main()
