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
