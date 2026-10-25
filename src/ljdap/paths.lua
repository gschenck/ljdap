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
