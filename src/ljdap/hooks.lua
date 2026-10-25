-- ljdap.hooks – Verwaltung von debug.sethook für den Agenten.
--
-- Ein einziger Hook (H.fn) für "line" und "count":
--   count  -> Socket abfragen (on_count), ausstehende Hook-Änderungen anwenden
--   line   -> nur bei Treffer im Vorfilter (Zeile hat irgendwo einen
--             Haltepunkt, oder es wird gesteppt) on_line(line) aufrufen
--
-- Der Zeilenpfad ist bewusst minimal (zwei Upvalue-Zugriffe): gemessen
-- kostet allein der Aufruf eines leeren Lua-Hooks je Zeile 4–7×, jede
-- weitere Funktion im Pfad vervielfacht das (Konzept 6, Messung M2).
--
-- Coroutinen (gemessen M3): Unter LuaJIT gelten Hooks global für alle
-- Coroutinen. Unter Lua 5.1 gelten sie je Thread: ljdap setzt den Hook in
-- jeder registrierten Coroutine (H.attach, H.set_threads) und in der
-- Haupt-Coroutine nur, wenn gerade dort Code läuft (5.1 liefert kein
-- Handle auf den Hauptthread); sonst wird beim nächsten Hook-Aufruf auf der
-- Haupt-Coroutine nachgeholt.
--
-- Fehlerkonvention: keine Fehler; H.foreign() meldet fremde Hooks.

local H = {}

local on_line, on_count
local want_line, want_count = false, 0
local dirty = false

-- Vorfilter (Upvalues für den heißen Pfad)
local f_lines = {}    -- Zeile -> Anzahl Haltepunkte
local f_step = false  -- es wird gesteppt

local getinfo_hook = debug.gethook
local PER_THREAD = jit == nil   -- Lua 5.1: Hooks je Coroutine
local each_thread = nil         -- function(fn) über alle Coroutinen

local apply

local function hook(ev, line)
  if ev == "line" then
    if f_lines[line] or f_step then on_line(line) end
    return
  end
  if dirty then apply() end
  on_count()
end
H.fn = hook

local function set_on(co)
  if not want_line and want_count <= 0 then
    if co then debug.sethook(co) else debug.sethook() end
  elseif co then
    debug.sethook(co, hook, want_line and "l" or "", want_count)
  else
    debug.sethook(hook, want_line and "l" or "", want_count)
  end
end

apply = function()
  if PER_THREAD and each_thread then
    each_thread(function(co)
      local cur = getinfo_hook(co)
      if cur == nil or cur == hook then set_on(co) end
    end)
  end
  if coroutine.running() ~= nil then
    -- Haupt-Coroutine (Lua 5.1) bzw. global (LuaJIT, über die Coroutine
    -- gesetzt wirkt es dort ebenfalls) – unter 5.1 nachholen
    if PER_THREAD then dirty = true; return false end
  end
  local cur = getinfo_hook()
  if cur and cur ~= hook then dirty = false; return false end -- fremder Hook
  set_on(nil)
  dirty = false
  return true
end

--- Lua 5.1: Iterator über die registrierten Coroutinen festlegen.
function H.set_threads(iter)
  each_thread = iter
end

--- Lua 5.1: Hook in einer neuen Coroutine setzen (LuaJIT: global, nichts zu tun).
function H.attach(co)
  if PER_THREAD and type(co) == "thread" then
    local cur = getinfo_hook(co)
    if cur == nil or cur == hook then set_on(co) end
  end
end

--- Rückrufe festlegen: line(line) und count().
function H.init(line_cb, count_cb)
  on_line, on_count = line_cb, count_cb
end

--- Vorfilter setzen: lines = Tabelle Zeile -> n, stepping = bool.
function H.filter(lines, stepping)
  f_lines = lines or {}
  f_step = stepping and true or false
end

--- Gewünschten Zustand setzen und (wenn möglich) sofort anwenden.
function H.set(line, count)
  line = line and true or false
  count = count or 0
  if line ~= want_line or count ~= want_count or dirty then
    want_line, want_count = line, count
    return apply()
  end
  return true
end

--- Fremder Hook (z. B. Profiler) aktiv?
function H.foreign()
  local cur = getinfo_hook()
  return cur ~= nil and cur ~= hook
end

--- Hook entfernen (nur den eigenen).
function H.remove()
  want_line, want_count, dirty = false, 0, false
  if getinfo_hook() == hook then debug.sethook() end
end

return H
