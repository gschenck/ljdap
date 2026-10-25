-- ljdap 0.1.0-dev – DAP-Server in reinem Lua für LuaJIT 2.1 und Lua 5.1
-- https://github.com/gschenck/ljdap – MIT-Lizenz, (c) 2026 Gunter Schenck
-- Ein-Datei-Version, erzeugt von tools/amalgamate.lua aus src/ljdap/ – nicht von Hand ändern.
-- Einbindung: luajit -l ljdap skript.lua   bzw.   require("ljdap").start{ port = 4711 }

package.preload["ljdap.version"] = function(...)
-- ljdap.version – Versionsstand (SemVer). Wird bei jedem Release angepasst.
return "0.1.0-dev"
end

package.preload["ljdap.json"] = function(...)
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
end

package.preload["ljdap.transport"] = function(...)
-- ljdap.transport – TCP-Server (nicht blockierend) und Nachrichtenrahmen.
--
-- Backends in dieser Reihenfolge (opt.backend = "auto"):
--   "posix"     LuaJIT-FFI, Linux und macOS
--   "windows"   LuaJIT-FFI, ws2_32
--   "luasocket" falls ohne FFI (PUC-Lua 5.1) und LuaSocket vorhanden
-- Dazu transport.stdio() für den stdio-Modus (nur blockierend).
--
-- Alle FFI-Deklarationen tragen eigene Namen (ljdap_*, Funktionen per
-- __asm__-Alias), damit sie nicht mit cdefs des untersuchten Programms
-- kollidieren (z. B. F7Cmdr net/sock.lua). Die Doppelung zu F7Cmdr ist
-- gewollt: der Agent muss ohne Abhängigkeiten laufen.
--
-- Fehlerkonvention: alle Funktionen liefern wert | nil, fehlertext; nie error().
--
-- Schnittstelle:
--   srv = transport.listen(host, port, opt)   -> Server | nil, err
--   srv:accept()        -> Verbindung | nil (keine wartend) | nil, err
--   srv:close()
--   con:receive()       -> daten | "" (nichts da) | nil, "closed"/err
--   con:send(data)      -> true | nil, err (schreibt alles, wartet bei Bedarf)
--   con:wait(ms)        -> true, wenn lesbar (oder geschlossen); ms < 0: ewig
--   con:close()
--   f = transport.framer(); f:feed(daten); f:next() -> body | nil | nil, err
--   transport.frame(body) -> "Content-Length: n\r\n\r\n" .. body

local pcall = pcall -- Original; ljdap.errors ersetzt das globale pcall

local M = {}

local SEND_TIMEOUT_MS = 10000
local CHUNK = 65536

------------------------------------------------------------------------
-- Nachrichtenrahmen (Content-Length)
------------------------------------------------------------------------

local MAX_BODY = 64 * 1024 * 1024

--- Erzeugt den Rahmen für einen JSON-Text.
function M.frame(body)
  return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

local Framer = {}
Framer.__index = Framer

--- Neuer Rahmenleser; puffert Teilpakete.
function M.framer()
  return setmetatable({ buf = "", need = nil }, Framer)
end

function Framer:feed(data)
  if data and data ~= "" then self.buf = self.buf .. data end
end

--- Liefert den nächsten vollständigen Body, nil wenn noch unvollständig,
-- oder nil, err bei kaputtem Kopf (der Puffer wird dann verworfen).
function Framer:next()
  local buf = self.buf
  if not self.need then
    local hend = buf:find("\r\n\r\n", 1, true)
    if not hend then
      if #buf > 8192 then
        self.buf = ""
        return nil, "Kopf zu lang oder ohne Content-Length"
      end
      return nil
    end
    local head = buf:sub(1, hend - 1)
    local len
    for line in (head .. "\r\n"):gmatch("(.-)\r\n") do
      local k, v = line:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
      if k and k:lower() == "content-length" then len = tonumber(v) end
    end
    if not len or len < 0 or len ~= math.floor(len) or len > MAX_BODY then
      self.buf = ""
      return nil, "ungültiger Kopf: " .. head:sub(1, 200)
    end
    self.need = len
    buf = buf:sub(hend + 4)
    self.buf = buf
  end
  if #buf < self.need then return nil end
  local body = buf:sub(1, self.need)
  self.buf = buf:sub(self.need + 1)
  self.need = nil
  return body
end

------------------------------------------------------------------------
-- FFI-Backends
------------------------------------------------------------------------

local has_ffi, ffi = pcall(require, "ffi")
if not has_ffi then ffi = nil end
local bit = has_ffi and require("bit") or nil

local function cdef_once(check_type, decl)
  if not pcall(ffi.typeof, check_type) then ffi.cdef(decl) end
end

local posix, windows -- Backend-Tabellen, lazy aufgebaut

