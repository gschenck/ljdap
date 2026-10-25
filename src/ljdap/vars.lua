-- ljdap.vars – Variablen-Referenzen, Anzeige von Werten, Kinder von Tabellen.
--
-- Referenzen (variablesReference) gelten nur während eines Halts und
-- werden beim Weiterlaufen verworfen (refs:clear()).
--
-- Anzeige ruft __tostring nur geschützt (pcall) auf; der Aufrufer sorgt
-- dafür, dass dabei keine Hooks wieder eintreten (Sperre in der Session).
-- Tabellen werden roh gelesen (next/rawget), __index/__pairs nicht benutzt.
--
-- Fehlerkonvention: keine Fehler nach außen; nicht lesbare Werte erscheinen
-- als Text "<Fehler: …>".

local pcall = pcall -- Original; ljdap.errors ersetzt das globale pcall

local M = {}

local MAX_STRING = 200
local COUNT_LIMIT = 1000

local has_ffi, ffi = pcall(require, "ffi")
if not has_ffi then ffi = nil end

------------------------------------------------------------------------
-- Referenzen
------------------------------------------------------------------------

local Refs = {}
Refs.__index = Refs

function M.refs()
  return setmetatable({ items = {}, n = 0 }, Refs)
end

function Refs:add(item)
  self.n = self.n + 1
  self.items[self.n] = item
  return self.n
end

function Refs:get(id)
  return self.items[tonumber(id) or -1]
end

function Refs:clear()
  self.items = {}
  self.n = 0
end

------------------------------------------------------------------------
-- Anzeige
------------------------------------------------------------------------

local function fmt_number(v)
  if v ~= v then return "nan" end
  if v == math.huge then return "inf" end
  if v == -math.huge then return "-inf" end
  if v == math.floor(v) and v > -1e15 and v < 1e15 then
    return string.format("%.0f", v)
  end
  local s = string.format("%.14g", v)
  if tonumber(s) ~= v then s = string.format("%.17g", v) end
  return (s:gsub(",", "."))
end
M.fmt_number = fmt_number

-- Länge einer gültigen UTF-8-Folge ab Lead-Byte, 0 = ungültig
local function seq_len(s, i)
  local c = s:byte(i)
  local n
  if c < 0x80 then return 1
  elseif c >= 0xC2 and c <= 0xDF then n = 2
  elseif c >= 0xE0 and c <= 0xEF then n = 3
  elseif c >= 0xF0 and c <= 0xF4 then n = 4
  else return 0 end
  for k = 1, n - 1 do
    local cc = s:byte(i + k)
    if not cc or cc < 0x80 or cc > 0xBF then return 0 end
  end
  return n
end

local ESC = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ['"'] = '\\"', ["\\"] = "\\\\",
              ["\0"] = "\\0" }

--- String als Lua-Literal: Steuerzeichen escaped, ungültiges UTF-8 als
-- \xNN, gekürzt auf max Zeichen (an Zeichengrenze).
function M.quote(s, max)
  max = max or MAX_STRING
  local out, n, chars, i, len = {}, 0, 0, 1, #s
  while i <= len do
    if chars >= max then
      n = n + 1
      out[n] = "…"
      break
    end
    local c = s:sub(i, i)
    local b = s:byte(i)
    local step = 1
    if ESC[c] then
      n = n + 1; out[n] = ESC[c]
    elseif b < 32 or b == 127 then
      n = n + 1; out[n] = string.format("\\%d", b)
    elseif b < 128 then
      n = n + 1; out[n] = c
    else
      local k = seq_len(s, i)
      if k == 0 then
        n = n + 1; out[n] = string.format("\\x%02X", b)
      else
        n = n + 1; out[n] = s:sub(i, i + k - 1)
        step = k
      end
    end
    chars = chars + 1
    i = i + step
  end
  local r = '"' .. table.concat(out, "", 1, n) .. '"'
  if i <= len then r = r .. string.format(" (%d Bytes)", len) end
  return r
end

local function safe_tostring(v)
  local ok, s = pcall(tostring, v)
  if ok and type(s) == "string" then return s end
  return "<Fehler in __tostring: " .. tostring(s) .. ">"
