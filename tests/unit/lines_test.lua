local T = dofile("tests/unit/t.lua")
local lines = require("ljdap.lines")
local eq, check, case = T.eq, T.check, T.case

local function sorted(set)
  local t = {}
  for l in pairs(set) do t[#t + 1] = l end
  table.sort(t)
  return t
end

case("verschachtelte Funktionen", function()
  local src = table.concat({
    "local a = 1",             -- 1
    "-- Kommentar",            -- 2
    "local function f(x)",     -- 3
    "",                        -- 4
    "  local y = x * 2",       -- 5
    "  return function()",     -- 6
    "    return y",            -- 7
    "  end",                   -- 8
    "end",                     -- 9
    "print(f(a)())",           -- 10
  }, "\n")
  local fn = assert(loadstring(src, "=t"))
  local set = assert(lines.of_function(fn))
  check(set[1] and set[5] and set[7] and set[10], "Codezeilen: " .. table.concat(sorted(set), ","))
  check(not set[2] and not set[4], "Kommentar/Leerzeile nicht gültig")
  local a2 = lines.adjust(set, 2)
  check(a2 and a2 > 2, "Kommentar 2 wird nach unten geschoben")
  check(lines.adjust(set, 4) == 5, "Leerzeile 4 -> 5")
  check(lines.adjust(set, 7) == 7, "gültige Zeile bleibt")
  eq(lines.adjust(set, 200), nil, "jenseits des Endes")
end)

case("Datei", function()
  local set = assert(lines.of_file("tests/fixtures/steps.lua"))
  check(set[13] and set[15] and set[19], "steps.lua 13/15/19")
  check(not set[17] and not set[18], "Kommentar 17, Leerzeile 18")
  eq(lines.adjust(set, 17), 19)
  local v, err = lines.of_file("tests/fixtures/gibtsnicht.lua")
  check(v == nil and err, "fehlende Datei")
end)

case("Shebang, BOM und Syntaxfehler", function()
  -- nicht os.tmpname(): unter Windows/Wine liegt der Name im Laufwerks-
  -- wurzelverzeichnis (\\sXXX.), dort darf ein normaler Benutzer nicht schreiben
  local tmp = "tests/unit/_tmp_lines.lua"
  local f = assert(io.open(tmp, "wb"))
  f:write("\239\187\191#!/usr/bin/env luajit\nlocal x = 1\nreturn x\n")
  f:close()
  local set = assert(lines.of_file(tmp))
  check(set[2] and set[3], "Zeilennummern bleiben trotz BOM/Shebang")
  f = assert(io.open(tmp, "wb"))
  f:write("local = \n")
  f:close()
  local v, err = lines.of_file(tmp)
  check(v == nil and err, "Syntaxfehler")
  os.remove(tmp)
end)

T.finish()
