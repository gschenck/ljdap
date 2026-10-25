"""Gibt Fehler des Ende-zu-Ende-Tests als GitHub-Annotationen aus.

Annotationen sind über die REST-API lesbar (check-runs/<id>/annotations),
auch wo Logs und Artefakte nicht abrufbar sind. Grenze laut GitHub: 10
Fehler-Annotationen je Schritt; jede höchstens einige KB.
"""

import glob
import os
import sys


def esc(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def tail(path, n):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return "(fehlt)"


def main(d):
    shown = 0
    fehler = os.path.join(d, "FEHLER.txt")
    if os.path.exists(fehler):
        print("::error title=e2e FEHLER::" + esc(tail(fehler, 20)[:3500]))
        shown += 1
    for name in sorted(glob.glob(os.path.join(d, "*-treiber-out.jsonl"))):
        print(f"::error title={os.path.basename(name)}::" + esc(tail(name, 8)[-3500:]))
        shown += 1
    for name in sorted(glob.glob(os.path.join(d, "*-ljdap-protokoll.log"))):
        print(f"::error title={os.path.basename(name)}::" + esc(tail(name, 25)[-3500:]))
        shown += 1
    if not shown:
        print("::error title=e2e::keine Ausgaben in " + d)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "e2e-out")