local function build_posix()
  local os_name = ffi.os
  local K
  if os_name == "Linux" then
    K = { SOL_SOCKET = 1, SO_REUSEADDR = 2, O_NONBLOCK = 0x800, EAGAIN = 11,
          EINTR = 4, MSG_NOSIGNAL = 0x4000, SO_NOSIGPIPE = nil, bsd_sockaddr = false }
  elseif os_name == "OSX" then
    K = { SOL_SOCKET = 0xffff, SO_REUSEADDR = 4, O_NONBLOCK = 0x4, EAGAIN = 35,
          EINTR = 4, MSG_NOSIGNAL = 0, SO_NOSIGPIPE = 0x1022, bsd_sockaddr = true }
  else
    return nil, "FFI-Socket für " .. os_name .. " nicht umgesetzt"
  end
  K.AF_INET, K.SOCK_STREAM, K.IPPROTO_TCP, K.TCP_NODELAY = 2, 1, 6, 1
  K.F_GETFL, K.F_SETFL, K.F_SETFD, K.FD_CLOEXEC = 3, 4, 2, 1
  K.POLLIN, K.POLLOUT, K.POLLERR, K.POLLHUP = 1, 4, 8, 16

  cdef_once("ljdap_pollfd_t", [[
    typedef struct { int fd; short events; short revents; } ljdap_pollfd_t;
    int ljdap_socket(int, int, int) __asm__("socket");
    int ljdap_setsockopt(int, int, int, const void *, uint32_t) __asm__("setsockopt");
    int ljdap_bind(int, const void *, uint32_t) __asm__("bind");
    int ljdap_listen(int, int) __asm__("listen");
    int ljdap_accept(int, void *, void *) __asm__("accept");
    intptr_t ljdap_recv(int, void *, size_t, int) __asm__("recv");
    intptr_t ljdap_send(int, const void *, size_t, int) __asm__("send");
    int ljdap_close(int) __asm__("close");
    int ljdap_fcntl(int, int, ...) __asm__("fcntl");
    int ljdap_poll(ljdap_pollfd_t *, unsigned long, int) __asm__("poll");
    int ljdap_inet_pton(int, const char *, void *) __asm__("inet_pton");
    char *ljdap_strerror(int) __asm__("strerror");
  ]])
  if K.bsd_sockaddr then
    cdef_once("ljdap_sockaddr_bsd_t", [[typedef struct { uint8_t len; uint8_t family;
      uint8_t port[2]; uint32_t addr; uint8_t zero[8]; } ljdap_sockaddr_bsd_t;]])
  else
    cdef_once("ljdap_sockaddr_t", [[typedef struct { uint16_t family;
      uint8_t port[2]; uint32_t addr; uint8_t zero[8]; } ljdap_sockaddr_t;]])
  end

  local C = ffi.C
  local sockaddr_t = ffi.typeof(K.bsd_sockaddr and "ljdap_sockaddr_bsd_t" or "ljdap_sockaddr_t")
  local pollfd_t = ffi.typeof("ljdap_pollfd_t[1]")
  local int1 = ffi.typeof("int[1]")
  local cint = ffi.typeof("int")

  local B = { name = "posix" }

  local function errmsg(what)
    local e = ffi.errno()
    return what .. ": " .. ffi.string(C.ljdap_strerror(e)) .. " (errno " .. e .. ")", e
  end

  local function set_flags(fd)
    local fl = C.ljdap_fcntl(fd, K.F_GETFL, cint(0))
    if fl < 0 or C.ljdap_fcntl(fd, K.F_SETFL, cint(bit.bor(fl, K.O_NONBLOCK))) < 0 then
      return nil, errmsg("fcntl O_NONBLOCK")
    end
    -- Kindprozesse des Programms sollen den Socket nicht erben
    C.ljdap_fcntl(fd, K.F_SETFD, cint(K.FD_CLOEXEC))
    return true
  end

  local function setopt(fd, level, name, value)
    local v = int1(value)
    return C.ljdap_setsockopt(fd, level, name, v, 4) == 0
  end

  function B.listen(host, port)
    local addr = sockaddr_t()
    if K.bsd_sockaddr then addr.len = ffi.sizeof(sockaddr_t) end
    addr.family = K.AF_INET
    addr.port[0] = bit.rshift(port, 8)
    addr.port[1] = bit.band(port, 0xff)
    local a = ffi.new("uint32_t[1]")
    if C.ljdap_inet_pton(K.AF_INET, host, a) ~= 1 then
      return nil, "ungültige IPv4-Adresse: " .. tostring(host)
    end
    addr.addr = a[0]
    local fd = C.ljdap_socket(K.AF_INET, K.SOCK_STREAM, 0)
    if fd < 0 then return nil, errmsg("socket") end
    setopt(fd, K.SOL_SOCKET, K.SO_REUSEADDR, 1)
    if C.ljdap_bind(fd, addr, ffi.sizeof(sockaddr_t)) ~= 0 then
      local err = errmsg("bind " .. host .. ":" .. port)
      C.ljdap_close(fd)
      return nil, err
    end
    if C.ljdap_listen(fd, 4) ~= 0 then
      local err = errmsg("listen")
      C.ljdap_close(fd)
      return nil, err
    end
    local ok, err = set_flags(fd)
    if not ok then C.ljdap_close(fd); return nil, err end
    return fd
  end

  function B.accept(fd)
    local c = C.ljdap_accept(fd, nil, nil)
    if c < 0 then
      local e = ffi.errno()
      if e == K.EAGAIN or e == K.EINTR then return nil end
      return nil, errmsg("accept")
    end
    local ok, err = set_flags(c)
    if not ok then C.ljdap_close(c); return nil, err end
    setopt(c, K.IPPROTO_TCP, K.TCP_NODELAY, 1)
    if K.SO_NOSIGPIPE then setopt(c, K.SOL_SOCKET, K.SO_NOSIGPIPE, 1) end
    return c
  end

  local rbuf = ffi.new("uint8_t[?]", CHUNK)

  function B.recv(fd)
    local n = C.ljdap_recv(fd, rbuf, CHUNK, 0)
    if n > 0 then return ffi.string(rbuf, n) end
    if n == 0 then return nil, "closed" end
    local e = ffi.errno()
    if e == K.EAGAIN or e == K.EINTR then return "" end
    return nil, errmsg("recv")
  end

  -- Liefert Anzahl gesendeter Bytes, 0 bei EAGAIN, oder nil, err
  function B.send_some(fd, data, offset)
    local p = ffi.cast("const uint8_t *", data) + offset
    local n = C.ljdap_send(fd, p, #data - offset, K.MSG_NOSIGNAL)
    if n >= 0 then return tonumber(n) end
    local e = ffi.errno()
    if e == K.EAGAIN or e == K.EINTR then return 0 end
    return nil, errmsg("send")
  end

  local pfd = pollfd_t()
  -- what: "r" oder "w"; liefert true (bereit/Fehler/geschlossen) oder false
  function B.wait(fd, what, ms)
    pfd[0].fd = fd
    pfd[0].events = what == "w" and K.POLLOUT or K.POLLIN
    pfd[0].revents = 0
    local r = C.ljdap_poll(pfd, 1, ms)
    return r > 0
  end

  function B.close(fd) C.ljdap_close(fd) end

  return B
end

local function build_windows()
  cdef_once("ljdap_fdset_t", [[
    typedef uintptr_t ljdap_socket_t;
    typedef struct { uint16_t family; uint8_t port[2]; uint32_t addr; uint8_t zero[8]; } ljdap_wsockaddr_t;
    typedef struct { uint32_t count; ljdap_socket_t fds[64]; } ljdap_fdset_t;
    typedef struct { int32_t sec; int32_t usec; } ljdap_timeval_t;
    int ljdap_WSAStartup(uint16_t, void *) __asm__("WSAStartup");
    int ljdap_WSAGetLastError(void) __asm__("WSAGetLastError");
    ljdap_socket_t ljdap_wsocket(int, int, int) __asm__("socket");
    int ljdap_wsetsockopt(ljdap_socket_t, int, int, const void *, int) __asm__("setsockopt");
    int ljdap_wbind(ljdap_socket_t, const void *, int) __asm__("bind");
    int ljdap_wlisten(ljdap_socket_t, int) __asm__("listen");
    ljdap_socket_t ljdap_waccept(ljdap_socket_t, void *, void *) __asm__("accept");
    int ljdap_wrecv(ljdap_socket_t, void *, int, int) __asm__("recv");
    int ljdap_wsend(ljdap_socket_t, const void *, int, int) __asm__("send");
    int ljdap_closesocket(ljdap_socket_t) __asm__("closesocket");
    int ljdap_ioctlsocket(ljdap_socket_t, int32_t, uint32_t *) __asm__("ioctlsocket");
    int ljdap_select(int, ljdap_fdset_t *, ljdap_fdset_t *, ljdap_fdset_t *, const ljdap_timeval_t *) __asm__("select");
    uint32_t ljdap_inet_addr(const char *) __asm__("inet_addr");
    int ljdap_SetHandleInformation(uintptr_t, uint32_t, uint32_t) __asm__("SetHandleInformation");
  ]])
  local ok, W = pcall(ffi.load, "ws2_32")
  if not ok then return nil, "ws2_32 nicht ladbar: " .. tostring(W) end
  local K32 = ffi.C -- kernel32 ist im Prozess immer da

  local INVALID = ffi.cast("ljdap_socket_t", -1)
  local WSAEWOULDBLOCK, WSAEINTR = 10035, 10004
  local AF_INET, SOCK_STREAM, IPPROTO_TCP, TCP_NODELAY = 2, 1, 6, 1
  local SOL_SOCKET, SO_EXCLUSIVEADDRUSE = 0xffff, -5 -- ~SO_REUSEADDR
  local FIONBIO = -2147195266 -- 0x8004667E als int32

  local wsadata = ffi.new("uint8_t[1024]")
  local r = W.ljdap_WSAStartup(0x0202, wsadata)
  if r ~= 0 then return nil, "WSAStartup: " .. r end

  local B = { name = "windows" }
  local int1 = ffi.typeof("int[1]")

  local function errmsg(what)
    local e = W.ljdap_WSAGetLastError()
    return what .. ": WSA-Fehler " .. e, e
  end

  local function prepare(s)
    local one = ffi.new("uint32_t[1]", 1)
    if W.ljdap_ioctlsocket(s, FIONBIO, one) ~= 0 then return nil, errmsg("ioctlsocket FIONBIO") end
    -- nicht an Kindprozesse vererben (HANDLE_FLAG_INHERIT = 1)
    pcall(K32.ljdap_SetHandleInformation, ffi.cast("uintptr_t", s), 1, 0)
    return true
  end

  function B.listen(host, port)
    local addr = ffi.new("ljdap_wsockaddr_t")
    addr.family = AF_INET
    addr.port[0] = bit.rshift(port, 8)
    addr.port[1] = bit.band(port, 0xff)
    local a = W.ljdap_inet_addr(host)
    if a == 0xffffffff and host ~= "255.255.255.255" then
      return nil, "ungültige IPv4-Adresse: " .. tostring(host)
    end
    addr.addr = a
    local s = W.ljdap_wsocket(AF_INET, SOCK_STREAM, 0)
    if s == INVALID then return nil, errmsg("socket") end
    W.ljdap_wsetsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, int1(1), 4)
    if W.ljdap_wbind(s, addr, ffi.sizeof(addr)) ~= 0 then
      local err = errmsg("bind " .. host .. ":" .. port)
      W.ljdap_closesocket(s)
      return nil, err
    end
    if W.ljdap_wlisten(s, 4) ~= 0 then
      local err = errmsg("listen")
      W.ljdap_closesocket(s)
      return nil, err
    end
    local ok, err = prepare(s)
    if not ok then W.ljdap_closesocket(s); return nil, err end
    return s
  end

  function B.accept(s)
    local c = W.ljdap_waccept(s, nil, nil)
    if c == INVALID then
      local e = W.ljdap_WSAGetLastError()
      if e == WSAEWOULDBLOCK or e == WSAEINTR then return nil end
      return nil, "accept: WSA-Fehler " .. e
    end
    local ok, err = prepare(c)
    if not ok then W.ljdap_closesocket(c); return nil, err end
    W.ljdap_wsetsockopt(c, IPPROTO_TCP, TCP_NODELAY, int1(1), 4)
    return c
  end

  local rbuf = ffi.new("uint8_t[?]", CHUNK)

  function B.recv(s)
    local n = W.ljdap_wrecv(s, rbuf, CHUNK, 0)
    if n > 0 then return ffi.string(rbuf, n) end
    if n == 0 then return nil, "closed" end
    local e = W.ljdap_WSAGetLastError()
    if e == WSAEWOULDBLOCK or e == WSAEINTR then return "" end
    return nil, "recv: WSA-Fehler " .. e
  end

  function B.send_some(s, data, offset)
    local p = ffi.cast("const uint8_t *", data) + offset
    local n = W.ljdap_wsend(s, p, #data - offset, 0)
    if n >= 0 then return n end
    local e = W.ljdap_WSAGetLastError()
    if e == WSAEWOULDBLOCK or e == WSAEINTR then return 0 end
    return nil, "send: WSA-Fehler " .. e
  end

  local set = ffi.new("ljdap_fdset_t")
  local tv = ffi.new("ljdap_timeval_t")
  function B.wait(s, what, ms)
    set.count = 1
    set.fds[0] = s
    local ptv = nil
    if ms >= 0 then
      tv.sec = math.floor(ms / 1000)
      tv.usec = (ms % 1000) * 1000
      ptv = tv
    end
    local r
    if what == "w" then r = W.ljdap_select(0, nil, set, nil, ptv)
    else r = W.ljdap_select(0, set, nil, nil, ptv) end
    return r > 0
  end

  function B.close(s) W.ljdap_closesocket(s) end

  return B
end

local function build_luasocket()
  local ok, socket = pcall(require, "socket")
  if not ok then return nil, "weder FFI noch LuaSocket verfügbar" end
  local B = { name = "luasocket" }

  function B.listen(host, port)
    local s, err = socket.tcp()
    if not s then return nil, err end
    s:setoption("reuseaddr", true)
    local r
    r, err = s:bind(host, port)
    if not r then s:close(); return nil, "bind " .. host .. ":" .. port .. ": " .. tostring(err) end
    r, err = s:listen(4)
    if not r then s:close(); return nil, "listen: " .. tostring(err) end
    s:settimeout(0)
    return s
  end

  function B.accept(s)
    local c, err = s:accept()
    if not c then
      if err == "timeout" then return nil end
      return nil, "accept: " .. tostring(err)
    end
    c:settimeout(0)
    c:setoption("tcp-nodelay", true)
    return c
  end

  function B.recv(c)
    local data, err, partial = c:receive(CHUNK)
    if data then return data end
    if partial and partial ~= "" then return partial end
    if err == "timeout" then return "" end
    if err == "closed" then return nil, "closed" end
    return nil, "recv: " .. tostring(err)
  end

  function B.send_some(c, data, offset)
    local last, err, partial = c:send(data, offset + 1)
    if last then return last - offset end
    if err == "timeout" then return (partial or offset) - offset end
    return nil, "send: " .. tostring(err)
  end

  function B.wait(c, what, ms)
    local t = ms >= 0 and ms / 1000 or nil
    local r, w
    if what == "w" then r, w = socket.select(nil, { c }, t) ; return #w > 0 end
    r = socket.select({ c }, nil, t)
    return #r > 0
  end

  function B.close(c) c:close() end

  return B
end

local backends = {}

--- Liefert das Backend name ("auto", "posix", "windows", "luasocket").
function M.backend(name)
  name = name or "auto"
  if name == "auto" then
    if ffi then
      name = ffi.os == "Windows" and "windows" or "posix"
      local b = M.backend(name)
      if b then return b end
    end
    return M.backend("luasocket")
  end
  if backends[name] then return backends[name] end
  local b, err
  if name == "posix" then
    if not ffi then return nil, "kein FFI" end
    b, err = build_posix()
  elseif name == "windows" then
    if not ffi then return nil, "kein FFI" end
    b, err = build_windows()
  elseif name == "luasocket" then
    b, err = build_luasocket()
  else
    return nil, "unbekanntes Backend: " .. tostring(name)
  end
  if b then backends[name] = b end
  return b, err
end

------------------------------------------------------------------------
-- Server und Verbindung
------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

function Conn:receive()
  if self.closed then return nil, "closed" end
  local data, err = self.b.recv(self.h)
  if not data then self:close() end
  return data, err
end

function Conn:send(data)
  if self.closed then return nil, "closed" end
  local off, len = 0, #data
  local waited = 0
  while off < len do
    local n, err = self.b.send_some(self.h, data, off)
    if not n then self:close(); return nil, err end
    if n == 0 then
      if waited >= SEND_TIMEOUT_MS then
        self:close()
        return nil, "send: Zeitüberschreitung"
      end
      self.b.wait(self.h, "w", 100)
      waited = waited + 100
    else
      off = off + n
      waited = 0
    end
  end
  return true
end

function Conn:wait(ms)
  if self.closed then return true end
  return self.b.wait(self.h, "r", ms or -1)
end

function Conn:close()
  if not self.closed then
    self.closed = true
    self.b.close(self.h)
  end
end

local Server = {}
Server.__index = Server

function Server:accept()
  if self.closed then return nil, "closed" end
  local h, err = self.b.accept(self.h)
  if not h then return nil, err end
  return setmetatable({ b = self.b, h = h, closed = false }, Conn)
end

--- Wartet bis zu ms Millisekunden auf eine Verbindung (ms < 0: ewig).
function Server:wait(ms)
  if self.closed then return false end
  return self.b.wait(self.h, "r", ms or -1)
end

function Server:close()
  if not self.closed then
    self.closed = true
    self.b.close(self.h)
  end
end

--- Öffnet einen TCP-Server. opt.backend wählt das Backend.
function M.listen(host, port, opt)
  host = host or "127.0.0.1"
  -- nur IPv4 in Punktschreibweise: einheitlich über alle Backends, kein DNS
  local a, b, c, d = tostring(host):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a or tonumber(a) > 255 or tonumber(b) > 255 or tonumber(c) > 255 or tonumber(d) > 255 then
    return nil, "ungültige IPv4-Adresse: " .. tostring(host)
  end
  if type(port) ~= "number" or port < 0 or port > 65535 or port ~= math.floor(port) then
    return nil, "ungültiger Port: " .. tostring(port)
  end
  local b, err = M.backend(opt and opt.backend)
  if not b then return nil, err end
  local h
  h, err = b.listen(host, port)
  if not h then return nil, err end
  return setmetatable({ b = b, h = h, closed = false, backend = b.name,
                        host = host, port = port }, Server)
end

------------------------------------------------------------------------
-- stdio
------------------------------------------------------------------------

-- Nur blockierend: receive() wartet auf Daten. Für Programme, die stdin und
-- stdout nicht selbst nutzen; Pause im laufenden Programm ist damit nicht
-- möglich (kein nicht blockierendes Lesen ohne FFI).
local Stdio = {}
Stdio.__index = Stdio

function Stdio:send(data)
  if self.closed then return nil, "closed" end
  local ok, err = self.out:write(data)
  if not ok then return nil, err end
  self.out:flush()
  return true
end

function Stdio:wait() return true end
function Stdio:close() self.closed = true end

-- Rahmenleser für stdio: Kopf zeilenweise, Body gezielt mit read(n); so
-- blockiert read nie über das Nachrichtenende hinaus. Ersetzt receive().
function Stdio:read_message()
  local len
  while true do
    local line = self.inp:read("*l")
    if not line then self.closed = true; return nil, "closed" end
    line = line:gsub("\r$", "")
    if line == "" then
      if len then break end
    else
      local v = line:match("^[Cc]ontent%-[Ll]ength%s*:%s*(%d+)")
      if v then len = tonumber(v) end
    end
  end
  local body = self.inp:read(len)
  if not body or #body < len then self.closed = true; return nil, "closed" end
  return body
end

--- Verbindung über Standardein-/-ausgabe (oder übergebene Dateien).
-- Windows: stdin/stdout im Textmodus verwandeln "\n" in "\r\n" (und
-- umgekehrt) und zerstören damit den Rahmen; daher Binärmodus.
local function windows_binary_stdio()
  if not (ffi and ffi.os == "Windows") then return end
  pcall(function()
    cdef_once("ljdap_setmode_marker_t", [[
      typedef int ljdap_setmode_marker_t;
      int ljdap_setmode(int, int) __asm__("_setmode");
    ]])
    local O_BINARY = 0x8000
    ffi.C.ljdap_setmode(0, O_BINARY)
    ffi.C.ljdap_setmode(1, O_BINARY)
  end)
end

function M.stdio(inp, out)
  if not inp and not out then windows_binary_stdio() end
  local o = out or io.stdout
  if o.setvbuf then o:setvbuf("full") end
  return setmetatable({ inp = inp or io.stdin, out = o, closed = false, stdio = true }, Stdio)
end

return M
end

package.preload["ljdap.protocol"] = function(...)
-- ljdap.protocol – DAP-Nachrichten über eine Transportverbindung.
--
-- Kanal = Verbindung + Rahmenleser + Sequenzzähler. Kennt keine Semantik
-- einzelner Requests (die liegt in ljdap.session).
--
-- Fehlerkonvention: wert | nil, fehlertext; nie error().
--
--   ch = protocol.channel(con, log)    log(richtung, text) optional
--   msg, err = ch:read(ms)    ms = 0: nur Vorhandenes, ms < 0: blockierend
--                             nil ohne err: nichts da; err "closed": getrennt
--   ch:respond(req, body)              Erfolg
--   ch:fail(req, text)                 Fehlerantwort
--   ch:event(name, body)
--   ch:close()

local pcall = pcall -- Original; ljdap.errors ersetzt das globale pcall

local json = require("ljdap.json")
local transport = require("ljdap.transport")

local M = {}

local Channel = {}
Channel.__index = Channel

function M.channel(con, log)
  return setmetatable({ con = con, framer = transport.framer(), seq = 0,
                        log = log, closed = false }, Channel)
end

local function decode(self, body)
  if self.log then self.log("<-", body) end
  local msg, err = json.decode(body)
  if not msg then return nil, "ungültiges JSON: " .. err end
  if type(msg) ~= "table" or type(msg.type) ~= "string" then
    return nil, "keine DAP-Nachricht"
  end
  return msg
end

--- Liest die nächste Nachricht. Kaputte Nachrichten werden übersprungen und
-- als zweiter Wert "bad" mit Text gemeldet: nil, nil, text.
function Channel:read(ms)
  if self.closed then return nil, "closed" end
  local con = self.con
  if con.read_message then -- stdio: nur blockierend
    local body, err = con:read_message()
    if not body then self.closed = true; return nil, err end
    local msg, derr = decode(self, body)
    if not msg then return nil, nil, derr end
    return msg
  end
  local waited = false
  while true do
    local body, ferr = self.framer:next()
    if body then
      local msg, derr = decode(self, body)
      if not msg then return nil, nil, derr end
      return msg
    end
    if ferr then return nil, nil, ferr end
    local data, err = con:receive()
    if not data then
      self.closed = true
      return nil, err or "closed"
    end
    if data == "" then
      if ms == 0 or (waited and ms > 0) then return nil end
      con:wait(ms)
      waited = true
    else
      self.framer:feed(data)
    end
  end
end

function Channel:send(msg)
  if self.closed then return nil, "closed" end
  self.seq = self.seq + 1
  msg.seq = self.seq
  local ok, body = pcall(json.encode, msg)
  if not ok then
    -- Programmierfehler im Agenten: als Fehlerantwort/Ausgabe melden statt abbrechen
    body = json.encode({ seq = msg.seq, type = "event", event = "output",
      body = { category = "console", output = "ljdap: interner Fehler beim Kodieren: " .. tostring(body) .. "\n" } })
  end
  if self.log then self.log("->", body) end
  local sent, err = self.con:send(transport.frame(body))
  if not sent then self.closed = true; return nil, err end
  return true
end

function Channel:respond(req, body)
  return self:send({ type = "response", request_seq = req.seq, success = true,
                     command = req.command, body = body })
end

function Channel:fail(req, text)
  return self:send({ type = "response", request_seq = req.seq, success = false,
                     command = req.command, message = text,
                     body = { error = { id = 1, format = text, showUser = true } } })
end

function Channel:event(name, body)
  return self:send({ type = "event", event = name, body = body })
end

function Channel:close()
  if not self.closed then
    self.closed = true
    self.con:close()
  end
end

return M
end

package.preload["ljdap.paths"] = function(...)
-- ljdap.paths – Pfade zwischen Lua-Quellnamen und Client-Pfaden.
--
-- debug.getinfo().source ist "@pfad" (relativ zum Arbeitsverzeichnis beim
-- Laden), "=name" oder der Quelltext selbst (loadstring). ljdap merkt sich
-- das Arbeitsverzeichnis beim Start; Programme, die später chdir() machen
-- und danach relative Pfade laden, werden falsch aufgelöst (Grenze, README).
--
-- Schlüssel (key) = normalisierter absoluter Pfad zum Vergleichen:
--   "/" als Trenner, "." und ".." aufgelöst, unter Windows klein geschrieben.
-- Anzeige (display) = absoluter Pfad in der Schreibweise des Systems.
--
-- pathMappings (attach-Argument), Liste von { localRoot, remoteRoot }:
--   localRoot  = Pfad auf der Client-Seite (Editor)
--   remoteRoot = Pfad im untersuchten Programm
--
-- Fehlerkonvention: reine Funktionen, keine Fehler; unbekannte Quellen → nil.

local pcall = pcall -- Original; ljdap.errors ersetzt das globale pcall

local M = {}

local has_ffi, ffi = pcall(require, "ffi")
if not has_ffi then ffi = nil end

local windows
if ffi then windows = ffi.os == "Windows"
else windows = package.config:sub(1, 1) == "\\" end
M.windows = windows

------------------------------------------------------------------------
-- Arbeitsverzeichnis
------------------------------------------------------------------------

local function getcwd_ffi()
  if windows then
    pcall(ffi.cdef, [[
      uint32_t ljdap_GetCurrentDirectoryW(uint32_t, uint16_t *) __asm__("GetCurrentDirectoryW");
      int ljdap_WideCharToMultiByte(uint32_t, uint32_t, const uint16_t *, int, char *, int,
                                    const char *, int *) __asm__("WideCharToMultiByte");
    ]])
    local n = ffi.C.ljdap_GetCurrentDirectoryW(0, nil)
    if n == 0 then return nil end
    local w = ffi.new("uint16_t[?]", n)
    n = ffi.C.ljdap_GetCurrentDirectoryW(n, w)
    local CP_UTF8 = 65001
    local len = ffi.C.ljdap_WideCharToMultiByte(CP_UTF8, 0, w, n, nil, 0, nil, nil)
    local buf = ffi.new("char[?]", len)
    ffi.C.ljdap_WideCharToMultiByte(CP_UTF8, 0, w, n, buf, len, nil, nil)
    return ffi.string(buf, len)
  else
    pcall(ffi.cdef, [[char *ljdap_getcwd(char *, size_t) __asm__("getcwd");]])
    local buf = ffi.new("char[4096]")
    if ffi.C.ljdap_getcwd(buf, 4096) == nil then return nil end
    return ffi.string(buf)
  end
end

--- Aktuelles Arbeitsverzeichnis (UTF-8) oder nil.
function M.getcwd()
  if ffi then
    local ok, d = pcall(getcwd_ffi)
    if ok and d and d ~= "" then return d end
  end
  -- Nicht $PWD: das bleibt veraltet, wenn ein Elternprozess das Verzeichnis
  -- wechselt, ohne PWD anzupassen (Python-subprocess, Editoren, Dienste).
  -- Ohne FFI daher einmal beim Start die Shell fragen.
  local d
  local p = io.popen(windows and "cd" or "pwd")
  if p then
    d = p:read("*l")
    p:close()
    if d and d ~= "" then return d end
  end
  return nil
end

------------------------------------------------------------------------
-- Normalisierung
------------------------------------------------------------------------

local function is_abs(p)
  return p:sub(1, 1) == "/" or p:match("^%a:[/\\]") ~= nil or p:sub(1, 2) == "\\\\"
end
M.is_abs = is_abs

-- Löst "." und ".." auf; erhält Laufwerk bzw. führenden Schrägstrich.
local function clean(p)
  p = p:gsub("\\", "/")
  local prefix = ""
  local drive = p:match("^(%a:)/")
  if drive then
    prefix = drive:upper() .. "/"
    p = p:sub(4)
  elseif p:sub(1, 2) == "//" then
    prefix = "//"
    p = p:sub(3)
  elseif p:sub(1, 1) == "/" then
    prefix = "/"
    p = p:sub(2)
  end
  local parts = {}
  for part in p:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        parts[#parts] = nil
      elseif prefix == "" then
        parts[#parts + 1] = ".."
      end
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return prefix .. table.concat(parts, "/")
end
M.clean = clean

--- Absoluter, bereinigter Pfad mit "/" (relativ zu base).
function M.absolute(p, base)
  if not is_abs(p) and base then p = base .. "/" .. p end
  return clean(p)
end

--- Vergleichsschlüssel eines absoluten Pfads.
function M.key(p)
  p = clean(p)
  if windows then p = p:lower() end
  return p
end

--- Pfad in Systemschreibweise (Windows: Backslash).
function M.display(p)
  if windows then return (p:gsub("/", "\\")) end
  return p
end

------------------------------------------------------------------------
-- Zuordnung Quelle <-> Client
------------------------------------------------------------------------

local Mapper = {}
Mapper.__index = Mapper

--- cwd: Arbeitsverzeichnis beim Start; mappings: pathMappings (optional).
function M.mapper(cwd, mappings)
  local maps = {}
  for _, m in ipairs(mappings or {}) do
    if type(m) == "table" and type(m.localRoot) == "string" and type(m.remoteRoot) == "string" then
      -- Schreibweise des Clients aus localRoot ableiten (nicht aus dem
      -- System des Programms): Windows-Editor ↔ Linux-Programm und umgekehrt
      local win = m.localRoot:find("\\", 1, true) ~= nil or m.localRoot:match("^%a:") ~= nil
      maps[#maps + 1] = { loc = M.key(m.localRoot), loc_raw = clean(m.localRoot),
                          rem = M.key(m.remoteRoot), rem_raw = clean(m.remoteRoot),
                          win = win }
    end
  end
  return setmetatable({ cwd = cwd and clean(cwd) or nil, maps = maps, cache = {} }, Mapper)
end

local function replace_prefix(key, raw, from_key, to_raw)
  if key == from_key then return to_raw end
  local n = #from_key
  if key:sub(1, n) == from_key and key:sub(n + 1, n + 1) == "/" then
    return to_raw .. raw:sub(n + 1)
  end
  return nil
end

--- Lua-Quelle ("@pfad") -> { key = Schlüssel, path = Anzeigepfad für den
-- Client } oder nil für Quellen ohne Datei.
function Mapper:from_source(source)
  local hit = self.cache[source]
  if hit ~= nil then return hit or nil end
  local r = false
  if type(source) == "string" and source:sub(1, 1) == "@" then
    local abs = M.absolute(source:sub(2), self.cwd)
    local key = M.key(abs)
    local client = M.display(abs)
    for _, m in ipairs(self.maps) do
      local mapped = replace_prefix(key, abs, m.rem, m.loc_raw)
      if mapped then
        client = m.win and (mapped:gsub("/", "\\")) or mapped
        break
      end
    end
    r = { key = key, path = client, abs = abs }
  end
  self.cache[source] = r
  return r or nil
end

--- Client-Pfad -> Schlüssel im Programm (und lokaler absoluter Pfad).
function Mapper:from_client(path)
  local abs = M.absolute(path, self.cwd)
  local key = M.key(abs)
  for _, m in ipairs(self.maps) do
    local mapped = replace_prefix(key, abs, m.loc, m.rem_raw)
    if mapped then
      return M.key(mapped), mapped
    end
  end
  return key, abs
end

return M
end

package.preload["ljdap.lines"] = function(...)
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
end

package.preload["ljdap.breakpoints"] = function(...)
-- ljdap.breakpoints – Haltepunkte je Datei, Prüfung und Verschiebung.
--
-- setBreakpoints ersetzt alle Haltepunkte einer Quelle. Gültige Zeilen
-- kommen aus ljdap.lines (Datei übersetzen, nicht ausführen): Haltepunkte
-- auf Kommentar-/Leerzeilen werden auf die nächste Codezeile geschoben und
-- sofort als verified gemeldet. Ist die Datei nicht lesbar, bleibt der
-- Haltepunkt an der gewünschten Zeile aktiv, aber unverified.
--
-- Laufzeitprüfung im Hook: zuerst store.lines[line] (billig, ohne
-- getinfo), nur bei Treffer die Quelle vergleichen.
--
-- Stand M2: Bedingungen, Trefferzähler und Logpoints werden gespeichert,
-- aber erst ab M3 ausgewertet.
--
-- Fehlerkonvention: keine Fehler; Probleme stehen in message der Antwort.

local lines = require("ljdap.lines")

local M = {}

local MAX_SHIFT = 30

local Store = {}
Store.__index = Store

function M.new()
  return setmetatable({
    by_key = {},   -- key -> { [line] = bp }
    lines = {},    -- line -> Anzahl Haltepunkte über alle Dateien
    next_id = 1,
    count = 0,
  }, Store)
end

local function recount(self)
  local lc, n = {}, 0
  for _, per in pairs(self.by_key) do
    for line in pairs(per) do
      lc[line] = (lc[line] or 0) + 1
      n = n + 1
    end
  end
  self.lines = lc
  self.count = n
end

--- Setzt die Haltepunkte einer Datei.
-- key, abs: aus mapper:from_client; list: DAP SourceBreakpoint[];
-- client_path: Pfad wie vom Client gesendet (für die Antwort).
-- Liefert DAP-Breakpoint[] in derselben Reihenfolge.
function Store:set(key, abs, list)
  local valid, err = lines.of_file(abs)
  local per = {}
  local result = {}
  for i, req in ipairs(list) do
    local want = tonumber(req.line) or 0
    local line, verified, message = want, false, nil
    if valid then
      local adj = lines.adjust(valid, want, MAX_SHIFT)
      if adj then
        line, verified = adj, true
      else
        message = "keine Codezeile ab Zeile " .. want
      end
    else
      message = "Datei im Programm nicht lesbar (" .. tostring(err) .. "); Haltepunkt bleibt aktiv"
    end
    local bp
    if verified or not valid then
      bp = per[line]
      if not bp then
        bp = { id = self.next_id, line = line, key = key,
               condition = req.condition, hitCondition = req.hitCondition,
               logMessage = req.logMessage, hits = 0 }
        self.next_id = self.next_id + 1
        per[line] = bp
      end
      result[i] = { id = bp.id, verified = verified, line = line, message = message }
    else
      result[i] = { id = self.next_id, verified = false, line = want, message = message }
      self.next_id = self.next_id + 1
    end
  end
  if next(per) then self.by_key[key] = per else self.by_key[key] = nil end
  recount(self)
  return result
end

--- Alle Haltepunkte entfernen (z. B. neuer Client).
function Store:clear()
  self.by_key = {}
  recount(self)
end

--- Haltepunkt für Quelle/Zeile oder nil. src = mapper:from_source(...)
function Store:lookup(src, line)
  if not src then return nil end
  local per = self.by_key[src.key]
  return per and per[line] or nil
end

return M
end

package.preload["ljdap.vars"] = function(...)
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
end

package.preload["ljdap.hooks"] = function(...)
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
end

package.preload["ljdap.eval"] = function(...)
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
end

package.preload["ljdap.threads"] = function(...)
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
end

package.preload["ljdap.errors"] = function(...)
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
end

package.preload["ljdap.session"] = function(...)
-- ljdap.session – Zustand des Agenten und Behandlung der DAP-Requests.
--
-- Stand M3: Verbindung, Anhängen, Haltepunkte mit Bedingung/Trefferzähler/
-- Logpoint, Stepping (in/over/out) auch über Coroutine-Grenzen, Pause,
-- Stack/Scopes/Variablen aller Coroutinen, evaluate/setVariable, Halt bei
-- Fehlern (uncaught/raised) mit exceptionInfo.
--
-- Zustände:
--   idle       nicht gestartet
--   listening  Server offen, kein Client
--   connected  Client verbunden, Konfiguration läuft
--   running    configurationDone erhalten
-- Zusätzlich S.stop ~= nil während eines Halts.
--
-- Abfrage des Sockets im laufenden Programm: Count-Hook (alle opt.poll
-- Anweisungen) auf der Haupt-Coroutine und ljdap.poll() für Hauptschleifen.
-- Unter LuaJIT feuern Hooks nicht in kompiliertem Code: bei verbundenem
-- Client ist der JIT aus; ohne Client ljdap.poll() oder opt.jit = "off".
--
-- Stack-Ebenen: Ein Halt merkt sich eine Markierungsfunktion (den Hook bzw.
-- ljdap.breakhere). Der Rahmen des Programms direkt über der Markierung ist
-- Frame 0; die Ebene wird bei jeder Abfrage neu gesucht, nicht hart codiert.
--
-- Fehlerkonvention: öffentliche Funktionen liefern true | nil, err; Fehler
-- in Handlern werden als Fehlerantwort gemeldet, nie an das Programm
-- weitergereicht.

local pcall = pcall -- Original; ljdap.errors ersetzt das globale pcall

local json = require("ljdap.json")
local transport = require("ljdap.transport")
local protocol = require("ljdap.protocol")
local paths = require("ljdap.paths")
local breakpoints = require("ljdap.breakpoints")
local vars = require("ljdap.vars")
local hooks = require("ljdap.hooks")
local eval = require("ljdap.eval")
local threads = require("ljdap.threads")
local errors = require("ljdap.errors")
local VERSION = require("ljdap.version")

local getinfo, getlocal, setlocal = debug.getinfo, debug.getlocal, debug.setlocal
local getupvalue = debug.getupvalue

local M = {}

local DEFAULTS = {
  host = "127.0.0.1",
  port = 4711,
  wait = false,      -- blockiert start() bis configurationDone
  backend = "auto",  -- auto | posix | windows | luasocket | stdio
  poll = 10000,      -- Count-Hook-Intervall (Anweisungen), 0 = aus
  jit = "on",        -- "off": jit.off() beim Start
  log = nil,         -- Dateipfad für Protokollmitschnitt
}

local MAX_FRAMES = 1000

-- Quellen des Agenten selbst: beim Steppen überspringen.
--   Module (src/ljdap/*.lua): alles unter dem Verzeichnis ljdap/. Unter
--     Windows erzeugt require gemischte Trenner ("src/ljdap\\session.lua",
--     aber "src/ljdap/init.lua"), daher mit vereinheitlichten Trennern.
--   Ein-Datei-Version (ljdap.lua): genau diese Datei – nicht ihr
--     Verzeichnis, dort liegen oft die Skripte des Benutzers.
local SELF = getinfo(1, "S").source:gsub("\\", "/")
local AGENT_PREFIX, AGENT_EXACT
if SELF:match("/ljdap/[^/]+%.lua$") or SELF:match("^@ljdap/[^/]+%.lua$") then
  AGENT_PREFIX = SELF:match("^(@.*/)")
else
  AGENT_EXACT = SELF
end
local agent_cache = {}
local function is_agent(source)
  local r = agent_cache[source]
  if r == nil then
    local s = source:gsub("\\", "/")
    if AGENT_EXACT then r = s == AGENT_EXACT
    else r = s:sub(1, #AGENT_PREFIX) == AGENT_PREFIX end
    agent_cache[source] = r
  end
  return r
end

local S = {
  state = "idle",
  opt = nil,
  server = nil,
  ch = nil,
  busy = false,       -- Wiedereintrittssperre (Hooks, poll)
  client = nil,       -- Argumente von initialize
  configured = false, -- einmal configurationDone erhalten (gibt wait frei)
  logfile = nil,
  cwd = nil,
  mapper = nil,
  bps = breakpoints.new(),
  step = nil,         -- { mode = "in"|"over"|"out"|"pause", depth, thread, reason }
  stop = nil,         -- { marker, skip, reason, depth, refs, thread, tid, frames, exc }
  exc = { uncaught = false, raised = false }, -- Ausnahme-Filter des Clients
  resume = false,
  lines1 = true,      -- Client zählt Zeilen ab 1
  cols1 = true,
}
M.S = S -- für Tests

------------------------------------------------------------------------
-- Hilfen
------------------------------------------------------------------------

local function warn(text)
  io.stderr:write("ljdap: ", text, "\n")
  io.stderr:flush()
end

local function log(dir, text)
  local f = S.logfile
  if f then
    f:write(os.date("%H:%M:%S "), dir, " ", text, "\n")
    f:flush()
  end
end

local function output(text, category)
  if S.ch then S.ch:event("output", { category = category or "console", output = text }) end
end

local function line_out(l) return S.lines1 and l or l - 1 end
local function line_in(l) return S.lines1 and l or l + 1 end

local function update_hooks()
  local line = S.ch ~= nil and (S.bps.count > 0 or S.step ~= nil)
  hooks.filter(S.bps.lines, S.step ~= nil)
  hooks.set(line, S.opt and S.opt.poll or 0)
end

-- pcall/xpcall-Hüllen nur, solange sie gebraucht werden: Filter „raised“,
-- unter Lua 5.1 auch „uncaught“ (Schutztiefe für die traceback-Erkennung).
local function update_exc()
  local exc = S.exc
  local need = S.ch ~= nil and (exc.raised or (not errors.is_luajit and exc.uncaught))
  errors.wrap_protected(need and true or false)
end

-- Ebene von Frame k über der Markierungsfunktion, relativ zum Aufrufer.
-- (Ebene 1 = diese Funktion, 2 = Aufrufer; Markierung bei l -> Frame 0
-- liegt für den Aufrufer bei Ebene l, zuzüglich skip übersprungener Rahmen.)
-- Nicht in eine Hilfsfunktion verpacken: die Ebene gilt für den Aufrufer.
local function user_level(k, marker, skip)
  if not marker then return nil end
  for l = 2, 10000 do
    local i = getinfo(l, "f")
    if not i then return nil end
    if i.func == marker then return l + (skip or 0) + (k or 0) end
  end
  return nil
end

-- Rahmen-Accessor für eval und Variablen. Kein Tail Call auf debug.*:
-- LuaJIT ersetzt dabei den Rahmen der Hülle, die Ebene stimmt dann nicht.
--   fr = { co = thread, lv = Ebene }            Rahmen einer anderen Coroutine
--   fr = { k = n, marker = f, skip = s }        Rahmen im laufenden Thread
local function accessor(fr)
  if fr.co then
    local co, lv = fr.co, fr.lv
    return {
      info = function(what) local r = getinfo(co, lv, what); return r end,
      getlocal = function(i) local n, v = getlocal(co, lv, i); return n, v end,
      setlocal = function(i, v) local n = setlocal(co, lv, i, v); return n end,
    }
  end
  local k, marker, skip = fr.k, fr.marker, fr.skip
  return {
    info = function(what)
      local l = user_level(k, marker, skip)
      if not l then return nil end
      local r = getinfo(l, what)
      return r
    end,
    getlocal = function(i)
      local l = user_level(k, marker, skip)
      if not l then return nil end
      local n, v = getlocal(l, i)
      return n, v
    end,
    setlocal = function(i, v)
      local l = user_level(k, marker, skip)
      if not l then return nil end
      local n = setlocal(l, i, v)
      return n
    end,
  }
end

------------------------------------------------------------------------
-- Halt
------------------------------------------------------------------------

local service -- vorwärts

-- Hält das Programm an. marker: Funktion direkt unter Frame 0 (zuzüglich
-- skip Rahmen); depth: Stacktiefe von Frame 0 (für Step over/out).
local function enter_stop(reason, marker, depth, extra, skip)
  S.busy = true
  S.step = nil
  local thread = coroutine.running()
  S.stop = { marker = marker, reason = reason, depth = depth, skip = skip or 0,
             refs = vars.refs(), thread = thread, tid = threads.id(thread), frames = {} }
  S.resume = false
  local body = { reason = reason, threadId = S.stop.tid, allThreadsStopped = true }
  if extra then
    for k, v in pairs(extra) do
      if k == "exc" then S.stop.exc = v else body[k] = v end
    end
  end
  S.ch:event("stopped", body)
  local ok, err = pcall(function()
    while S.ch and not S.resume do service(-1) end
  end)
  if not ok then warn("interner Fehler im Halt: " .. tostring(err)) end
  S.stop.refs:clear()
  S.stop = nil
  if not S.ch then S.step = nil end
  update_hooks()
  S.busy = false
end

-- Wertet text im Rahmen des Programms aus, das gerade den Hook ausgelöst
-- hat (Frame 0 über hooks.fn). Für Bedingungen und Logpoints.
local function eval_here(text)
  return eval.run(text, accessor({ k = 0, marker = hooks.fn, skip = 0 }))
end

local function hit_ok(cond, n)
  local op, num = cond:match("^%s*([<>=%%]*)%s*(%d+)%s*$")
  num = tonumber(num)
  if not num then return true end
  if op == "" or op == "==" or op == "=" then return n == num
  elseif op == ">" then return n > num
  elseif op == ">=" then return n >= num
  elseif op == "<" then return n < num
  elseif op == "<=" then return n <= num
  elseif op == "%" then return num > 0 and n % num == 0 end
  return true
end

local function plain(v)
  if type(v) == "string" then return v end
  return (vars.format(v))
end

-- Prüft Bedingung, Trefferzähler und Logpoint. Liefert anhalten(bool),
-- beschreibung. S.busy schützt vor Hooks im ausgewerteten Code.
local function check_bp(bp, line, src)
  if bp.condition and bp.condition ~= "" then
    S.busy = true
    local ok, r = eval_here(bp.condition)
    S.busy = false
    if not ok then
      output(("ljdap: Bedingung „%s“ fehlerhaft: %s\n"):format(bp.condition, r), "stderr")
      return true, "Bedingung fehlerhaft: " .. r
    end
    if not r[1] then return false end
  end
  bp.hits = bp.hits + 1
  if bp.hitCondition and bp.hitCondition ~= "" and not hit_ok(bp.hitCondition, bp.hits) then
    return false
  end
  if bp.logMessage and bp.logMessage ~= "" then
    S.busy = true
    local msg = bp.logMessage:gsub("{(.-)}", function(expr)
      local ok, r = eval_here(expr)
      if not ok then return "<" .. r .. ">" end
      local parts = {}
      for i = 1, r.n do parts[i] = plain(r[i]) end
      return table.concat(parts, ", ")
    end)
    S.busy = false
    local ev = { category = "console", output = msg .. "\n", line = line_out(line) }
    if src then ev.source = { name = src.path:match("([^/\\]+)$"), path = src.path } end
    S.ch:event("output", ev)
    return false
  end
  return true
end

-- Zeilen-Hook. Ebenen: 1 = on_line, 2 = Hook, 3 = Programm.
local function on_line(line)
  if S.busy or not S.ch then return end
  -- Vorfilter liegt im Hook (hooks.lua): hier nur noch Treffer-Kandidaten
  local step = S.step
  local info = getinfo(3, "S")
  if not info then return end
  local source = info.source
  if is_agent(source) then return end
  if S.bps.lines[line] then
    local src = S.mapper:from_source(source)
    local bp = S.bps:lookup(src, line)
    if bp then
      local stop, desc = check_bp(bp, line, src)
      if stop then
        local d = 3
        while getinfo(d, "l") do d = d + 1 end
        return enter_stop("breakpoint", hooks.fn, d - 3,
                          { hitBreakpointIds = { bp.id }, description = desc })
      end
    end
  end
  if step then
    local mode = step.mode
    local d = 3
    while getinfo(d, "l") do d = d + 1 end
    d = d - 3
    if mode == "in" or mode == "pause" then
      return enter_stop(step.reason or "step", hooks.fn, d)
    end
    local co = coroutine.running()
    if co == step.thread then
      if (mode == "over" and d <= step.depth) or (mode == "out" and d < step.depth) then
        return enter_stop("step", hooks.fn, d)
      end
    else
      -- anderer Thread: halten, wenn der Step-Thread nicht mehr läuft
      -- (yield oder Ende, zurück im Aufrufer); nicht, wenn er uns per
      -- resume aufgerufen hat (Status "normal"). Haupt-Coroutine (nil) ist
      -- in einer Coroutine immer "normal".
      local st = step.thread and coroutine.status(step.thread) or "normal"
      if st == "suspended" or st == "dead" then
        return enter_stop("step", hooks.fn, d)
      end
    end
  end
end

--- Programmatischer Halt (ljdap.breakhere). marker = öffentliche Funktion,
-- die den Programmcode direkt aufruft. Ebenen: 1 = hier, 2 = marker, 3 = Programm.
function M.breakhere(marker)
  if S.busy then return false end
  M.poll()
  if not S.ch or not S.configured then return false end
  local d = 3
  while getinfo(d, "l") do d = d + 1 end
  enter_stop("pause", marker, d - 3, { description = "ljdap.breakhere()" })
  return true
end

-- Rückruf aus ljdap.errors am Fehlerort. kind = "raised" | "uncaught".
local function on_error(err, kind, marker)
  if S.busy or not S.ch or not S.configured or S.stop then return end
  local exc = S.exc
  if kind == "raised" and not exc.raised then return end
  if kind == "uncaught" and not (exc.uncaught or exc.raised) then return end
  local text = errors.error_text(err)
  -- führende C-Rahmen (error, assert, Handler-Aufruf) überspringen
  local base = user_level(0, marker, 0)
  if not base then return end
  local skip = 0
  while true do
    local i = getinfo(base + skip, "S")
    if not i then skip = 0; break end
    if i.what ~= "C" then break end
    skip = skip + 1
  end
  local d = base + skip
  while getinfo(d, "l") do d = d + 1 end
  local label = kind == "uncaught" and "nicht abgefangener Fehler" or "Fehler (in pcall)"
  enter_stop("exception", marker, d - base - skip,
             { description = label, text = text, exc = { text = text, kind = kind } }, skip)
end

------------------------------------------------------------------------
-- Request-Behandlung
------------------------------------------------------------------------

local handlers = {}

local function need_stop(req)
  if not S.stop then
    S.ch:fail(req, "Programm ist nicht angehalten")
    return false
  end
  return true
end

function handlers.initialize(req)
  S.client = req.arguments or {}
  S.lines1 = S.client.linesStartAt1 ~= false
  S.cols1 = S.client.columnsStartAt1 ~= false
  S.ch:respond(req, {
    supportsConfigurationDoneRequest = true,
    supportsConditionalBreakpoints = true,
    supportsHitConditionalBreakpoints = true,
    supportsLogPoints = true,
    supportsSetVariable = true,
    supportsEvaluateForHovers = true,
    supportsExceptionInfoRequest = true,
    exceptionBreakpointFilters = {
      { filter = "uncaught", label = "Nicht abgefangene Fehler", default = true,
        description = "Hält, wenn ein Fehler das Programm (oder eine Coroutine) beenden würde" },
      { filter = "raised", label = "Alle Fehler (auch in pcall)", default = false,
        description = "Hält bei jedem Fehler, auch wenn pcall/xpcall ihn abfängt" },
    },
  })
  S.ch:event("initialized", json.object())
end

function handlers.attach(req)
  local args = req.arguments or {}
  S.mapper = paths.mapper(S.cwd, args.pathMappings)
  S.stop_on_entry = args.stopOnEntry == true
  S.ch:respond(req, json.object())
  local backend = S.opt.backend == "stdio" and "stdio" or (S.server and S.server.backend or "?")
  output(("ljdap %s verbunden (%s, Transport %s)\n"):format(
    VERSION, jit and jit.version or _VERSION, backend))
  if not S.cwd then
    output("ljdap: Arbeitsverzeichnis unbekannt – relative Quellpfade nicht auflösbar\n", "stderr")
  end
end

function handlers.launch(req)
  S.ch:fail(req, "launch wird erst im Starter-Modus unterstützt (geplant M4); bitte attach verwenden")
end

function handlers.setBreakpoints(req)
  local args = req.arguments or {}
  local src = args.source or {}
  local list = args.breakpoints
  if type(list) ~= "table" then
    -- veraltete Form: nur lines
    list = {}
    if type(args.lines) == "table" then
      for i, l in ipairs(args.lines) do list[i] = { line = l } end
    end
  end
  local reqs = {}
  for i, bp in ipairs(list) do
    local l = type(bp) == "table" and tonumber(bp.line) or 0
    reqs[i] = { line = line_in(l), condition = bp.condition, hitCondition = bp.hitCondition,
                logMessage = bp.logMessage }
  end
  local out = json.array()
  if type(src.path) ~= "string" or src.path == "" then
    for i, r in ipairs(reqs) do
      out[i] = { verified = false, line = line_out(r.line),
                 message = "Quelle ohne Dateipfad wird nicht unterstützt" }
    end
  else
    local key, abs = S.mapper:from_client(src.path)
    local res = S.bps:set(key, abs, reqs)
    for i, r in ipairs(res) do
      r.line = line_out(r.line)
      out[i] = r
    end
  end
  S.ch:respond(req, { breakpoints = out })
  update_hooks()
end

function handlers.setExceptionBreakpoints(req)
  local args = req.arguments or {}
  local exc = { uncaught = false, raised = false }
  for _, f in ipairs(type(args.filters) == "table" and args.filters or {}) do
    if f == "uncaught" or f == "raised" then exc[f] = true end
  end
  for _, o in ipairs(type(args.filterOptions) == "table" and args.filterOptions or {}) do
    if type(o) == "table" and (o.filterId == "uncaught" or o.filterId == "raised") then exc[o.filterId] = true end
  end
  S.exc = exc
  update_exc()
  S.ch:respond(req, json.object())
end

function handlers.setFunctionBreakpoints(req)
  S.ch:respond(req, { breakpoints = json.array() })
end

function handlers.configurationDone(req)
  S.ch:respond(req, json.object())
  S.state = "running"
  S.configured = true
  if S.stop_on_entry and not S.stop then
    S.step = { mode = "in", reason = "entry" }
  end
  update_exc()
  update_hooks()
end

function handlers.threads(req)
  S.ch:respond(req, { threads = threads.list() })
end

local function frame_of(info, id)
  local name = info.name
  if info.what == "main" then name = "Hauptchunk"
  elseif info.what == "tail" then name = "(tail call)"
  elseif not name and info.what == "Lua" then
    -- aus C aufgerufen (pcall, coroutine.resume …): Lua kennt keinen Namen
    name = (info.short_src or "?"):match("([^/\\]+)$") .. ":" .. tostring(info.linedefined)
  elseif not name then name = "?" end
  local f = { id = id, name = name, line = 0, column = 0 }
  if info.what == "C" then
    f.name = info.name and ("[C] " .. info.name) or "[C]"
    f.presentationHint = "subtle"
    return f
  end
  if info.what == "tail" then
    f.presentationHint = "label"
    return f
  end
  local s = S.mapper:from_source(info.source)
  if s then
    f.source = { name = s.path:match("([^/\\]+)$") or s.path, path = s.path }
  else
    local nm = info.source:sub(1, 1) == "=" and info.source:sub(2) or info.short_src
    f.source = { name = nm, presentationHint = "deemphasize" }
  end
  if info.currentline and info.currentline > 0 then
    f.line = line_out(info.currentline)
    f.column = S.cols1 and 1 or 0
  end
  return f
end

function handlers.stackTrace(req)
  if not need_stop(req) then return end
  local args = req.arguments or {}
  local first = tonumber(args.startFrame) or 0
  local levels = tonumber(args.levels) or 0
  if levels <= 0 then levels = MAX_FRAMES end
  local tid = tonumber(args.threadId) or S.stop.tid
  local reg = S.stop.frames
  local list = {}
  -- Agentenrahmen ausblenden
  local function add(info, fr)
    if info.what ~= "C" and info.what ~= "tail" and is_agent(info.source) then return end
    list[#list + 1] = { info = info, fr = fr }
  end
  if tid == S.stop.tid then
    local st = S.stop
    local base = user_level(0, st.marker, st.skip)
    local k = 0
    while base and k < MAX_FRAMES do
      local info = getinfo(base + k, "nSl")
      if not info then break end
      add(info, { k = k, marker = st.marker, skip = st.skip })
      k = k + 1
    end
  else
    local co, is_main = threads.get(tid)
    if is_main then
      list[1] = { pseudo = "(Haupt-Coroutine, wartet in coroutine.resume)" }
    elseif co and coroutine.status(co) ~= "dead" then
      local lv = 0
      while lv < MAX_FRAMES do
        local info = getinfo(co, lv, "nSl")
        if not info then break end
        add(info, { co = co, lv = lv })
        lv = lv + 1
      end
    end
  end
  -- C-Rahmen am Boden (Interpreter, Agent-Aufrufer) abschneiden
  while #list > 1 and list[#list].info and list[#list].info.what == "C" do list[#list] = nil end
  local frames = json.array()
  for i = first + 1, math.min(#list, first + levels) do
    local e = list[i]
    local id = #reg + 1
    reg[id] = e.fr or false
    if e.pseudo then
      frames[#frames + 1] = { id = id, name = e.pseudo, line = 0, column = 0, presentationHint = "label" }
    else
      frames[#frames + 1] = frame_of(e.info, id)
    end
  end
  S.ch:respond(req, { stackFrames = frames, totalFrames = #list })
end

local function frame_ref(id)
  local fr = S.stop.frames[tonumber(id) or 0]
  if fr == nil then
    fr = { k = (tonumber(id) or 1) - 1, marker = S.stop.marker, skip = S.stop.skip }
  end
  return fr or nil
end

function handlers.scopes(req)
  if not need_stop(req) then return end
  local fr = frame_ref((req.arguments or {}).frameId)
  local refs = S.stop.refs
  local scopes = json.array()
  if fr then
    local acc = accessor(fr)
    local info = acc.info("Sf")
    if info and info.what ~= "C" and info.what ~= "tail" then
      scopes[#scopes + 1] = { name = "Lokal", presentationHint = "locals", expensive = false,
                              variablesReference = refs:add({ kind = "locals", fr = fr }) }
      if acc.getlocal(-1) ~= nil then
        scopes[#scopes + 1] = { name = "Varargs", presentationHint = "arguments", expensive = false,
                                variablesReference = refs:add({ kind = "varargs", fr = fr }) }
      end
      if info.func and getupvalue(info.func, 1) ~= nil then
        scopes[#scopes + 1] = { name = "Upvalues", expensive = false,
                                variablesReference = refs:add({ kind = "upvalues", fr = fr }) }
      end
      local env = info.func and getfenv(info.func) or _G
      scopes[#scopes + 1] = { name = env == _G and "Global" or "Umgebung (fenv)", expensive = true,
                              variablesReference = refs:add({ kind = "value", value = env, fr = fr }) }
    end
  end
  S.ch:respond(req, { scopes = scopes })
end

function handlers.variables(req)
  if not need_stop(req) then return end
  local args = req.arguments or {}
  local refs = S.stop.refs
  local item = refs:get(args.variablesReference)
  local list = json.array()
  if item then
    if item.kind == "value" then
      for i, v in ipairs(vars.children(refs, item, args.start, args.count)) do list[i] = v end
    else
      local acc = accessor(item.fr)
      item.names = {}
      if item.kind == "locals" then
        local i = 1
        while true do
          local name, v = acc.getlocal(i)
          if not name then break end
          if name:sub(1, 1) ~= "(" then
            list[#list + 1] = vars.variable(refs, name, v, item.fr)
            item.names[name] = i
          end
          i = i + 1
        end
      elseif item.kind == "varargs" then
        local i = 1
        while true do
          local name, v = acc.getlocal(-i)
          if not name then break end
          list[#list + 1] = vars.variable(refs, "[" .. i .. "]", v, item.fr)
          i = i + 1
        end
      elseif item.kind == "upvalues" then
        local info = acc.info("f")
        local f = info and info.func
        local i = 1
        while f do
          local name, v = getupvalue(f, i)
          if not name then break end
          local nm = name ~= "" and name or ("?" .. i)
          list[#list + 1] = vars.variable(refs, nm, v, item.fr)
          item.names[nm] = i
          i = i + 1
        end
      end
    end
  end
  S.ch:respond(req, { variables = list })
end

function handlers.evaluate(req)
  local args = req.arguments or {}
  local acc, fr
  if S.stop then
    fr = args.frameId and frame_ref(args.frameId)
      or { k = 0, marker = S.stop.marker, skip = S.stop.skip }
    acc = accessor(fr)
  end
  local ok, r = eval.run(args.expression, acc)
  if not ok then
    S.ch:fail(req, r)
    return
  end
  local refs = S.stop and S.stop.refs or vars.refs()
  if r.n == 0 then
    S.ch:respond(req, { result = "", variablesReference = 0 })
  elseif r.n == 1 then
    local v = vars.variable(refs, "", r[1], fr)
    if not S.stop then v.variablesReference = 0 end
    S.ch:respond(req, { result = v.value, type = v.type, variablesReference = v.variablesReference })
  else
    local parts = {}
    for i = 1, r.n do parts[i] = (vars.format(r[i])) end
    S.ch:respond(req, { result = table.concat(parts, ", "), variablesReference = 0 })
  end
end

function handlers.setVariable(req)
  if not need_stop(req) then return end
  local args = req.arguments or {}
  local refs = S.stop.refs
  local item = refs:get(args.variablesReference)
  local name = args.name
  if not item or type(name) ~= "string" then
    S.ch:fail(req, "unbekannte Variable")
    return
  end
  local fr = item.fr
  local acc = fr and accessor(fr)
  local ok, r = eval.run(args.value, acc)
  if not ok then
    S.ch:fail(req, r)
    return
  end
  local v = r[1]
  if item.kind == "locals" then
    local idx = item.names and item.names[name]
    if not idx then S.ch:fail(req, "lokale Variable nicht gefunden: " .. name); return end
    acc.setlocal(idx, v)
  elseif item.kind == "varargs" then
    local i = tonumber(name:match("^%[(%d+)%]$"))
    if not i then S.ch:fail(req, "ungültiger Vararg-Name"); return end
    acc.setlocal(-i, v)
  elseif item.kind == "upvalues" then
    local u = item.names and item.names[name]
    local info = acc.info("f")
    if not u or not info then S.ch:fail(req, "Upvalue nicht gefunden: " .. name); return end
    debug.setupvalue(info.func, u, v)
  elseif item.kind == "value" and type(item.value) == "table" then
    local key = item.keymap and item.keymap[name]
    if key == nil then S.ch:fail(req, "Schlüssel nicht gefunden: " .. name); return end
    rawset(item.value, key, v)
    item.keys = nil -- neu sortieren beim nächsten Abruf
  else
    S.ch:fail(req, "Variable nicht änderbar")
    return
  end
  local var = vars.variable(refs, name, v, fr)
  S.ch:respond(req, { value = var.value, type = var.type, variablesReference = var.variablesReference })
end

function handlers.exceptionInfo(req)
  if not need_stop(req) then return end
  local e = S.stop.exc
  if not e then
    S.ch:fail(req, "kein Fehler-Halt")
    return
  end
  S.ch:respond(req, {
    exceptionId = e.kind == "uncaught" and "Lua-Fehler (nicht abgefangen)" or "Lua-Fehler (in pcall)",
    description = e.text,
    breakMode = e.kind == "uncaught" and "unhandled" or "always",
    details = { message = e.text },
  })
end

function handlers.pause(req)
  S.ch:respond(req, json.object())
  if not S.stop then
    S.step = { mode = "pause", reason = "pause" }
    update_hooks()
  end
end

local function resume_with(req, step)
  if not need_stop(req) then return end
  S.step = step
  S.ch:respond(req, { allThreadsContinued = true })
  S.resume = true
end

function handlers.continue(req) resume_with(req, nil) end
function handlers.next(req)
  resume_with(req, S.stop and { mode = "over", depth = S.stop.depth, thread = S.stop.thread })
end
function handlers.stepIn(req) resume_with(req, { mode = "in" }) end
function handlers.stepOut(req)
  resume_with(req, S.stop and { mode = "out", depth = S.stop.depth, thread = S.stop.thread })
end

local jit_for_client -- vorwärts, s. u.

local function drop_client()
  if S.ch then
    S.ch:close()
    jit_for_client(false)
  end
  S.ch = nil
  S.client = nil
  S.step = nil
  S.resume = true -- ein laufender Halt endet; das Programm läuft weiter
  if S.server then S.state = "listening" else S.state = "idle" end
  update_hooks()
  update_exc()
end

function handlers.disconnect(req)
  -- terminateDebuggee wird nicht ausgewertet: das Programm läuft weiter
  S.ch:respond(req, json.object())
  drop_client()
end

local function dispatch(msg)
  if msg.type ~= "request" then return end
  local h = handlers[msg.command]
  if not h then
    S.ch:fail(msg, "nicht unterstützt: " .. tostring(msg.command))
    return
  end
  local ok, err = pcall(h, msg)
  if not ok and S.ch then
    S.ch:fail(msg, "interner Fehler in " .. tostring(msg.command) .. ": " .. tostring(err))
  end
end

------------------------------------------------------------------------
-- Verbindungsverwaltung
------------------------------------------------------------------------

-- JIT bei verbundenem Client aus: Hooks feuern nicht in Traces (Konzept 6).
-- jit.flush() verwirft vorhandene Traces, sonst liefen sie weiter.
jit_for_client = function(connected)
  if not jit or S.opt.jit == "off" then return end
  if connected then
    S.jit_was_on = jit.status()
    jit.off()
    jit.flush()
  elseif S.jit_was_on then
    S.jit_was_on = nil
    jit.on()
  end
end

local function on_connect(con)
  S.ch = protocol.channel(con, S.logfile and log or nil)
  S.state = "connected"
  S.bps:clear()           -- ein neuer Client schickt alle Haltepunkte neu
  S.exc = { uncaught = false, raised = false }
  S.mapper = paths.mapper(S.cwd)
  S.lines1, S.cols1 = true, true
  jit_for_client(true)
  log("--", "Client verbunden")
end

-- Liest und behandelt Nachrichten. ms wie Channel:read. Liefert true, wenn
-- mindestens eine Nachricht behandelt wurde.
service = function(ms)
  local any = false
  while S.ch do
    local msg, err, bad = S.ch:read(any and 0 or ms)
    if msg then
      dispatch(msg)
      any = true
      if S.resume and S.stop then break end
    elseif bad then
      log("!!", bad)
      output("ljdap: " .. bad .. "\n", "stderr")
      any = true
    elseif err then
      log("--", "Client getrennt: " .. tostring(err))
      drop_client()
      break
    else
      break
    end
  end
  return any
end

local function try_accept(ms)
  if not S.server then return false end
  if ms ~= 0 and not S.server:wait(ms) then return false end
  local con, err = S.server:accept()
  if con then
    on_connect(con)
    return true
  end
  if err then log("!!", err) end
  return false
end

--- Fragt Socket und Client ohne Blockieren ab. Für Hauptschleifen von
-- Programmen, deren Code unter LuaJIT kompiliert läuft (Count-Hook feuert
-- dort nicht). Billig, wenn nichts anliegt (ein poll()-Systemaufruf).
function M.poll()
  if S.busy or S.state == "idle" then return end
  S.busy = true
  local ok, err = pcall(function()
    if not S.ch then try_accept(0) end
    if S.ch then service(0) end
  end)
  S.busy = false
  if not ok then warn("interner Fehler: " .. tostring(err)) end
end

-- Blockiert, bis ein Client configurationDone geschickt hat.
local function wait_configured()
  S.busy = true
  local ok, err = pcall(function()
    -- nicht auf state prüfen: ein disconnect direkt nach configurationDone
    -- (im selben Lesedurchgang) setzt state wieder auf "listening"
    while not S.configured and S.state ~= "idle" do
      if not S.ch then
        try_accept(-1)
      else
        service(-1)
      end
    end
  end)
  S.busy = false
  if not ok then warn("interner Fehler: " .. tostring(err)) end
end

hooks.init(on_line, M.poll)
hooks.set_threads(threads.each)
errors.on_error = on_error

------------------------------------------------------------------------
-- Öffentlich
------------------------------------------------------------------------

--- Wandelt "port=4711,wait=1,host=…" in eine Optionstabelle.
function M.parse_env(s)
  local o = {}
  for item in (s or ""):gmatch("[^,;]+") do
    local k, v = item:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if not k then
      k, v = item:match("^%s*([%w_]+)%s*$"), "1"
    end
    if k then
      if k == "port" or k == "poll" then v = tonumber(v)
      elseif k == "wait" then v = (v == "1" or v == "true" or v == "yes")
      end
      o[k] = v
    end
  end
  return o
end

--- Startet den Agenten. Liefert true oder nil, fehlertext; bricht das
-- Programm nie ab.
function M.start(opt)
  if S.state ~= "idle" then return true end
  local o = {}
  for k, v in pairs(DEFAULTS) do o[k] = v end
  for k, v in pairs(opt or {}) do o[k] = v end
  S.opt = o
  S.cwd = paths.getcwd()
  S.mapper = paths.mapper(S.cwd)
  if o.log then
    S.logfile = io.open(o.log, "a")
    if not S.logfile then warn("Protokolldatei nicht beschreibbar: " .. tostring(o.log)) end
    log("--", "ljdap " .. VERSION .. " Start, cwd " .. tostring(S.cwd))
  end
  if o.jit == "off" and jit then jit.off() end
  -- Coroutinen als Threads; unter LuaJIT Körper unter xpcall (Fehler-Halt)
  threads.install(hooks.attach, errors.is_luajit and errors.body_wrap or nil)
  errors.install_traceback()
  if hooks.foreign() then
    warn("vorhandener debug.sethook-Hook (Profiler?) – ljdap-Hooks aus, nur ljdap.poll() und breakhere()")
  end

  if o.backend == "stdio" then
    -- stdio: genau ein Client, immer blockierend bis configurationDone
    on_connect(transport.stdio())
    wait_configured()
    update_hooks()
    return true
  end

  local srv, err = transport.listen(o.host, o.port, { backend = o.backend })
  if not srv then
    warn("Start fehlgeschlagen: " .. tostring(err) .. " – Programm läuft ohne Debugger")
    S.opt = nil
    return nil, err
  end
  S.server = srv
  S.state = "listening"
  log("--", ("warte auf %s:%d (%s)"):format(o.host, o.port, srv.backend))
  if o.wait then
    warn(("%s – warte auf DAP-Client an %s:%d"):format(VERSION, o.host, o.port))
    wait_configured()
  end
  update_hooks()
  return true
end

--- Beendet den Agenten: trennt den Client, schließt den Server.
function M.stop()
  if S.state == "idle" then return true end
  hooks.remove()
  if S.ch then
    S.ch:event("terminated", json.object())
  end
  drop_client()
  hooks.remove()
  if S.server then S.server:close() end
  S.server = nil
  S.state = "idle"
  S.configured = false
  if S.logfile then S.logfile:close(); S.logfile = nil end
  return true
end

function M.state() return S.state end

return M
end

-- Hauptmodul (src/ljdap/init.lua)
-- ljdap – DAP-Server in reinem Lua für LuaJIT 2.1 und Lua 5.1.
--
-- Einbindung:
--   luajit -l ljdap skript.lua                  startet mit Vorgaben bzw. LJDAP
--   LJDAP="port=4711,wait=1" luajit -l ljdap skript.lua
--   local dbg = require("ljdap"); dbg.start{ port = 4711, wait = true }
--
-- Automatischer Start beim Laden, wenn die Umgebungsvariable LJDAP gesetzt
-- ist (auch leer) oder das Modul über `-l ljdap` geladen wurde. Ein
-- späteres dbg.start{…} wirkt dann nicht mehr (bereits gestartet).
--
-- Öffentliche Funktionen:
--   start(opt) -> true | nil, err   opt: host, port, wait, backend, poll, jit, log
--   stop()     -> true
--   poll()                          in Hauptschleifen aufrufen (siehe README)
--   breakhere()                     programmatischer Haltepunkt (ab M2)
--   VERSION

local session = require("ljdap.session")

local M = {
  VERSION = require("ljdap.version"),
  start = session.start,
  stop = session.stop,
  poll = session.poll,
  state = session.state,
}

--- Programmatischer Haltepunkt; ohne verbundenen Client wirkungslos.
-- Liefert true, wenn angehalten wurde.
function M.breakhere()
  -- kein Tail Call: der Rahmen dieser Funktion dient als Markierung
  local stopped = session.breakhere(M.breakhere)
  return stopped
end

-- Geladen über `luajit -l ljdap`? Dann ruft C (lua.c/luajit.c) require auf:
-- Ebene 1 = dieser Chunk, 2 = require, 3 = C statt Lua-Aufrufer.
local function loaded_by_dash_l()
  local info = debug.getinfo(4, "S")
  -- Ebene 4 von hier aus = Ebene 3 vom Chunk aus
  return info == nil or info.what == "C"
end

-- LuaJIT mit `luajit [optionen] -l ljdap skript.lua args…`: das Skript selbst
-- unter xpcall ausführen, damit nicht abgefangene Fehler am Fehlerort
-- anhalten können (luajit.c ruft dafür kein Lua auf). Nur wenn -l ljdap die
-- letzte Option vor dem Skript ist; abschaltbar mit LJDAP="run=0".
-- Lua 5.1 braucht das nicht (ljdap.errors ersetzt debug.traceback).
local function takeover(opt)
  if not jit or opt.run == "0" or opt.run == false then return end
  if type(arg) ~= "table" or type(arg[0]) ~= "string" or arg[0] == "-" then return end
  if not ((arg[-2] == "-l" and arg[-1] == "ljdap") or arg[-1] == "-lljdap") then return end
  local n, args = 0, {}
  for i = 1, #arg do n = i; args[i] = arg[i] end
  args.n = n
  local lowest = -1
  while arg[lowest - 1] ~= nil do lowest = lowest - 1 end
  local progname = arg[lowest] or "luajit"
  -- Das Skript läuft noch innerhalb von require("ljdap"): vorher eintragen,
  -- sonst meldet ein require("ljdap") im Skript eine Ladeschleife
  package.loaded["ljdap"] = M
  require("ljdap.errors").run_script(arg[0], args, progname)
end

local env = os.getenv("LJDAP")
local dash_l = loaded_by_dash_l()
if env or dash_l then
  local opt = session.parse_env(env)
  M.start(opt)
  if dash_l then takeover(opt) end
end

return M
