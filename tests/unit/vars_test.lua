local T = dofile("tests/unit/t.lua")
local vars = require("ljdap.vars")
local eq, check, case = T.eq, T.check, T.case

case("Zahlen", function()
  eq(vars.format(42), "42")
  eq(vars.format(-0.5), "-0.5")
  eq(vars.format(0.1), "0.1")
  eq(vars.format(1 / 3), "0.33333333333333331")
  eq(vars.format(2 ^ 60), "1.152921504606847e+18")
  eq(vars.format(0 / 0), "nan")
  eq(vars.format(-math.huge), "-inf")
end)

case("Strings", function()
  eq(vars.format("abc"), '"abc"')
  eq(vars.format('a"b\\'), '"a\\"b\\\\"')
  eq(vars.format("z\n\t\0\1"), '"z\\n\\t\\0\\1"')
  eq(vars.format("Größe"), '"Größe"')
  eq(vars.format("a\255b"), '"a\\xFFb"')
  eq(vars.format("\195"), '"\\xC3"', "abgeschnittene UTF-8-Folge")
  local long = string.rep("ä", 300)
  local s = vars.format(long)
  check(s:find("…", 1, true) and s:find("(600 Bytes)", 1, true), "gekürzt: " .. s:sub(-30))
  -- Kürzung an Zeichengrenze: kein halbes ä
  local body = s:match('^"(.-)…')
  check(body and #body == 400, "200 Zeichen à 2 Bytes")
end)

case("Tabellen und Funktionen", function()
  local s, tn, exp = vars.format({ 1, 2, 3 })
  check(s:match("^table: ") and s:find("[3]", 1, true), s)
  eq(tn, "table")
  eq(exp, true)
  local obj = setmetatable({}, { __tostring = function() return "Obj!" end, __name = "Klasse" })
  s, tn = vars.format(obj)
  check(s:find("^Obj!"), s)
  eq(tn, "Klasse")
  local bad = setmetatable({}, { __tostring = function() error("kaputt") end })
  s = vars.format(bad)
  check(s:find("Fehler in __tostring"), "Fehler in __tostring abgefangen: " .. s)
  s = vars.format(print)
  eq(s, "function [C]")
  s = vars.format(function() end)
  check(s:find("^function .*vars_test%.lua:%d+"), s)
  local big = {}
  for i = 1, 1500 do big[i] = i end
  s = vars.format(big)
  check(s:find("[1000+]", 1, true), "Zählgrenze")
end)

case("Kinder, Sortierung, Metatabelle, Paging", function()
  local refs = vars.refs()
  local mt = { __index = function() error("darf nicht aufgerufen werden") end }
  local t = setmetatable({ 3, 1, b = 2, a = { tief = 1 }, ["mit leer"] = 0, [true] = "w" }, mt)
  local item = { kind = "value", value = t }
  local kids = vars.children(refs, item)
  local names = {}
  for i, v in ipairs(kids) do names[i] = v.name end
  eq(names, { "[1]", "[2]", "a", "b", '["mit leer"]', "[true]", "[metatable]" })
  local a = kids[3]
  check(a.variablesReference > 0, "Untertabelle aufklappbar")
  local sub = vars.children(refs, refs:get(a.variablesReference))
  eq(sub[1].name, "tief")
  eq(sub[1].value, "1")
  -- Paging
  local page = vars.children(refs, item, 2, 2)
  eq(#page, 2)
  eq(page[1].name, "a")
  eq(page[2].name, "b")
  refs:clear()
  eq(refs:get(a.variablesReference), nil, "Referenzen nach clear ungültig")
end)

case("cdata", function()
  local ok, ffi = pcall(require, "ffi")
  if not ok then return end
  local v = ffi.new("int[3]")
  local s, tn = vars.format(v)
  check(s:find("^cdata"), s)
  check(tn:find("ctype"), tn)
end)

T.finish()
