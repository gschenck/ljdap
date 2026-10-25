"""Testtreiber in Sublime Text: führt Befehle aus einer Datei aus.

Nur für tests/editors/e2e_sublime.py. Wird als Paket „ljdap_e2e“ neben
„Debugger“ und „ljdap“ installiert. Befehle: eine JSON-Zeile je Befehl in
$LJDAP_E2E_DIR/cmd.jsonl ({"id": n, "action": …}); Ergebnisse als JSON-Zeile
in $LJDAP_E2E_DIR/out.jsonl ({"id": n, "ok": bool, "result": …}).
"""

import json
import os
import traceback

import sublime

DIR = os.environ.get("LJDAP_E2E_DIR", "")
_done = set()
_pos = 0


def _out(obj):
    with open(os.path.join(DIR, "out.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def _debugger(create=False):
    from Debugger.modules.debugger import Debugger
    return Debugger.get(sublime.active_window(), create=create)


def _state():
    d = _debugger()
    if not d:
        return {"debugger": False}
    s = getattr(d, "session", None)  # current_session wirft ohne Sitzung
    if not s:
        return {"debugger": True, "session": False}
    fr = s.selected_frame
    frame = None
    if fr is not None:
        src = getattr(fr, "source", None)
        frame = {"name": getattr(fr, "name", None), "line": getattr(fr, "line", None),
                 "path": getattr(src, "path", None) if src else None}
    th = s.selected_thread
    return {"debugger": True, "session": True, "state": int(s.state),
            "state_name": s.State(s.state).name if hasattr(s, "State") else None,
            "thread": getattr(th, "name", None) if th else None, "frame": frame}


def _run(cmd):
    a = cmd["action"]
    w = sublime.active_window()
    if a == "ping":
        return {"windows": len(sublime.windows())}
    if a == "breakpoint":
        d = _debugger(create=True)
        d.breakpoints.source.toggle_file_line(cmd["file"], cmd["line"])
        return {"count": len(d.breakpoints.source.breakpoints)}
    if a == "start":
        w.run_command("debugger", {"action": "start", "configuration": cmd["configuration"]})
        return None
    if a == "debugger":
        w.run_command("debugger", {"action": cmd["debugger_action"]})
        return None
    if a == "state":
        return _state()
    if a == "quit":
        sublime.set_timeout(lambda: sublime.run_command("exit"), 200)
        return None
    raise ValueError("unbekannte Aktion " + a)


def _poll():
    global _pos
    path = os.path.join(DIR, "cmd.jsonl")
    try:
        with open(path, encoding="utf-8") as f:
            f.seek(_pos)
            data = f.read()
            # nur vollständige Zeilen verarbeiten
            end = data.rfind("\n") + 1
            _pos += len(data[:end].encode("utf-8"))
            lines = data[:end].splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        if not line.strip():
            continue
        cmd = json.loads(line)
        if cmd["id"] in _done:
            continue
        _done.add(cmd["id"])
        try:
            _out({"id": cmd["id"], "ok": True, "result": _run(cmd)})
        except Exception as e:
            _out({"id": cmd["id"], "ok": False, "error": repr(e), "trace": traceback.format_exc()})
    sublime.set_timeout(_poll, 100)


def plugin_loaded():
    if not DIR:
        return
    _out({"id": 0, "ok": True, "result": "geladen"})
    sublime.set_timeout(_poll, 500)
