local T = dofile("tests/unit/t.lua")
local eval = require("ljdap.eval")
local eq, check, case = T.eq, T.check, T.case

-- Rahmen einer pausierten Coroutine als Accessor (Ebene 1 = Funktion)
local function frame_of(co)
  return {
    info = function(what) return debug.getinfo(co, 1, what) end,
    getlocal = function(i) return debug.getlocal(co, 1, i) end,
    setlocal = function(i, v) return debug.setlocal(co, 1, i, v) end,
  }
end

local oben = 100
local function probe(a, ...)
  local b = a * 2
  local t = { x = 1 }
  local gelesen = coroutine.yield()
  return a, b, t, oben, gelesen, ...
end

local function start(...)
  local co = coroutine.create(probe)
  assert(coroutine.resume(co, ...))
  return co
end

case("global", function()
  local ok, r = eval.run("1 + 2")
  check(ok and r.n == 1 and r[1] == 3, "1 + 2")
  ok, r = eval.run("string.format('%d', 7)")
  eq(r[1], "7")
  ok, r = eval.run("1, nil, 3")
  eq(r.n, 3)
  eq(r[2], nil)
  ok, r = eval.run("ljdap_test_global = 5")
  check(ok and r.n == 0, "Anweisung")
  eq(rawget(_G, "ljdap_test_global"), 5)
  ljdap_test_global = nil
end)

case("Fehler", function()
  local ok, err = eval.run("1 +")
  check(not ok and err:find("expected") or err:find("unexpected"), "Syntax: " .. tostring(err))
  ok, err = eval.run("nichtda.feld")
  check(not ok and err:find("nichtda"), "Laufzeit: " .. tostring(err))
  check(not err:find("auswertung"), "kein Chunkname in der Meldung")
  ok, err = eval.run("   ")
  check(not ok, "leer")
  ok, err = eval.run(nil)
  check(not ok, "nil")
end)

case("Rahmen: lesen", function()
  local co = start(21, "v1", "v2")
  local acc = frame_of(co)
  local ok, r = eval.run("a + b", acc)
  eq(r[1], 63)
  ok, r = eval.run("t.x", acc)
  eq(r[1], 1)
  ok, r = eval.run("oben", acc)
  eq(r[1], 100, "Upvalue")
  ok, r = eval.run("print == _G.print", acc)
  eq(r[1], true, "Globale über fenv")
  ok, r = eval.run("gelesen", acc)
  eq(r[1], nil, "noch nicht zugewiesene Local verdeckt Globale")
  if jit then
    ok, r = eval.run("vararg.n, vararg[1], vararg[2]", acc)
    eq({ r[1], r[2], r[3] }, { 2, "v1", "v2" }, "Varargs als Pseudovariable")
  end
end)

case("Rahmen: schreiben", function()
  local co = start(5)
  local acc = frame_of(co)
  local ok = eval.run("b = 99; t.x = 2; oben = 7", acc)
  check(ok, "Zuweisungen")
  local _, a, b, t, o = coroutine.resume(co, "neu")
  eq(a, 5)
  eq(b, 99, "Local zurückgeschrieben")
  eq(t.x, 2, "Tabelle geändert")
  eq(o, 7, "Upvalue zurückgeschrieben")
  oben = 100
end)

case("fehlgeschlagene Auswertung schreibt nicht zurück", function()
  local co = start(5)
  local acc = frame_of(co)
  local ok = eval.run("b = 1; error('x')", acc)
  check(not ok, "Fehler")
  local _, _, b = coroutine.resume(co)
  eq(b, 10, "unverändert")
end)

T.finish()
