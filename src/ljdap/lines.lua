-- ljdap.lines – gültige Haltepunktzeilen einer Lua-Datei.
--
-- Übersetzt den Quelltext (ohne ihn auszuführen) und sammelt die Zeilen,
-- auf denen Code steht, aus allen Funktionen des Chunks:
--   LuaJIT:  jit.util.funcinfo/funck (Kind-Prototypen)
--   Lua 5.1: string.dump lesen (Zeilentabellen aller Prototypen)
-- Damit lassen sich Haltepunkte auf Kommentar- und Leerzeilen sofort auf
-- die nächste Codezeile schieben, auch in noch nicht aufgerufenen Funktionen.
--
-- Fehlerkonvention: lines.of_file(path) -> set | nil, err.

local pcall = pcall -- Original; ljdap.errors ersetzt das globale pcall

local M = {}

local has_jit_util, ju = pcall(require, "jit.util")
if not has_jit_util then ju = nil end

local function collect_luajit(fn, set)
  local function walk(f)
    local fi = ju.funcinfo(f)
    for pc = 1, (fi.bytecodes or 1) - 1 do
      local li = ju.funcinfo(f, pc).currentline
      if li and li > 0 then set[li] = true end
    end
    local k = -1
    while true do
      local c = ju.funck(f, k)
      if c == nil then break end
      if type(c) == "proto" then walk(c) end
      k = k - 1
    end
  end
  walk(fn)
end

-- Leser für das Format von string.dump in Lua 5.1 (lundump.c).
local function collect_dump51(fn, set)
  local s = string.dump(fn)
  local pos = 1
  local function byte()
    local b = s:byte(pos)
    pos = pos + 1
    return b
  end
  if s:sub(1, 5) ~= "\27Lua\81" then return nil, "unbekanntes Dump-Format" end
  pos = 7
  local little = byte() == 1
  local sz_int, sz_size, sz_ins, sz_num = byte(), byte(), byte(), byte()
  pos = pos + 1 -- integral flag

  local function uint(n)
    local v, mul = 0, 1
    if little then
      for i = 0, n - 1 do v = v + s:byte(pos + i) * mul; mul = mul * 256 end
    else
      for i = n - 1, 0, -1 do v = v + s:byte(pos + i) * mul; mul = mul * 256 end
    end
    pos = pos + n
    return v
  end
  local function int() return uint(sz_int) end
  local function str()
    local n = uint(sz_size)
    pos = pos + n
  end

  local function func()
    str()                    -- source
    int(); int()             -- linedefined, lastlinedefined
    pos = pos + 4            -- nups, numparams, is_vararg, maxstacksize
    local ncode = int()
    pos = pos + ncode * sz_ins
    local nk = int()
    for _ = 1, nk do
      local t = byte()
      if t == 1 then pos = pos + 1
      elseif t == 3 then pos = pos + sz_num
      elseif t == 4 then str()
      elseif t ~= 0 then error("unbekannter Konstantentyp " .. t) end
    end
    local np = int()
    for _ = 1, np do func() end
    local nl = int()
    for _ = 1, nl do
      local li = int()
      if li > 0 then set[li] = true end
    end
    local nloc = int()
    for _ = 1, nloc do str(); int(); int() end
    local nup = int()
    for _ = 1, nup do str() end
  end
  local ok, err = pcall(func)
  if not ok then return nil, err end
  return true
end

--- Gültige Zeilen des übersetzten Chunks fn: Tabelle zeile -> true.
function M.of_function(fn)
  local set = {}
  if ju then
    local ok, err = pcall(collect_luajit, fn, set)
    if not ok then return nil, err end
    return set
  end
  local ok, err = collect_dump51(fn, set)
  if not ok then return nil, err end
  return set
end

--- Gültige Zeilen einer Datei (Lua-Quelltext). Liefert set | nil, err.
function M.of_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local src = f:read("*a")
  f:close()
  if src:sub(1, 3) == "\239\187\191" then src = src:sub(4) end -- UTF-8-BOM
  if src:sub(1, 1) == "#" then src = "--" .. src end         -- Shebang
  local fn, cerr = loadstring(src, "@" .. path)
  if not fn then return nil, cerr end
  return M.of_function(fn)
end

--- Nächste gültige Zeile ≥ line innerhalb von max_shift Zeilen, sonst nil.
function M.adjust(set, line, max_shift)
  for l = line, line + (max_shift or 10) do
    if set[l] then return l end
  end
  return nil
end

return M
