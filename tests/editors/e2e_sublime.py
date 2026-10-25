"""Ende-zu-Ende-Test: Sublime Text + Paket Debugger + ljdap-Plugin + ljdap.

Startet Sublime Text ohne Bildschirm (Xvfb) mit eigenem Datenverzeichnis,
installiert dort Debugger (Klon), editors/sublime als „ljdap“ und den
Testtreiber tests/editors/sublime_e2e als „ljdap_e2e“, startet ein Lua-
Programm mit ljdap und steuert eine Debug-Sitzung wie ein Benutzer:
Haltepunkt setzen, starten, steppen, weiterlaufen. Geprüft wird der
Zustand im Debugger-Paket und der DAP-Mitschnitt von ljdap.

Aufruf aus dem Repo-Wurzelverzeichnis:
    SUBLIME_TEXT=/pfad/sublime_text/sublime_text \\
    SUBLIME_DEBUGGER_SRC=/pfad/SublimeDebugger \\
    python3 tests/editors/e2e_sublime.py [interp]
Ohne SUBLIME_TEXT wird der Test übersprungen (Rückgabe 0).
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tests"))
from dap_client import free_port  # noqa: E402

DEV_PATH = "package.path='src/?.lua;src/?/init.lua;'..package.path"
STEPS = os.path.join(ROOT, "tests", "fixtures", "steps.lua")


class Fail(Exception):
    pass


class Sublime:
    def __init__(self, exe, debugger_src, work):
        self.work = work
        self.home = os.path.join(work, "home")
        pk = os.path.join(self.home, ".config", "sublime-text", "Packages")
        os.makedirs(os.path.join(pk, "User"))
        shutil.copytree(debugger_src, os.path.join(pk, "Debugger"),
                        ignore=shutil.ignore_patterns(".git"))
        shutil.copytree(os.path.join(ROOT, "editors", "sublime"), os.path.join(pk, "ljdap"))
        shutil.copytree(os.path.join(HERE, "sublime_e2e"), os.path.join(pk, "ljdap_e2e"))
        with open(os.path.join(pk, "User", "Preferences.sublime-settings"), "w") as f:
            json.dump({"update_check": False, "hot_exit": "disabled",
                       "remember_open_files": False, "show_panel_on_build": False}, f)
        self.dir = os.path.join(work, "e2e")
        os.makedirs(self.dir)
        open(os.path.join(self.dir, "cmd.jsonl"), "w").close()
        self.seq = 0
        self.xvfb = None
        # XDG_CONFIG_HOME ausdrücklich setzen: GitHub-Runner setzen es auf das
        # echte Home, Sublime würde dann dort nach Paketen suchen
        env = dict(os.environ, HOME=self.home, LJDAP_E2E_DIR=self.dir,
                   XDG_CONFIG_HOME=os.path.join(self.home, ".config"),
                   XDG_DATA_HOME=os.path.join(self.home, ".local", "share"),
                   XDG_CACHE_HOME=os.path.join(self.home, ".cache"))
        self.packages = pk
        self.display = env.get("DISPLAY")
        if not env.get("DISPLAY"):
            disp = ":%d" % (90 + os.getpid() % 9)
            self.xvfb = subprocess.Popen(["Xvfb", disp, "-screen", "0", "1280x800x24", "-nolisten", "tcp"],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            env["DISPLAY"] = disp
            self.display = disp
            time.sleep(1.0)
        self.log = open(os.path.join(work, "sublime.log"), "w")
        self.p = subprocess.Popen([exe, "--wait", "--new-window", ROOT], env=env,
                                  stdout=self.log, stderr=subprocess.STDOUT)

    def results(self):
        try:
            with open(os.path.join(self.dir, "out.jsonl"), encoding="utf-8") as f:
                return [json.loads(l) for l in f if l.strip()]
        except FileNotFoundError:
            return []

    def wait_loaded(self, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if any(r["id"] == 0 for r in self.results()):
                return
            time.sleep(0.2)
        state = "läuft" if self.p.poll() is None else f"beendet ({self.p.returncode})"
        try:
            with open(os.path.join(self.work, "sublime.log"), encoding="utf-8", errors="replace") as f:
                log = f.read()[-1500:]
        except OSError:
            log = ""
        data = os.path.dirname(self.packages)
        listing = sorted(os.listdir(data)) if os.path.isdir(data) else []
        raise Fail(f"Testtreiber in Sublime nicht geladen; Sublime {state}; "
                   f"Datenverzeichnis {listing}; Ausgabe: {log!r}")

    def cmd(self, action, timeout=20, **kw):
        self.seq += 1
        c = dict(kw, id=self.seq, action=action)
        with open(os.path.join(self.dir, "cmd.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(c) + "\n")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for r in self.results():
                if r["id"] == self.seq:
                    if not r["ok"]:
                        raise Fail(f"{action}: {r.get('error')}\n{r.get('trace')}")
                    return r["result"]
            time.sleep(0.1)
        raise Fail(f"keine Antwort auf {action}")

    def wait_state(self, pred, what, timeout=20):
        deadline = time.monotonic() + timeout
        st = None
        while time.monotonic() < deadline:
            st = self.cmd("state")
            if pred(st):
                return st
            time.sleep(0.2)
        raise Fail(f"Zeitüberschreitung: {what}; letzter Zustand {st}")

    def screenshot(self, name):
        """Bildschirmfoto nach $LJDAP_E2E_OUT/<name>.png (ImageMagick import)."""
        d = os.environ.get("LJDAP_E2E_OUT")
        if not d or not shutil.which("import"):
            return None
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, name + ".png")
        time.sleep(0.8)  # Oberfläche nachzeichnen lassen
        subprocess.run(["import", "-display", self.display, "-window", "root", path],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        return path

    def close(self):
        try:
            if self.p.poll() is None:
                self.cmd("quit", timeout=5)
                self.p.wait(timeout=10)
        except Exception:
            pass
        if self.p.poll() is None:
            self.p.kill()
        if self.xvfb:
            self.xvfb.kill()
        self.log.close()


def paused_at(name, line):
    def pred(st):
        f = st.get("frame") or {}
        return st.get("state_name") == "PAUSED" and f.get("name") == name and f.get("line") == line
    return pred


def run(interp, exe, debugger_src):
    work = tempfile.mkdtemp(prefix="ljdap-e2e-")
    port = free_port()
    proto = os.path.join(work, "ljdap-protokoll.log")
    report = {"work": work}
    st = Sublime(exe, debugger_src, work)
    prog = None
    try:
        st.wait_loaded()
        env = dict(os.environ, LJDAP=f"port={port},wait=1,log={proto}")
        prog = subprocess.Popen(interp.split() + ["-e", DEV_PATH, "-l", "ljdap", "tests/fixtures/steps.lua"],
                                cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        st.cmd("breakpoint", file=STEPS, line=13)
        st.cmd("start", configuration={"name": "ljdap", "type": "ljdap", "request": "attach",
                                       "host": "127.0.0.1", "port": port})
        steps = [("Haltepunkt", None, ("rechne", 13)),
                 ("step_over", "step_over", ("rechne", 14)),
                 ("step_over", "step_over", ("rechne", 15)),
                 ("step_in", "step_in", ("inc", 8)),
                 ("step_out", "step_out", ("rechne", 16))]
        seen = []
        for label, action, (name, line) in steps:
            if action:
                st.cmd("debugger", debugger_action=action)
            try:
                s = st.wait_state(paused_at(name, line), f"{label} → {name}:{line}")
            except Fail as e:
                if prog.poll() is not None:
                    _, err = prog.communicate()
                    raise Fail(f"{e}; Programm beendet ({prog.returncode}), stderr: "
                               f"{err.decode(errors='replace')[-800:]!r}")
                raise
            seen.append((label, s["frame"]["name"], s["frame"]["line"], s["frame"]["path"]))
            st.screenshot(f"{interp.split()[0].split('/')[-1]}-{len(seen)}-{label}")
            if s["frame"]["path"] != STEPS:
                raise Fail(f"falscher Pfad im Stack: {s['frame']['path']}")
        report["halte"] = seen
        st.cmd("breakpoint", file=STEPS, line=13)  # wieder entfernen
        st.cmd("debugger", debugger_action="continue")
        out, err = prog.communicate(timeout=30)
        report["programm"] = out.decode().strip()
        if prog.returncode != 0 or b"steps: 16 Punkt 42" not in out:
            raise Fail(f"Programmende falsch: {prog.returncode} {out!r} {err!r}")
        st.wait_state(lambda s: not s.get("session") or s.get("state_name") == "STOPPED",
                      "Sitzungsende in Sublime")
        # DAP-Mitschnitt auswerten
        cmds, fails = [], []
        with open(proto, encoding="utf-8") as f:
            for line in f:
                parts = line.split(" ", 2)
                if len(parts) < 3 or parts[1] not in ("<-", "->"):
                    continue
                msg = json.loads(parts[2])
                if parts[1] == "<-" and msg.get("type") == "request":
                    cmds.append(msg["command"])
                if parts[1] == "->" and msg.get("type") == "response" and not msg.get("success"):
                    fails.append((msg.get("command"), msg.get("message")))
        report["requests"] = sorted(set(cmds))
        report["abgelehnt"] = fails
        for need in ("initialize", "attach", "setBreakpoints", "configurationDone", "threads",
                     "stackTrace", "scopes", "next", "stepIn", "stepOut", "continue"):
            if need not in cmds:
                raise Fail(f"Sublime hat {need} nicht gesendet")
        return report
    finally:
        if prog and prog.poll() is None:
            prog.kill()
        st.close()
        keep_logs(interp, work, proto, st)


def keep_logs(interp, work, proto, st):
    """Protokolle nach $LJDAP_E2E_OUT kopieren (CI-Artefakt), auch bei Fehlern."""
    d = os.environ.get("LJDAP_E2E_OUT")
    if not d:
        return
    os.makedirs(d, exist_ok=True)
    tag = interp.split()[0].split("/")[-1]
    for src, name in ((proto, "ljdap-protokoll.log"),
                      (os.path.join(st.dir, "out.jsonl"), "treiber-out.jsonl"),
                      (os.path.join(st.dir, "cmd.jsonl"), "treiber-cmd.jsonl"),
                      (os.path.join(work, "sublime.log"), "sublime.log")):
        if os.path.exists(src):
            shutil.copy(src, os.path.join(d, f"{tag}-{name}"))


def main():
    exe = os.environ.get("SUBLIME_TEXT")
    src = os.environ.get("SUBLIME_DEBUGGER_SRC")
    if not exe or not src:
        print("übersprungen: SUBLIME_TEXT und SUBLIME_DEBUGGER_SRC setzen")
        return 0
    ok = True
    for interp in sys.argv[1:] or ["luajit", "lua5.1"]:
        try:
            rep = run(interp, exe, src)
            print(f"OK   {interp}")
            for k, v in rep.items():
                print(f"     {k}: {v}")
        except Exception as e:
            ok = False
            print(f"FAIL {interp}: {e}")
            d = os.environ.get("LJDAP_E2E_OUT")
            if d:
                os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, "FEHLER.txt"), "a", encoding="utf-8") as f:
                    f.write(f"{interp}: {e}\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
