"""Leistungsmessung: Laufzeit von tests/fixtures/bench.lua mit und ohne ljdap.

Aufruf aus dem Repo-Wurzelverzeichnis:  python3 tests/perf/bench.py [interp …]
Vergleichsbasis ist der Lauf ohne ljdap mit ausgeschaltetem JIT (-joff),
weil ljdap bei verbundenem Client den JIT abschaltet.
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from dap_client import DapClient, free_port  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEV_PATH = "package.path='src/?.lua;src/?/init.lua;'..package.path"


def run(interp, ljdap, bp=None, extra=()):
    port = free_port()
    env = dict(os.environ)
    cmd = interp.split() + list(extra) + ["-e", DEV_PATH]
    if ljdap:
        env["LJDAP"] = f"port={port},wait=1"
        cmd += ["-l", "ljdap"]
    cmd += ["tests/fixtures/bench.lua"]
    p = subprocess.Popen(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    c = None
    if ljdap:
        c = DapClient.connect("127.0.0.1", port)
        c.request("initialize", {})
        c.request("attach", {})
        if bp:
            path, line = bp
            c.request("setBreakpoints", {"source": {"path": path}, "breakpoints": [{"line": line}]})
        c.request("configurationDone")
    out, _ = p.communicate(timeout=600)
    if c:
        c.close()
    return float(out.split()[1])


def main(interps):
    other = (os.path.join(ROOT, "tests", "fixtures", "steps.lua"), 13)
    for interp in interps:
        joff = ["-joff"] if "luajit" in interp else []
        base = run(interp, False, extra=joff)
        rows = [("ohne ljdap" + (" (-joff)" if joff else ""), base),
                ("Client verbunden, keine Haltepunkte", run(interp, True)),
                ("Haltepunkt in anderer Datei", run(interp, True, bp=other))]
        if joff:
            rows.insert(0, ("ohne ljdap, JIT an", run(interp, False)))
        print(interp)
        for name, t in rows:
            print(f"  {name:38s} {t:7.3f} s  {t / base:5.2f}×")


if __name__ == "__main__":
    main(sys.argv[1:] or ["luajit", "lua5.1"])
