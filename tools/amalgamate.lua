-- tools/amalgamate.lua – erzeugt die Ein-Datei-Version ljdap.lua aus src/ljdap/.
--
-- Aufruf im Repo-Wurzelverzeichnis (luajit oder lua5.1):
--   luajit tools/amalgamate.lua            schreibt ljdap.lua
--   luajit tools/amalgamate.lua --check    Rückgabe 1, wenn ljdap.lua veraltet ist
--   luajit tools/amalgamate.lua --out x.lua
--
-- Aufbau der Ausgabe: alle Module außer init als package.preload-Funktionen,
-- danach der Inhalt von init.lua als Hauptchunk. So bleiben die Stack-Ebenen
-- für die Erkennung von `-l ljdap` (init.lua) dieselben wie in src/.

local MODULES = {
  "version", "json", "transport", "protocol", "paths", "lines",
  "breakpoints", "vars", "hooks", "eval", "threads", "errors", "session",
}
local MAIN = "init"

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- Alle Dateien in src/ljdap/ müssen in MODULES oder MAIN vorkommen.
local function check_complete()
  local known = { [MAIN] = true }
  for _, m in ipairs(MODULES) do known[m] = true end
  local sep = package.config:sub(1, 1)
  local cmd = sep == "\\" and 'dir /b "src\\ljdap\\*.lua"' or "ls src/ljdap/*.lua"
  local p = io.popen(cmd)
  if not p then return end
  for line in p:lines() do
    local name = line:match("([%w_]+)%.lua%s*$")
    if name and not known[name] then
      error("Modul src/ljdap/" .. name .. ".lua fehlt in tools/amalgamate.lua (MODULES)", 0)
    end
  end
  p:close()
end

local function build()
  check_complete()
  local version = read("src/ljdap/version.lua"):match('"([^"]+)"')
  local out = {}
  out[#out + 1] = ("-- ljdap %s – DAP-Server in reinem Lua für LuaJIT 2.1 und Lua 5.1\n"):format(version)
  out[#out + 1] = "-- https://github.com/gschenck/ljdap – MIT-Lizenz, (c) 2026 Gunter Schenck\n"
  out[#out + 1] = "-- Ein-Datei-Version, erzeugt von tools/amalgamate.lua aus src/ljdap/ – nicht von Hand ändern.\n"
  out[#out + 1] = "-- Einbindung: luajit -l ljdap skript.lua   bzw.   require(\"ljdap\").start{ port = 4711 }\n\n"
  for _, m in ipairs(MODULES) do
    local src = read("src/ljdap/" .. m .. ".lua")
    if src:sub(-1) ~= "\n" then src = src .. "\n" end
    out[#out + 1] = ('package.preload["ljdap.%s"] = function(...)\n'):format(m)
    out[#out + 1] = src
    out[#out + 1] = "end\n\n"
  end
  out[#out + 1] = "-- Hauptmodul (src/ljdap/init.lua)\n"
  out[#out + 1] = read("src/ljdap/" .. MAIN .. ".lua")
  return table.concat(out)
end

local check, target = false, "ljdap.lua"
local i = 1
while arg[i] do
  if arg[i] == "--check" then check = true
  elseif arg[i] == "--out" then i = i + 1; target = arg[i] end
  i = i + 1
end

local ok, text = pcall(build)
if not ok then
  io.stderr:write("amalgamate: ", tostring(text), "\n")
  os.exit(2)
end
-- Syntaxprüfung der Ausgabe
local fn, err = loadstring(text, "=ljdap.lua")
if not fn then
  io.stderr:write("amalgamate: erzeugte Datei fehlerhaft: ", err, "\n")
  os.exit(2)
end

if check then
  local f = io.open(target, "rb")
  local cur = f and f:read("*a")
  if f then f:close() end
  if cur ~= text then
    io.stderr:write(target, " ist veraltet – luajit tools/amalgamate.lua ausführen\n")
    os.exit(1)
  end
  print(target .. " ist aktuell")
  os.exit(0)
end

local f = assert(io.open(target, "wb"))
f:write(text)
f:close()
print(("%s geschrieben (%d Bytes)"):format(target, #text))
