-- ljdap.json – JSON-Kodierer und -Dekodierer für DAP-Nachrichten.
--
-- Ohne Abhängigkeiten, Lua 5.1 und LuaJIT 2.1.
--
-- Fehlerkonvention:
--   encode(v)       -> string; error() bei nicht kodierbaren Werten
--                      (Funktion, Zyklus, gemischte Tabelle): Programmierfehler
--   decode(s, opt)  -> wert | nil, fehlertext; Eingaben vom Netz sind nicht
--                      vertrauenswürdig, daher nie error()
--
-- Abbildung:
--   JSON null    -> in Objekten weggelassen (DAP: null == fehlt), in Arrays
--                   der Platzhalter json.null (Indizes bleiben richtig);
--                   decode(s, {keep_null = true}) behält null auch in Objekten
--   Lua-Tabelle  -> Array, wenn alle Schlüssel ganze Zahlen ≥ 1 sind
--                   (Lücken werden null), sonst Objekt; leere Tabelle -> {}
--                   außer mit json.array({}) markiert -> []
--   Zahlen       -> ganzzahlige Werte (|n| < 2^53) ohne Exponent und ohne
--                   Nachkommastellen, sonst %.17g; NaN/±inf -> null
--   Strings      -> UTF-8; ungültige Bytefolgen werden zu U+FFFD, damit
--                   die Ausgabe gültiges JSON bleibt
--
-- Beispiel:
--   local json = require("ljdap.json")
--   local s = json.encode{ seq = 1, type = "event", body = json.array{} }
--   local t, err = json.decode(s)

local pcall = pcall -- Original; ljdap.errors ersetzt das globale pcall

local M = {}

local byte, char, sub, find, format, gsub =
  string.byte, string.char, string.sub, string.find, string.format, string.gsub
local concat = table.concat
local floor, huge = math.floor, math.huge
local type, pairs, tostring, tonumber, getmetatable, setmetatable, rawget =
  type, pairs, tostring, tonumber, getmetatable, setmetatable, rawget

M.null = setmetatable({}, { __tostring = function() return "null" end })
local null = M.null

local ARRAY_MT = { __jsontype = "array" }
local OBJECT_MT = { __jsontype = "object" }

--- Markiert t (oder eine neue Tabelle) als JSON-Array; nötig für leere Arrays.
function M.array(t) return setmetatable(t or {}, ARRAY_MT) end
--- Markiert t (oder eine neue Tabelle) als JSON-Objekt.
function M.object(t) return setmetatable(t or {}, OBJECT_MT) end

-- Dezimaltrennzeichen der aktuellen C-Locale. Lua 5.1 nutzt für
-- string.format und tonumber die Locale (strtod/printf); ein GUI-Programm mit
-- setlocale(LC_ALL, "de_DE") würde sonst "1,5" erzeugen bzw. "1.5" ablehnen.
local function locale_point()
  return sub(format("%.1f", 0.5), 2, 2)
end

------------------------------------------------------------------------
-- UTF-8-Prüfung
------------------------------------------------------------------------

local REPLACEMENT = "\239\191\189" -- U+FFFD

-- Liefert s unverändert, wenn es gültiges UTF-8 ist, sonst eine Kopie, in
-- der jede ungültige Bytefolge durch U+FFFD ersetzt ist.
local function clean_utf8(s)
  if not find(s, "[\128-\255]") then return s end
  local out, n = nil, 0
  local i, len, last = 1, #s, 1
  while i <= len do
    local c = byte(s, i)
    local need, min
    if c < 0x80 then need = 0
    elseif c >= 0xC2 and c <= 0xDF then need, min = 1, 0x80
    elseif c >= 0xE0 and c <= 0xEF then need, min = 2, 0x800
    elseif c >= 0xF0 and c <= 0xF4 then need, min = 3, 0x10000
    else need = -1 end
    local ok = need >= 0
    if ok and need > 0 then
      if i + need > len then
        ok = false
      else
        local cp = c % (2 ^ (6 - need))
        for k = 1, need do
          local cc = byte(s, i + k)
          if cc < 0x80 or cc > 0xBF then ok = false; break end
          cp = cp * 64 + (cc - 0x80)
        end
        if ok and (cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) then
          ok = false
        end
      end
    end
    if ok then
      i = i + need + 1
    else
      out = out or {}
      n = n + 1; out[n] = sub(s, last, i - 1)
      n = n + 1; out[n] = REPLACEMENT
      i = i + 1
      last = i
    end
  end
  if not out then return s end
  n = n + 1; out[n] = sub(s, last)
  return concat(out, "", 1, n)
end
M._clean_utf8 = clean_utf8

