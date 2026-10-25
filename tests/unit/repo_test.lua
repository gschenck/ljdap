-- ljdap – Gerüsttest (M0): prüft Pflichtdateien und Changelog-Format.
-- Wird durch echte Modultests ab M1 ergänzt.

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("  FEHLER: ", msg, "\n")
  end
end

for _, p in ipairs{ "README.md", "LICENSE", "CHANGELOG.md", "docs/KONZEPT.md" } do
  check(read(p) ~= nil, p .. " fehlt")
end

local lic = read("LICENSE") or ""
check(lic:find("MIT License", 1, true), "LICENSE ist nicht MIT")

local cl = read("CHANGELOG.md") or ""
check(cl:find("## [Unreleased]", 1, true), "CHANGELOG ohne [Unreleased]")
check(cl:find("keepachangelog.com", 1, true), "CHANGELOG ohne Keep-a-Changelog-Verweis")

os.exit(failures == 0 and 0 or 1)