end

local function count_entries(t)
  local n = 0
  for _ in next, t do
    n = n + 1
    if n >= COUNT_LIMIT then return COUNT_LIMIT .. "+" end
  end
  return tostring(n)
end

--- Liefert anzeige, typname, aufklappbar(bool).
function M.format(v)
  local tv = type(v)
  if tv == "nil" then return "nil", "nil", false
  elseif tv == "boolean" then return tostring(v), "boolean", false
  elseif tv == "number" then return fmt_number(v), "number", false
  elseif tv == "string" then return M.quote(v), "string", false
  elseif tv == "table" then
    local mt = debug.getmetatable(v)
    local s
    if mt and rawget(mt, "__tostring") then
      s = safe_tostring(v)
    else
      s = safe_tostring(v)
    end
    local name = mt and rawget(mt, "__name")
    local tn = type(name) == "string" and name or "table"
    return s .. " [" .. count_entries(v) .. "]", tn, true
  elseif tv == "function" then
    local i = debug.getinfo(v, "S")
    if i.what == "C" then return "function [C]", "function", false end
    return ("function %s:%d"):format(i.short_src, i.linedefined), "function", false
  elseif tv == "cdata" and ffi then
    local ok, ct = pcall(ffi.typeof, v)
    return safe_tostring(v), ok and tostring(ct) or "cdata", false
  end
  local mt = debug.getmetatable(v)
  return safe_tostring(v), tv, mt ~= nil
end

------------------------------------------------------------------------
-- Kinder
------------------------------------------------------------------------

local function is_ident(s)
  return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function key_name(k)
  if is_ident(k) then return k end
  local s = M.format(k)
  return "[" .. s .. "]"
end
M.key_name = key_name

local TYPE_ORDER = { number = 1, string = 2, boolean = 3 }

local function key_less(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then
    return (TYPE_ORDER[ta] or 9) < (TYPE_ORDER[tb] or 9) or
           ((TYPE_ORDER[ta] or 9) == (TYPE_ORDER[tb] or 9) and ta < tb)
  end
  if ta == "number" or ta == "string" then return a < b end
  return safe_tostring(a) < safe_tostring(b)
end

--- Sortierte Schlüssel einer Tabelle (roh).
function M.sorted_keys(t)
  local keys, n = {}, 0
  for k in next, t do
    n = n + 1
    keys[n] = k
  end
  table.sort(keys, key_less)
  return keys, n
end

--- DAP-Variable für name/wert; erzeugt bei Bedarf eine Kind-Referenz.
-- fr: Rahmen, in dem der Wert gefunden wurde (für evaluate/setVariable).
function M.variable(refs, name, v, fr)
  local s, tn, expandable = M.format(v)
  local ref = 0
  if expandable then
    ref = refs:add({ kind = "value", value = v, fr = fr })
  end
  return { name = name, value = s, type = tn, variablesReference = ref }
end

--- Kinder eines Werts (Tabelle, Metatabelle): DAP-Variable[].
-- item.keys wird beim ersten Aufruf zwischengespeichert (Paging).
function M.children(refs, item, start, count)
  local v = item.value
  local out = {}
  if type(v) == "table" then
    if not item.keys then item.keys, item.nkeys = M.sorted_keys(v) end
    local first = (tonumber(start) or 0) + 1
    local last = item.nkeys
    if tonumber(count) and count > 0 then last = math.min(last, first + count - 1) end
    item.keymap = item.keymap or {}
    for i = first, last do
      local k = item.keys[i]
      local name = key_name(k)
      item.keymap[name] = k -- für setVariable: Anzeigename -> Originalschlüssel
      out[#out + 1] = M.variable(refs, name, rawget(v, k), item.fr)
    end
    if first == 1 then
      local mt = debug.getmetatable(v)
      if mt then out[#out + 1] = M.variable(refs, "[metatable]", mt, item.fr) end
    end
  else
    local mt = debug.getmetatable(v)
    if mt then out[#out + 1] = M.variable(refs, "[metatable]", mt, item.fr) end
  end
  return out
end

return M
