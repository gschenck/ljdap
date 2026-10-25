-- ljdap.errors – Anhalten bei Fehlern.
--
-- Fehlerarten (DAP-Filter):
--   raised    jeder Fehler in pcall/xpcall: ljdap ersetzt pcall/xpcall durch
--             Hüllen mit eigenem Fehler-Handler, der am Fehlerort aufgerufen
--             wird (Stack noch intakt)
--   uncaught  Fehler, die das Programm beenden:
--             LuaJIT:  bei `-l ljdap` führt ljdap das Skript selbst unter
--                      xpcall aus (E.run_script), luajit.c ruft kein Lua
--             Lua 5.1: lua.c ruft für den Traceback das globale
--                      debug.traceback – ljdap ersetzt es; ob der Fehler
--                      ungeschützt ist, zeigt die Schutztiefe der pcall-Hüllen
--             Coroutinen (nur LuaJIT): Körper unter xpcall (body_wrap);
--                      Lua 5.1 erlaubt kein yield über xpcall hinweg
--
-- E.on_error(err, kind, marker) setzt die Session; marker ist die Funktion
-- direkt unter dem Fehlerort (für die Stack-Ebenen).
--
-- Fehlerkonvention: die Hüllen verhalten sich wie pcall/xpcall; Fehler im
-- Rückruf werden geschluckt (nie Programmabbruch durch den Debugger).

local E = {}

local orig_pcall, orig_xpcall = pcall, xpcall
local orig_traceback = debug.traceback
local running = coroutine.running
local unpack, select = unpack, select

local is_luajit = jit ~= nil
E.is_luajit = is_luajit

E.on_error = nil

local function notify(err, kind, marker)
  local cb = E.on_error
  if cb then orig_pcall(cb, err, kind, marker) end
end

------------------------------------------------------------------------
-- Schutztiefe je Thread
------------------------------------------------------------------------

local depth = setmetatable({}, { __mode = "k" })
local main_depth = 0

local function add_depth(d)
  local co = running()
  if co then depth[co] = (depth[co] or 0) + d
  else main_depth = main_depth + d end
end

--- Liegt der laufende Code in einem pcall/xpcall (über die Hüllen)?
function E.protected()
  local co = running()
  if co then return (depth[co] or 0) > 0 end
  return main_depth > 0
end

------------------------------------------------------------------------
-- pcall/xpcall-Hüllen
------------------------------------------------------------------------

local raised_handler
raised_handler = function(err)
  notify(err, "raised", raised_handler)
  return err
end

local function finish(...)
  add_depth(-1)
  return ...
end

local wrap_pcall, wrap_xpcall
if is_luajit then
  wrap_pcall = function(f, ...)
    add_depth(1)
    return finish(orig_xpcall(f, raised_handler, ...))
  end
  wrap_xpcall = function(f, msgh, ...)
    local h
    h = function(err)
      notify(err, "raised", h)
      return msgh(err)
    end
    add_depth(1)
    return finish(orig_xpcall(f, h, ...))
  end
else
  -- Lua 5.1: xpcall kennt keine Argumente
  wrap_pcall = function(f, ...)
    add_depth(1)
    if select("#", ...) == 0 then return finish(orig_xpcall(f, raised_handler)) end
    local n, args = select("#", ...), { ... }
    return finish(orig_xpcall(function() return f(unpack(args, 1, n)) end, raised_handler))
  end
  wrap_xpcall = function(f, msgh)
    local h
    h = function(err)
      notify(err, "raised", h)
      return msgh(err)
    end
    add_depth(1)
    return finish(orig_xpcall(f, h))
  end
end

local wrapped = false

--- pcall/xpcall-Hüllen ein- (true) oder ausschalten.
function E.wrap_protected(on)
  if on and not wrapped then
    pcall, xpcall = wrap_pcall, wrap_xpcall -- luacheck: ignore (globale Ersetzung gewollt)
    wrapped = true
  elseif not on and wrapped then
    if pcall == wrap_pcall then pcall = orig_pcall end
    if xpcall == wrap_xpcall then xpcall = orig_xpcall end
    wrapped = false
  end
end

------------------------------------------------------------------------
-- Ungefangene Fehler
------------------------------------------------------------------------

-- Lua 5.1: lua.c ruft bei einem Fehler im Hauptchunk debug.traceback(msg, 2)
-- aus seinem C-Handler auf, noch am Fehlerort.
-- Die Hülle muss sich für Benutzercode wie das Original verhalten (Test
-- errors_threads_test): Thread-Form unverändert durchreichen, ohne
-- Argumente keine Meldungszeile, sonst Ebene um die Hülle verschieben.
local tb_wrapper
tb_wrapper = function(...)
  local n = select("#", ...)
  local msg, level = ...
  if type(msg) == "thread" then
    local r = orig_traceback(...) -- Ebenen gelten im anderen Thread
    return r
  end
  if n >= 1 and running() == nil and main_depth == 0 then
    local caller = debug.getinfo(2, "S")
    if caller and caller.what == "C" then notify(msg, "uncaught", tb_wrapper) end
  end
  if n == 0 then
    local r = orig_traceback("", 2)
    return (r:gsub("^\n", ""))
  end
  local r = orig_traceback(msg, (tonumber(level) or 1) + 1)
  return r
end

--- Lua 5.1: debug.traceback ersetzen (für ungefangene Fehler im Hauptchunk).
function E.install_traceback()
  if not is_luajit and debug.traceback == orig_traceback then
    debug.traceback = tb_wrapper
  end
end

--- LuaJIT: Coroutine-Körper unter xpcall (ungefangene Fehler in Coroutinen).
function E.body_wrap(f)
  local h
  h = function(err)
    notify(err, "uncaught", h)
    return err
  end
  local function done(ok, ...)
    if ok then return ... end
    error((...), 0)
  end
  return function(...)
    return done(orig_xpcall(f, h, ...))
  end
end

local function error_text(err)
  if type(err) == "string" or type(err) == "number" then return tostring(err) end
  local mt = getmetatable(err)
  if mt and mt.__tostring then
    local ok, s = orig_pcall(tostring, err)
    if ok then return s end
  end
  return "(error object is a " .. type(err) .. " value)"
end
E.error_text = error_text

--- LuaJIT bei `-l ljdap`: führt das Skript unter xpcall aus und beendet den
-- Prozess wie luajit.c (Rückgabe 0 bzw. 1 mit Traceback auf stderr).
function E.run_script(path, args, progname)
  local fn, err = loadfile(path)
  if not fn then
    io.stderr:write(progname, ": ", tostring(err), "\n")
    io.stderr:flush()
    os.exit(1, true)
  end
  local h
  h = function(e)
    notify(e, "uncaught", h)
    return orig_traceback(error_text(e), 2)
  end
  local ok, res = orig_xpcall(function() return fn(unpack(args, 1, args.n)) end, h)
  io.stdout:flush()
  if not ok then
    io.stderr:write(progname, ": ", tostring(res), "\n")
    io.stderr:flush()
    os.exit(1, true)
  end
  os.exit(0, true)
end

return E
