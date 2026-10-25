#!/bin/sh
# Baut die Release-Dateien nach dist/:
#   ljdap.lua                   Ein-Datei-Version (muss aktuell eingecheckt sein)
#   ljdap-sublime-<v>.zip       Ordner ljdap/ zum Entpacken nach Packages/
#   ljdap.sublime-package       dasselbe als Paketdatei für "Installed Packages/"
#   SHA256SUMS
# Aufruf im Repo-Wurzelverzeichnis: sh tools/build_release.sh
set -eu
cd "$(dirname "$0")/.."
LUA=${LUA:-luajit}
V=$(sed -n 's/^return "\(.*\)".*/\1/p' src/ljdap/version.lua)
[ -n "$V" ] || { echo "Version in src/ljdap/version.lua nicht gefunden" >&2; exit 1; }

$LUA tools/amalgamate.lua --check

rm -rf dist
mkdir -p dist/stage/ljdap
cp ljdap.lua dist/ljdap.lua
cp editors/sublime/ljdap_adapter.py editors/sublime/.python-version \
   editors/sublime/ljdap.sublime-project.example dist/stage/ljdap/
cp LICENSE dist/stage/ljdap/LICENSE
cp ljdap.lua dist/stage/ljdap/ljdap.lua   # für launch (Starter-Modus)
(cd dist/stage && zip -qrX "../ljdap-sublime-$V.zip" ljdap)
(cd dist/stage/ljdap && zip -qrX ../../ljdap.sublime-package .)
rm -rf dist/stage
(cd dist && sha256sum ljdap.lua "ljdap-sublime-$V.zip" ljdap.sublime-package > SHA256SUMS)
echo "Version $V:"
ls -l dist
