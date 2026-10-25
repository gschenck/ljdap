"""M3-Szenarien: Coroutinen, evaluate/setVariable, Fehler-Halt, Bedingungen,
Trefferzähler, Logpoints, Pause.

Zeilennummern: tests/fixtures/steps.lua, coro.lua, fehler.lua, schleife.lua.
"""

import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(__file__))
from harness import INTERPS, fixture, is_luajit  # noqa: E402
from test_m2 import Session, STEPS  # noqa: E402

CORO = fixture("coro.lua")
FEHLER = fixture("fehler.lua")


class M3(unittest.TestCase):

    def run_each(self, fn):
        for interp in INTERPS:
            with self.subTest(interp=interp):
                fn(interp)

    # -- Bedingungen, Trefferzähler, Logpoints ---------------------------

    def test_conditional_breakpoint(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [8]}, bp_extra={8: {"condition": "n > 5"}})
            try:
                s.stopped("breakpoint")
                self.assertEqual(s.locals()["n"]["value"], "7", "nur der zweite Aufruf inc(7)")
                s.c.request("continue", {"threadId": 1})
                self.assertIn("steps: 16", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_condition_error_stops_and_reports(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [8]}, bp_extra={8: {"condition": "nichtda.feld > 1"}})
            try:
                ev = s.stopped("breakpoint")
                self.assertIn("Bedingung fehlerhaft", ev.get("description", ""))
                s.c.request("setBreakpoints", {"source": {"path": STEPS}, "breakpoints": []})
                s.c.request("continue", {"threadId": 1})
                s.finish()
            finally:
                s.close()
        self.run_each(body)

    def test_hit_condition(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [8]}, bp_extra={8: {"hitCondition": "2"}})
            try:
                s.stopped("breakpoint")
                self.assertEqual(s.locals()["n"]["value"], "7", "zweiter Treffer")
                s.c.request("continue", {"threadId": 1})
                s.finish()
            finally:
                s.close()
        self.run_each(body)

    def test_logpoint(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [8]},
                        bp_extra={8: {"logMessage": "inc n={n} zaehler={zaehler} fehler={nichtda.x}"}})
            try:
                logs = []
                deadline = time.monotonic() + 10
                while len(logs) < 2 and time.monotonic() < deadline:
                    ev = s.c.event("output")["body"]
                    if ev["output"].startswith("inc "):
                        logs.append(ev)
                self.assertEqual(logs[0]["output"].split(" fehler=")[0], "inc n=1 zaehler=0")
                self.assertEqual(logs[1]["output"].split(" fehler=")[0], "inc n=7 zaehler=1")
                self.assertIn("<", logs[0]["output"].split(" fehler=")[1], "Fehler im Ausdruck sichtbar")
                self.assertEqual(logs[0]["line"], 8)
                self.assertEqual(logs[0]["source"]["path"], STEPS)
                self.assertIn("steps: 16", s.finish(), "Logpoint hält nicht an")
            finally:
                s.close()
        self.run_each(body)

    # -- evaluate / setVariable -------------------------------------------

    def test_evaluate(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [19]})
            try:
                s.stopped("breakpoint")
                fid = s.frames()["stackFrames"][0]["id"]

                def ev(expr, ctx="watch", ok=True):
                    r = s.c.request("evaluate", {"expression": expr, "frameId": fid, "context": ctx}, ok=ok)
                    return r if not ok else r["body"]

                self.assertEqual(ev("summe * 2")["result"], "14")
                self.assertEqual(ev("t.nested.tief")["result"], "42")
                self.assertEqual(ev("a, b")["result"], "3, 4")
                # zaehler ist Upvalue von inc, nicht von rechne: hier nil (globale Suche)
                self.assertEqual(ev("zaehler", "hover")["result"], "nil")
                self.assertTrue(ev("inc", "hover")["result"].startswith("function"), "Upvalue von rechne")
                t = ev("t", "hover")
                self.assertEqual(t["type"], "table")
                self.assertGreater(t["variablesReference"], 0)
                kids = s.variables(t["variablesReference"])
                self.assertIn("nested", [k["name"] for k in kids])
                self.assertEqual(ev("#t")["result"], "2")
                self.assertEqual(ev("string.rep('a', 3)")["result"], '"aaa"')
                bad = ev("1 +", ok=False)
                self.assertFalse(bad["success"])
                bad = ev("nichtda.x", ok=False)
                self.assertIn("nichtda", bad["message"])
                # Anweisung schreibt Local zurück
                self.assertEqual(ev("r = 50", "repl")["result"], "")
                self.assertEqual(s.locals()["r"]["value"], "50")
                s.c.request("continue", {"threadId": 1})
                self.assertIn("steps: 100 Punkt 42", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_set_variable(self):
        def body(interp):
            s = Session(self, interp, {STEPS: [19]})
            try:
                s.stopped("breakpoint")
                sc = s.scopes()
                ref = sc["Lokal"]["variablesReference"]
                loc = {v["name"]: v for v in s.variables(ref)}
                r = s.c.request("setVariable", {"variablesReference": ref, "name": "r", "value": "summe * 3"})
                self.assertEqual(r["body"]["value"], "21")
                # Tabellenfeld ändern
                tref = loc["t"]["variablesReference"]
                s.variables(tref)
                r = s.c.request("setVariable", {"variablesReference": tref, "name": "x", "value": "'neu'"})
                self.assertEqual(r["body"]["value"], '"neu"')
                self.assertEqual({k["name"]: k["value"] for k in s.variables(tref)}["x"], '"neu"')
                # Upvalue
                uref = sc["Upvalues"]["variablesReference"]
                s.variables(uref)
                r = s.c.request("setVariable", {"variablesReference": uref, "name": "inc", "value": "inc"})
                self.assertTrue(r["body"]["value"].startswith("function"))
                bad = s.c.request("setVariable", {"variablesReference": ref, "name": "gibtsnicht", "value": "1"},
                                  ok=False)
                self.assertFalse(bad["success"])
                s.c.request("continue", {"threadId": 1})
                self.assertIn("steps: 42 Punkt 42", s.finish())
            finally:
                s.close()
        self.run_each(body)

    # -- Pause -------------------------------------------------------------

    def test_pause_and_set_loop_variable(self):
        def body(interp):
            s = Session(self, interp, {}, fixture_name="schleife.lua")
            try:
                time.sleep(0.5)
                s.c.request("pause", {"threadId": 1})
                s.stopped("pause")
                name, line = s.top()
                self.assertEqual(name, "Hauptchunk")
                self.assertIn(line, (6, 7))
                ref = s.scopes()["Lokal"]["variablesReference"]
                s.variables(ref)
                s.c.request("setVariable", {"variablesReference": ref, "name": "laufen", "value": "false"})
                s.c.request("continue", {"threadId": 1})
                self.assertIn("schleife: false true", s.finish())
            finally:
                s.close()
        self.run_each(body)

    # -- Fehler-Halt -------------------------------------------------------

    def test_uncaught_error(self):
        def body(interp):
            s = Session(self, interp, {}, fixture_name="fehler.lua", args=["uncaught"], exc=["uncaught"])
            try:
                ev = s.stopped("exception")
                self.assertIn("feld", ev.get("text", ""))
                frames = s.frames()["stackFrames"]
                self.assertEqual((frames[0]["name"], frames[0]["line"]), ("rechne", 12))
                self.assertEqual((frames[1]["name"], frames[1]["line"]), ("Hauptchunk", 25))
                for f in frames:
                    p = f.get("source", {}).get("path", "").replace("\\", "/")
                    self.assertNotIn("/src/ljdap/", p)
                    self.assertFalse(p.endswith("/ljdap.lua"))
                info = s.c.request("exceptionInfo", {"threadId": 1})["body"]
                self.assertEqual(info["breakMode"], "unhandled")
                self.assertIn("feld", info["description"])
                self.assertIn("t", s.locals())
                s.c.request("continue", {"threadId": 1})
                code, out, err = s.prog.finish()
                self.assertEqual(code, 1, "Programm endet mit Fehler wie ohne Debugger")
                self.assertIn("feld", err)
                self.assertIn("stack traceback", err)
                self.assertIn("vor dem Fehler", out)
            finally:
                s.close()
        self.run_each(body)

    def test_uncaught_filter_off_no_stop(self):
        def body(interp):
            s = Session(self, interp, {}, fixture_name="fehler.lua", args=["uncaught"], exc=[])
            try:
                code, out, err = s.prog.finish()
                self.assertEqual(code, 1)
                self.assertIn("feld", err)
            finally:
                s.close()
        self.run_each(body)

    def test_raised_error_in_pcall(self):
        def body(interp):
            s = Session(self, interp, {}, fixture_name="fehler.lua", args=["raised"], exc=["raised"])
            try:
                ev = s.stopped("exception")
                self.assertIn("Division durch null", ev.get("text", ""))
                # über pcall gerufen: Lua kennt keinen Namen -> Datei:Definitionszeile
                self.assertEqual(s.top(), ("fehler.lua:4", 6))
                info = s.c.request("exceptionInfo", {"threadId": 1})["body"]
                self.assertEqual(info["breakMode"], "always")
                s.c.request("continue", {"threadId": 1})
                self.assertIn("raised: false Division durch null", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_raised_off_pcall_runs_through(self):
        def body(interp):
            s = Session(self, interp, {}, fixture_name="fehler.lua", args=["raised"], exc=["uncaught"])
            try:
                self.assertIn("raised: false Division durch null", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_uncaught_error_in_coroutine(self):
        def body(interp):
            s = Session(self, interp, {}, fixture_name="fehler.lua", args=["coro"], exc=["uncaught"])
            try:
                if not is_luajit(interp):
                    # Lua 5.1: kein Halt (kein yield über xpcall), Programm läuft durch
                    self.assertIn("coro: false", s.finish())
                    return
                ev = s.stopped("exception", thread=None)
                self.assertNotEqual(ev["threadId"], 1)
                self.assertEqual(s.c.request("stackTrace", {"threadId": ev["threadId"]})["body"]
                                 ["stackFrames"][0]["line"], 12)
                s.c.request("continue", {"threadId": ev["threadId"]})
                self.assertIn("coro: false", s.finish())
            finally:
                s.close()
        self.run_each(body)

    # -- Coroutinen --------------------------------------------------------

    def test_breakpoint_in_coroutine(self):
        def body(interp):
            s = Session(self, interp, {CORO: [6]}, fixture_name="coro.lua", args=["0"])
            try:
                ev = s.stopped("breakpoint", thread=None)
                tid = ev["threadId"]
                self.assertNotEqual(tid, 1)
                ths = s.c.request("threads")["body"]["threads"]
                names = {t["id"]: t["name"] for t in ths}
                self.assertEqual(names[1], "main")
                self.assertIn("coro.lua:3", names[tid])
                st = s.c.request("stackTrace", {"threadId": tid})["body"]["stackFrames"]
                self.assertEqual((st[0]["name"], st[0]["line"]), ("coro.lua:3", 6))
                self.assertEqual(len(st), 1, "nur der Coroutine-Stack, ohne Agentenrahmen")
                loc = {v["name"]: v["value"] for v in
                       s.variables(s.c.request("scopes", {"frameId": st[0]["id"]})["body"]["scopes"][0]
                                   ["variablesReference"])}
                self.assertEqual(loc["start"], "10")
                main = s.c.request("stackTrace", {"threadId": 1})["body"]["stackFrames"]
                self.assertEqual(len(main), 1)
                self.assertIn("wartet", main[0]["name"])
                # Step über yield: zurück im Hauptchunk
                s.c.request("next", {"threadId": tid})
                ev = s.stopped("step", thread=tid)
                self.assertEqual(s.c.request("stackTrace", {"threadId": tid})["body"]["stackFrames"][0]["line"], 7)
                s.c.request("next", {"threadId": tid})
                s.stopped("step", thread=1)  # nach yield hält der Schritt im Aufrufer
                f = s.c.request("stackTrace", {"threadId": 1})["body"]["stackFrames"][0]
                self.assertEqual(f["name"], "Hauptchunk")
                self.assertIn(f["line"], (15, 16))
                # Haltepunkt weg, weiterlaufen
                s.c.request("setBreakpoints", {"source": {"path": CORO}, "breakpoints": []})
                s.c.request("continue", {"threadId": 1})
                self.assertIn("coro: 39", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_step_over_resume_does_not_stop_in_coroutine(self):
        def body(interp):
            s = Session(self, interp, {CORO: [15]}, fixture_name="coro.lua", args=["0"])
            try:
                s.stopped("breakpoint")
                s.c.request("setBreakpoints", {"source": {"path": CORO}, "breakpoints": []})
                s.c.request("next", {"threadId": 1})
                ev = s.stopped("step")
                self.assertEqual(ev["threadId"], 1)
                f = s.c.request("stackTrace", {"threadId": 1})["body"]["stackFrames"][0]
                self.assertEqual((f["name"], f["line"]), ("Hauptchunk", 16))
                s.c.request("continue", {"threadId": 1})
                self.assertIn("coro: 39", s.finish())
            finally:
                s.close()
        self.run_each(body)

    def test_coroutine_created_before_attach(self):
        # Coroutine "spaet" entsteht vor dem Verbinden (wait=0); Haltepunkt
        # darin wird nach dem Verbinden gesetzt (Konzept 11)
        def body(interp):
            s = Session(self, interp, {CORO: [24]}, fixture_name="coro.lua", args=["4"],
                        env="port={port},wait=0")
            try:
                ev = s.stopped("breakpoint", thread=None)
                self.assertNotEqual(ev["threadId"], 1)
                self.assertEqual(s.c.request("stackTrace", {"threadId": ev["threadId"]})["body"]
                                 ["stackFrames"][0]["line"], 24)
                s.c.request("setBreakpoints", {"source": {"path": CORO}, "breakpoints": []})
                s.c.request("continue", {"threadId": ev["threadId"]})
                self.assertIn("coro: 39", s.finish())
            finally:
                s.close()
        self.run_each(body)


if __name__ == "__main__":
    unittest.main()
