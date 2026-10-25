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
-- debug.sethook wirkt nur auf die laufende Coroutine. Stand M2 hängt ljdap
-- nur an der Haupt-Coroutine; eine Änderung, die in einer anderen Coroutine
-- angefordert wird (ljdap.poll() aus einer Coroutine), wird beim nächsten
-- Count-Ereignis auf der Haupt-Coroutine nachgeholt. Coroutinen folgen in M3.
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

local apply

local function hook(ev, line)
  if ev == "line" then
    if f_lines[line] or f_step then on_line(line) end
    return
  end
  if dirty and coroutine.running() == nil then apply() end
  on_count()
end
H.fn = hook

apply = function()
  if coroutine.running() ~= nil then dirty = true; return false end
  local cur = getinfo_hook()
  if cur and cur ~= hook then dirty = false; return false end -- fremder Hook
  if not want_line and want_count <= 0 then
    debug.sethook()
  else
    debug.sethook(hook, want_line and "l" or "", want_count)
  end
  dirty = false
  return true
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
