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
