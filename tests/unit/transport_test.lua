local T = dofile("tests/unit/t.lua")
local transport = require("ljdap.transport")
local protocol = require("ljdap.protocol")
local eq, check, case = T.eq, T.check, T.case

case("Rahmen: ganze und geteilte Nachrichten", function()
  local f = transport.framer()
  eq(f:next(), nil)
  local a, b = '{"seq":1}', '{"seq":2,"x":"ä"}'
  local data = transport.frame(a) .. transport.frame(b)
  -- byteweise einspeisen
  local got = {}
  for i = 1, #data do
    f:feed(data:sub(i, i))
    local body = f:next()
    while body do got[#got + 1] = body; body = f:next() end
  end
  eq(got, { a, b })
  eq(transport.frame(b):match("Content%-Length: (%d+)"), tostring(#b), "Länge in Bytes")
end)

case("Rahmen: Kopfvarianten und Fehler", function()
  local f = transport.framer()
  f:feed("content-length:3\r\nContent-Type: x\r\n\r\nabc")
  eq(f:next(), "abc", "Kleinschreibung, Zusatzfeld")
  f:feed("Foo: 1\r\n\r\nxyz")
  local v, err = f:next()
  check(v == nil and err and err:find("ungültiger Kopf"), "Kopf ohne Länge")
  f:feed("Content-Length: -1\r\n\r\n")
  v, err = f:next()
  check(v == nil and err, "negative Länge")
  f:feed(string.rep("x", 9000))
  v, err = f:next()
  check(v == nil and err and err:find("zu lang"), "Kopf ohne Ende")
  f:feed(transport.frame("ok"))
  eq(f:next(), "ok", "nach Fehler wieder lesbar")
end)

case("listen: Parameterprüfung", function()
  local s, err = transport.listen("127.0.0.1", 70000)
  check(s == nil and err:find("ungültiger Port"), "Port zu groß")
  s, err = transport.listen("127.0.0.1", 1.5)
  check(s == nil and err:find("ungültiger Port"), "Port gebrochen")
  s, err = transport.listen("kein.host", 4711)
  check(s == nil and err:find("IPv4"), "Hostname statt Adresse")
  s, err = transport.listen("127.0.0.1", 4711, { backend = "gibtsnicht" })
  check(s == nil and err:find("unbekanntes Backend"), "Backend")
end)

-- Loopback mit LuaSocket als Client (nur wo vorhanden)
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath
package.path = "/usr/share/lua/5.1/?.lua;" .. package.path
local has_socket, socket = pcall(require, "socket")

local function free_port()
  local s = socket.bind("127.0.0.1", 0)
  local _, port = s:getsockname()
  s:close()
  return tonumber(port)
end

local function loopback(backend)
  local port = free_port()
  local srv, err = transport.listen("127.0.0.1", port, { backend = backend })
  check(srv, "listen " .. tostring(err))
  if not srv then return end
  eq(srv.backend, backend)
  local c, aerr = srv:accept()
  check(c == nil and aerr == nil, "accept ohne Client liefert nil")
  local cli = assert(socket.connect("127.0.0.1", port))
  check(srv:wait(2000), "wait meldet wartende Verbindung")
  c = srv:accept()
  check(c, "accept")
  if not c then return end
  eq(c:receive(), "", "nichts da")
  check(not c:wait(50), "wait mit Zeitgrenze ohne Daten")
  cli:send("hallo")
  check(c:wait(2000), "wait mit Daten")
  eq(c:receive(), "hallo")
  cli:settimeout(5)
  local ch = protocol.channel(c)
  -- Die Gegenseite liest erst nach dem Senden; der Block muss in die
  -- Socketpuffer passen (größere Blöcke: send() wartet, s. Szenarien)
  local mid = string.rep("x", 100000)
  check(c:send(mid), "send 100 kB")
  local got = assert(cli:receive(#mid))
  eq(#got, #mid)
  check(ch:event("output", { output = "ä" }), "Event senden")
  local head = assert(cli:receive("*l"))
  check(head:find("Content%-Length: %d+"), "Kopf")
  cli:close()
  check(c:wait(2000), "wait nach Schließen der Gegenseite")
  local d, rerr = c:receive()
  check(d == nil and rerr == "closed", "closed erkannt")
  check(c.closed, "Verbindung als geschlossen markiert")
  srv:close()
end

if has_socket then
  case("Loopback FFI", function()
    if not pcall(require, "ffi") then return end
    local ffi = require("ffi")
    loopback(ffi.os == "Windows" and "windows" or "posix")
  end)
  case("Loopback LuaSocket", function() loopback("luasocket") end)
else
  io.stderr:write("  (Loopback übersprungen: LuaSocket fehlt)\n")
end

T.finish()
