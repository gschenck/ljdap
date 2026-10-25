-- ljdap.threads – Coroutinen als DAP-Threads.
--
-- Haupt-Coroutine = Thread 1. Jede Coroutine bekommt beim ersten Kontakt
-- (create/wrap oder erstes resume) eine ID; Zuordnung über schwache
-- Tabellen, tote Coroutinen verschwinden mit dem GC.
--
-- T.install() ersetzt coroutine.create/wrap/resume:
--   create  registriert und meldet die neue Coroutine (on_new, z. B. Hook
--           setzen unter Lua 5.1); optional wird der Körper umhüllt
--           (body_wrap, LuaJIT: Fehler-Halt in Coroutinen)
--   resume  registriert Coroutinen, die vor ljdap entstanden sind
-- Grenze: Code, der coroutine.resume/wrap vor dem Laden von ljdap in eine
-- lokale Variable kopiert hat, wird nicht erreicht.
--
-- Fehlerkonvention: keine Fehler; Wrapper verhalten sich wie die Originale.

local T = {}

local orig = {
  create = coroutine.create, wrap = coroutine.wrap, resume = coroutine.resume,
  running = coroutine.running, status = coroutine.status,
}
T.orig = orig

local ids = setmetatable({}, { __mode = "k" })    -- co -> id
local byid = setmetatable({}, { __mode = "v" })   -- id -> co
local names = setmetatable({}, { __mode = "k" })  -- co -> Anzeigename
local next_id = 2
local on_new, body_wrap

--- Registriert co (f = Körperfunktion, nur für den Namen); liefert die ID.
function T.register(co, f)
  local id = ids[co]
  if id then return id end
  id = next_id
  next_id = next_id + 1
  ids[co] = id
  byid[id] = co
  local where = ""
  if type(f) == "function" then
    local i = debug.getinfo(f, "S")
    if i and i.what ~= "C" then where = (" (%s:%d)"):format(i.short_src, i.linedefined) end
  end
  names[co] = "Coroutine " .. id .. where
  if on_new then on_new(co) end
  return id
end

--- ID eines Threads (nil = Haupt-Coroutine = 1).
function T.id(co)
  if co == nil then return 1 end
  return ids[co] or T.register(co)
end

--- Coroutine zu einer ID; für 1 liefert die Funktion nil, true.
function T.get(id)
  id = tonumber(id)
  if id == 1 then return nil, true end
  return byid[id], false
end

--- Alle lebenden Threads als DAP-Liste, nach ID sortiert.
function T.list()
  local out = { { id = 1, name = "main" } }
  local tmp = {}
  for co, id in pairs(ids) do
    if orig.status(co) ~= "dead" then tmp[#tmp + 1] = { id = id, name = names[co] } end
  end
  table.sort(tmp, function(a, b) return a.id < b.id end)
  for _, t in ipairs(tmp) do out[#out + 1] = t end
  return out
end

--- Alle registrierten lebenden Coroutinen (für Hooks).
function T.each(fn)
  for co in pairs(ids) do
    if orig.status(co) ~= "dead" then fn(co) end
  end
end

local function wrap_results(ok, ...)
  if ok then return ... end
  error((...), 0)
end

local installed = false

--- Ersetzt die coroutine-Funktionen. new_cb(co): neue Coroutine;
-- wrap_body(f) -> f': Körper umhüllen (oder nil).
function T.install(new_cb, wrap_body)
  on_new, body_wrap = new_cb, wrap_body
  if installed then return end
  installed = true
  coroutine.create = function(f)
    local g = f
    if body_wrap and type(f) == "function" then g = body_wrap(f) end
    local co = orig.create(g)
    T.register(co, f)
    return co
  end
  coroutine.wrap = function(f)
    local co = coroutine.create(f)
    return function(...)
      return wrap_results(orig.resume(co, ...))
    end
  end
  coroutine.resume = function(co, ...)
    if type(co) == "thread" and not ids[co] then T.register(co) end
    return orig.resume(co, ...)
  end
end

--- Stellt die Originale wieder her (nur wenn noch unsere Hüllen aktiv sind).
function T.uninstall()
  if not installed then return end
  installed = false
  coroutine.create, coroutine.wrap, coroutine.resume = orig.create, orig.wrap, orig.resume
end

return T
