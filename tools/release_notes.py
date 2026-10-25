"""Gibt den CHANGELOG-Abschnitt einer Version aus (für das GitHub-Release).

Aufruf: python3 tools/release_notes.py <version>
Für Versionen mit "-dev" wird der Abschnitt [Unreleased] genommen.
Rückgabe 1, wenn der Abschnitt fehlt oder leer ist.
"""

import re
import sys


def section(text, version):
    head = "Unreleased" if version.endswith("-dev") else re.escape(version)
    m = re.search(r"^## \[" + head + r"\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.S | re.M)
    return m.group(1).strip() if m else ""


def main():
    version = sys.argv[1]
    with open("CHANGELOG.md", encoding="utf-8") as f:
        body = section(f.read(), version)
    if not body:
        print(f"CHANGELOG.md: kein Abschnitt für {version}", file=sys.stderr)
        return 1
    print(body)
    print("\nInstallation: siehe README (Abschnitte „Einbindung“ und „Sublime Text“).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