------------------------------------------------------------------------
-- Kodierer
------------------------------------------------------------------------

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\127"] = "\\u007f",
}
for i = 0, 31 do
  local c = char(i)
  if not ESCAPES[c] then ESCAPES[c] = format("\\u%04x", i) end
end

local function encode_string(s)
  if find(s, '[%c"\\\128-\255]') then
    s = gsub(clean_utf8(s), '[%c"\\]', ESCAPES)
  end
  return '"' .. s .. '"'
end

local function encode_number(x)
  if x ~= x or x == huge or x == -huge then return "null" end
  if x == floor(x) and x > -2 ^ 53 and x < 2 ^ 53 then
    -- %.0f statt %d: %d schneidet unter Lua 5.1/Windows (long = 32 Bit) ab
    return format("%.0f", x)
  end
  local s = format("%.17g", x)
  local p = locale_point()
  if p ~= "." then s = gsub(s, "%" .. p, ".") end
  return s
end

local encode_value

-- Untersucht die Schlüssel: liefert "array", n (größter Index) oder "object".
local function classify(t)
  local mt = getmetatable(t)
  local forced = mt and rawget(mt, "__jsontype")
  if forced == "object" then return "object" end
  local max, count = 0, 0
  for k in pairs(t) do
    if type(k) == "number" and k >= 1 and k == floor(k) then
      if k > max then max = k end
      count = count + 1
    else
      if forced == "array" then
        error("json: Array mit Nicht-Index-Schlüssel " .. tostring(k), 0)
      end
      return "object"
    end
  end
  if count == 0 then
    return forced == "array" and "array" or "object", 0
  end
  -- Sehr dünn besetzte Zahlenschlüssel nicht zu riesigen null-Arrays aufblähen
  if max > 2 * count + 16 then
    error("json: dünn besetzte Tabelle (größter Index " .. max .. ")", 0)
  end
  return "array", max
end

local function encode_table(t, buf, n, depth, seen)
  if seen[t] then error("json: zyklische Tabelle", 0) end
  if depth > 200 then error("json: Schachtelung zu tief", 0) end
  seen[t] = true
  local kind, max = classify(t)
  if kind == "array" then
    n = n + 1; buf[n] = "["
    for i = 1, max do
      if i > 1 then n = n + 1; buf[n] = "," end
      n = encode_value(t[i], buf, n, depth + 1, seen)
    end
    n = n + 1; buf[n] = "]"
  else
    n = n + 1; buf[n] = "{"
    local first = true
    for k, v in pairs(t) do
      local tk = type(k)
      if tk == "number" then
        k = encode_number(k)
      elseif tk ~= "string" then
        error("json: Objektschlüssel vom Typ " .. tk, 0)
      end
      if not first then n = n + 1; buf[n] = "," end
      first = false
      n = n + 1; buf[n] = encode_string(k)
      n = n + 1; buf[n] = ":"
      n = encode_value(v, buf, n, depth + 1, seen)
    end
    n = n + 1; buf[n] = "}"
  end
  seen[t] = nil
  return n
end

encode_value = function(v, buf, n, depth, seen)
  local tv = type(v)
  local s
  if v == nil or v == null then s = "null"
  elseif tv == "boolean" then s = v and "true" or "false"
  elseif tv == "number" then s = encode_number(v)
  elseif tv == "string" then s = encode_string(v)
  elseif tv == "table" then return encode_table(v, buf, n, depth, seen)
  else error("json: Wert vom Typ " .. tv .. " nicht kodierbar", 0) end
  n = n + 1; buf[n] = s
  return n
end

--- Kodiert v als JSON-Text. Wirft bei nicht kodierbaren Werten.
function M.encode(v)
  local buf = {}
  local n = encode_value(v, buf, 0, 0, {})
  return concat(buf, "", 1, n)
end

------------------------------------------------------------------------
-- Dekodierer
------------------------------------------------------------------------

local function utf8_char(cp)
  if cp < 0x80 then return char(cp)
  elseif cp < 0x800 then
    return char(0xC0 + floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then
    return char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
  else
    return char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64,
                0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
  end
end

local SIMPLE = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
                 f = "\f", n = "\n", r = "\r", t = "\t" }

local function fail(s, pos, msg)
  error({ format("json: %s bei Position %d", msg, pos) }, 0)
end

local function skip_ws(s, pos)
  local _, e = find(s, "^[ \t\r\n]*", pos)
  return e + 1
end

