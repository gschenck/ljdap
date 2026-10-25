local T = dofile("tests/unit/t.lua")
local errors = require("ljdap.errors")
local threads = require("ljdap.threads")
local eq, check, case = T.eq, T.check, T.case

local orig_pcall, orig_xpcall = pcall, xpcall

case("pcall-Hülle verhält sich wie pcall", function()
  local seen = {}
  errors.on_error = function(err, kind) seen[#seen + 1] = kind .. ":" .. tostring(err) end
  errors.wrap_protected(true)
  check(pcall ~= orig_pcall, "ersetzt")
  eq({ pcall(function(a, b) return a + b, "x" end, 2, 3) }, { true, 5, "x" })
  eq({ pcall(function() end) }, { true })
  local ok, err = pcall(error, "boom", 0)
  eq({ ok, err }, { false, "boom" })
  local tab = {}
  ok, err = pcall(error, tab)
  check(not ok and err == tab, "Fehlerobjekt unverändert")
  ok, err = pcall(nil)
  check(not ok and type(err) == "string", "nicht aufrufbar")
  eq(#seen, 3, "Rückruf je Fehler")
  check(seen[1] == "raised:boom", seen[1])
  -- verschachtelt und Schutztiefe
  check(not errors.protected(), "außerhalb")
  pcall(function() check(errors.protected(), "innerhalb") end)
  check(not errors.protected(), "wieder außerhalb nach Fehler/Erfolg")
  -- xpcall: eigener Handler wird weiter aufgerufen
  local r = { xpcall(function() error("x", 0) end, function(e) return "behandelt " .. e end) }
  eq(r, { false, "behandelt x" })
  errors.wrap_protected(false)
  check(pcall == orig_pcall and xpcall == orig_xpcall, "Originale zurück")
  errors.on_error = nil
end)

case("Fehler im Rückruf bricht nicht ab", function()
  errors.on_error = function() error("Rückruf kaputt") end
  errors.wrap_protected(true)
  local ok, err = pcall(error, "a", 0)
  eq({ ok, err }, { false, "a" })
  errors.wrap_protected(false)
  errors.on_error = nil
end)

case("error_text", function()
  eq(errors.error_text("x"), "x")
  eq(errors.error_text(5), "5")
  eq(errors.error_text({}), "(error object is a table value)")
  eq(errors.error_text(setmetatable({}, { __tostring = function() return "Obj" end })), "Obj")
end)

case("Threads: IDs, Liste, Hüllen", function()
  local neu = {}
  threads.install(function(co) neu[#neu + 1] = co end, nil)
  local co = coroutine.create(function(a) local b = coroutine.yield(a + 1); return b * 2 end)
  check(#neu == 1 and neu[1] == co, "create meldet neue Coroutine")
  local id = threads.id(co)
  check(id >= 2, "ID ab 2")
  eq(threads.id(nil), 1)
  eq(select(2, threads.get(1)), true)
  check(threads.get(id) == co, "get")
  eq({ coroutine.resume(co, 1) }, { true, 2 })
  local names = {}
  for _, t in ipairs(threads.list()) do names[t.id] = t.name end
  eq(names[1], "main")
  check(names[id]:find("errors_threads_test%.lua:"), names[id])
  eq({ coroutine.resume(co, 5) }, { true, 10 })
  names = {}
  for _, t in ipairs(threads.list()) do names[t.id] = t.name end
  eq(names[id], nil, "tote Coroutine nicht mehr gelistet")
  -- wrap: Werte und Fehler wie das Original
  local gen = coroutine.wrap(function() coroutine.yield(1); coroutine.yield(2) end)
  eq({ gen(), gen() }, { 1, 2 })
  local bad = coroutine.wrap(function() error("im wrap", 0) end)
  local ok, err = orig_pcall(bad)
  eq({ ok, err }, { false, "im wrap" })
  -- resume registriert fremde Coroutinen
  local fremd = threads.orig.create(function() end)
  coroutine.resume(fremd)
  check(threads.id(fremd) >= 2, "registriert")
  threads.uninstall()
  check(coroutine.create == threads.orig.create, "Originale zurück")
end)

case("debug.traceback-Hülle (Lua 5.1) verhält sich wie das Original", function()
  local orig = debug.traceback
  errors.install_traceback()
  local wrapped = debug.traceback
  debug.traceback = orig
  local co = coroutine.create(function() coroutine.yield() end)
  coroutine.resume(co)
  local obj = {}
  local function probe(tb)
    return { tb(), tb("m"), tb("m", 1), tb("m", 2), tb(co), tb(co, "m"), tb(obj), tb(nil), tb(5) }
  end
  -- beide aus derselben Zeile, damit die Zeilennummern im Traceback gleich sind
  local a, b = probe(orig), probe(wrapped)
  for i = 1, 9 do
    eq(tostring(b[i]), tostring(a[i]), "Aufrufform " .. i)
  end
end)

if jit then
  case("LuaJIT: Coroutine-Körper unter xpcall", function()
    local seen
    errors.on_error = function(err, kind) seen = kind .. ":" .. tostring(err) end
    local f = errors.body_wrap(function(a)
      local x = coroutine.yield(a)
      error("im Körper " .. x, 0)
    end)
    local co = coroutine.create(f)
    eq({ coroutine.resume(co, 1) }, { true, 1 }, "yield über xpcall")
    eq({ coroutine.resume(co, "z") }, { false, "im Körper z" })
    eq(seen, "uncaught:im Körper z")
    errors.on_error = nil
  end)
end

T.finish()
