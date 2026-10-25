local T = dofile("tests/unit/t.lua")
local paths = require("ljdap.paths")
local eq, check, case = T.eq, T.check, T.case

case("clean", function()
  eq(paths.clean("/a/b/../c/./d"), "/a/c/d")
  eq(paths.clean("a/./b/"), "a/b")
  eq(paths.clean("../x"), "../x")
  eq(paths.clean("/../x"), "/x")
  eq(paths.clean("c:\\Users\\GS\\..\\x.lua"), "C:/Users/x.lua")
  eq(paths.clean("\\\\server\\share\\a"), "//server/share/a")
  eq(paths.clean("a//b"), "a/b")
end)

case("absolute", function()
  eq(paths.absolute("tests/x.lua", "/home/gs/p"), "/home/gs/p/tests/x.lua")
  eq(paths.absolute("./x.lua", "/home/gs/p"), "/home/gs/p/x.lua")
  eq(paths.absolute("/abs/x.lua", "/home"), "/abs/x.lua")
  eq(paths.absolute("D:\\w\\x.lua", "C:/cwd"), "D:/w/x.lua")
  eq(paths.absolute("..\\x.lua", "C:/w/sub"), "C:/w/x.lua")
end)

case("key", function()
  local k = paths.key("C:\\Work\\Datei.lua")
  if paths.windows then
    eq(k, "c:/work/datei.lua", "Windows: Kleinschreibung")
  else
    eq(k, "C:/Work/Datei.lua", "POSIX: Groß/Klein bleibt")
  end
end)

case("getcwd", function()
  local d = paths.getcwd()
  check(type(d) == "string" and paths.is_abs(d), "absolutes Arbeitsverzeichnis: " .. tostring(d))
  local f = io.open(paths.absolute("tests/unit/paths_test.lua", d), "rb")
  check(f ~= nil, "Datei über cwd erreichbar")
  if f then f:close() end
end)

case("mapper ohne Zuordnung", function()
  local m = paths.mapper("/home/gs/p")
  local s = m:from_source("@tests/x.lua")
  eq(s.key, paths.key("/home/gs/p/tests/x.lua"))
  eq(s.path, paths.display("/home/gs/p/tests/x.lua"))
  eq(m:from_source("=stdin"), nil)
  eq(m:from_source("local x = 1"), nil)
  check(m:from_source("@tests/x.lua") == s, "zwischengespeichert")
  local key, abs = m:from_client("/home/gs/p/tests/x.lua")
  eq(key, s.key)
  eq(abs, "/home/gs/p/tests/x.lua")
end)

case("mapper mit pathMappings", function()
  -- Editor unter Windows, Programm auf zeus
  local m = paths.mapper("/srv/app", {
    { localRoot = "C:\\Projekte\\app", remoteRoot = "/srv/app" },
    { localRoot = 5 }, -- ungültig, wird ignoriert
  })
  local key, abs = m:from_client("C:\\Projekte\\app\\src\\main.lua")
  eq(abs, "/srv/app/src/main.lua")
  eq(key, paths.key("/srv/app/src/main.lua"))
  local s = m:from_source("@src/main.lua")
  eq(s.key, key)
  eq(s.path, "C:\\Projekte\\app\\src\\main.lua", "Schreibweise des Clients")
  -- umgekehrt: Linux-Editor, Programm unter Windows/Wine
  local w = paths.mapper("Z:/home/gs/app", { { localRoot = "/home/gs/app", remoteRoot = "Z:\\home\\gs\\app" } })
  eq(w:from_source("@src/x.lua").path, "/home/gs/app/src/x.lua")
  -- Präfix nur an Pfadgrenzen
  local _, abs2 = m:from_client("C:\\Projekte\\app2\\x.lua")
  eq(abs2, "C:/Projekte/app2/x.lua", "kein Treffer bei app2")
end)

T.finish()