local function decode_string(s, pos)
  -- pos zeigt auf das öffnende Anführungszeichen
  local buf, n = nil, 0
  local i = pos + 1
  while true do
    local j = find(s, '["\\%z\1-\31]', i)
    if not j then fail(s, pos, "String nicht abgeschlossen") end
    local c = byte(s, j)
    if c == 34 then -- "
      local piece = sub(s, i, j - 1)
      if not buf then return clean_utf8(piece), j + 1 end
      n = n + 1; buf[n] = piece
      return clean_utf8(concat(buf, "", 1, n)), j + 1
    elseif c == 92 then -- \
      buf = buf or {}
      n = n + 1; buf[n] = sub(s, i, j - 1)
      local e = sub(s, j + 1, j + 1)
      if SIMPLE[e] then
        n = n + 1; buf[n] = SIMPLE[e]
        i = j + 2
      elseif e == "u" then
        local hex = sub(s, j + 2, j + 5)
        if not find(hex, "^%x%x%x%x$") then fail(s, j, "ungültiges \\u-Escape") end
        local cp = tonumber(hex, 16)
        i = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          local lo = find(s, "^\\u[dD][c-fC-F]%x%x", i) and tonumber(sub(s, i + 2, i + 5), 16)
          if lo then
            cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
            i = i + 6
          else
            cp = 0xFFFD
          end
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          cp = 0xFFFD
        end
        n = n + 1; buf[n] = utf8_char(cp)
      else
        fail(s, j, "ungültiges Escape")
      end
    else
      fail(s, j, "Steuerzeichen im String")
    end
  end
end

local function decode_number(s, pos)
  local _, e = find(s, "^-?%d+", pos)
  if not e then fail(s, pos, "unerwartetes Zeichen") end
  local _, e2 = find(s, "^%.%d+", e + 1)
  if e2 then e = e2 end
  _, e2 = find(s, "^[eE][-+]?%d+", e + 1)
  if e2 then e = e2 end
  local text = sub(s, pos, e)
  local v = tonumber(text)
  if not v then
    -- Lua 5.1: tonumber über strtod hängt von der Locale ab
    local p = locale_point()
    v = tonumber((gsub(text, "%.", p)))
  end
  if not v then fail(s, pos, "ungültige Zahl") end
  return v, e + 1
end

local decode_value

local function decode_array(s, pos, depth, opt)
  local t, n = M.array(), 0
  pos = skip_ws(s, pos + 1)
  if sub(s, pos, pos) == "]" then return t, pos + 1 end
  while true do
    local v
    v, pos = decode_value(s, pos, depth + 1, opt)
    n = n + 1
    t[n] = v
    pos = skip_ws(s, pos)
    local c = sub(s, pos, pos)
    if c == "]" then return t, pos + 1 end
    if c ~= "," then fail(s, pos, "',' oder ']' erwartet") end
    pos = skip_ws(s, pos + 1)
  end
end

local function decode_object(s, pos, depth, opt)
  local t = {}
  pos = skip_ws(s, pos + 1)
  if sub(s, pos, pos) == "}" then return t, pos + 1 end
  while true do
    if sub(s, pos, pos) ~= '"' then fail(s, pos, "Schlüssel erwartet") end
    local k
    k, pos = decode_string(s, pos)
    pos = skip_ws(s, pos)
    if sub(s, pos, pos) ~= ":" then fail(s, pos, "':' erwartet") end
    local v
    v, pos = decode_value(s, skip_ws(s, pos + 1), depth + 1, opt)
    if v ~= null or opt.keep_null then t[k] = v end
    pos = skip_ws(s, pos)
    local c = sub(s, pos, pos)
    if c == "}" then return t, pos + 1 end
    if c ~= "," then fail(s, pos, "',' oder '}' erwartet") end
    pos = skip_ws(s, pos + 1)
  end
end

decode_value = function(s, pos, depth, opt)
  if depth > 200 then fail(s, pos, "Schachtelung zu tief") end
  local c = sub(s, pos, pos)
  if c == "{" then return decode_object(s, pos, depth, opt)
  elseif c == "[" then return decode_array(s, pos, depth, opt)
  elseif c == '"' then return decode_string(s, pos)
  elseif sub(s, pos, pos + 3) == "true" then return true, pos + 4
  elseif sub(s, pos, pos + 4) == "false" then return false, pos + 5
  elseif sub(s, pos, pos + 3) == "null" then return null, pos + 4
  elseif c == "" then fail(s, pos, "unerwartetes Ende")
  else return decode_number(s, pos) end
end

local NO_OPT = {}

--- Dekodiert JSON-Text. Liefert wert oder nil, fehlertext.
-- opt.keep_null: null in Objekten als json.null behalten.
function M.decode(s, opt)
  if type(s) ~= "string" then return nil, "json: Text erwartet, " .. type(s) .. " erhalten" end
  local ok, v, pos = pcall(decode_value, s, skip_ws(s, 1), 0, opt or NO_OPT)
  if not ok then
    if type(v) == "table" then return nil, v[1] end
    return nil, "json: " .. tostring(v)
  end
  pos = skip_ws(s, pos)
  if pos <= #s then return nil, format("json: überzählige Zeichen bei Position %d", pos) end
  return v
end

return M
