@echo off
rem ljdap - lokale Tags nach GitHub schieben (aus der Claude-Sitzung nicht moeglich).
rem Aufruf im Repo-Verzeichnis: tools\push_tags.cmd
git fetch origin --tags || exit /b 1
git tag -l
git push origin --tags
