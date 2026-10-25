-- ljdap.eval – Ausdrücke und Anweisungen im Kontext eines Stack-Rahmens.
--
-- Rahmen-Zugriff über ein Accessor-Objekt (aus der Session):
--   acc.info(what)        -> debug.getinfo des Rahmens
--   acc.getlocal(i)       -> name, wert   (i < 0: Varargs, nur LuaJIT)
--   acc.setlocal(i, v)
-- Ohne Accessor wird global (in _G) ausgewertet.
--
-- Umgebung per setfenv: Lesen Locals -> Upvalues -> fenv der Funktion
-- (-> _G über deren __index); Varargs als Pseudovariable `vararg`
-- (Tabelle). Schreiben auf Locals/Upvalues wird gesammelt und nach dem Lauf
-- per setlocal/setupvalue zurückgeschrieben, sonst geht es in die fenv.
--
-- Zuerst als Ausdruck ("return " .. text), sonst als Anweisung.
--
-- Fehlerkonvention: E.run -> true, ergebnisse (Tabelle mit n) | false, text.

local E = {}

local pcall = pcall -- Original, nicht die Hülle aus ljdap.errors
local loadstring, setfenv, getfenv = loadstring, setfenv, getfenv
local getupvalue, setupvalue = debug.getupvalue, debug.setupvalue

local function pack(...)
  return { n = select("#", ...), ... }
end

local function compile(text)
  local fn = loadstring("return " .. text, "=(auswertung)")
  if fn then return fn end
  local err
  fn, err = loadstring(text, "=(auswertung)")
  if not fn then return nil, (err:gsub("^%(auswertung%):1: ", "")) end
  return fn
end
E.compile = compile

-- Baut die Umgebung; liefert env, commit (Rückschreiben).
local function frame_env(acc)
  local locals, ups = {}, {}
  local i = 1
  while true do
    local name, v = acc.getlocal(i)
    if not name then break end
    if name:sub(1, 1) ~= "(" then locals[name] = { i = i, v = v } end -- spätere verdecken
    i = i + 1
  end
  local va
  if acc.getlocal(-1) ~= nil then
    va = {}
    local k = 1
    while true do
      local name, v = acc.getlocal(-k)
      if not name then break end
      va[k] = v
      k = k + 1
    end
    va.n = k - 1
  end
  local info = acc.info("f")
  local func = info and info.func
  if func then
    local u = 1
    while true do
      local name, v = getupvalue(func, u)
      if not name then break end
      if name ~= "" and not locals[name] then ups[name] = { u = u, v = v } end
      u = u + 1
    end
  end
  local fenv = (func and getfenv(func)) or _G
  local dirty = {}
  local env = setmetatable({}, {
    __index = function(_, k)
      local l = locals[k]
      if l then return l.v end
      local up = ups[k]
      if up then return up.v end
      if k == "vararg" and va then return va end
      return fenv[k]
    end,
    __newindex = function(_, k, v)
      local l = locals[k]
      if l then l.v = v; dirty[#dirty + 1] = l; return end
      local up = ups[k]
      if up then up.v = v; dirty[#dirty + 1] = up; return end
      fenv[k] = v
    end,
  })
  local function commit()
    for _, d in ipairs(dirty) do
      if d.i then acc.setlocal(d.i, d.v)
      elseif func then setupvalue(func, d.u, d.v) end
    end
  end
  return env, commit, { locals = locals, ups = ups, func = func }
end
E.frame_env = frame_env

--- Wertet text aus. acc = Rahmen-Accessor oder nil (global).
function E.run(text, acc)
  if type(text) ~= "string" or text:match("^%s*$") then
    return false, "leerer Ausdruck"
  end
  local fn, err = compile(text)
  if not fn then return false, err end
  local env, commit = _G, nil
  if acc then env, commit = frame_env(acc) end
  setfenv(fn, env)
  local r = pack(pcall(fn))
  if not r[1] then
    local msg = tostring(r[2])
    return false, (msg:gsub("^%(auswertung%):%d+: ", ""))
  end
  if commit then commit() end
  local res = { n = r.n - 1 }
  for k = 2, r.n do res[k - 1] = r[k] end
  return true, res
end

return E
