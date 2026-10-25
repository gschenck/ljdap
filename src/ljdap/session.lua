-- ljdap.session – Zustand des Agenten und Behandlung der DAP-Requests.
--
-- Stand M1: Verbindung, Initialisierung, Anhängen, Trennen. Haltepunkte,
-- Stepping und Variablen folgen ab M2 (hooks.lua, breakpoints.lua, vars.lua).
--
-- Zustände:
--   idle       nicht gestartet
--   listening  Server offen, kein Client
--   connected  Client verbunden, Konfiguration läuft
--   running    configurationDone erhalten
--
-- Abfrage des Sockets im laufenden Programm: Count-Hook (alle opt.poll
-- Anweisungen) auf der Haupt-Coroutine und ljdap.poll() für Hauptschleifen.
-- Unter LuaJIT feuert der Count-Hook nicht in kompiliertem Code; daher
-- opt.jit = "off" oder ljdap.poll() in der Ereignisschleife (siehe README).
--
-- Fehlerkonvention: öffentliche Funktionen liefern true | nil, err; Fehler
-- in Handlern werden als Fehlerantwort gemeldet, nie an das Programm
-- weitergereicht.

local json = require("ljdap.json")
local transport = require("ljdap.transport")
local protocol = require("ljdap.protocol")
local VERSION = require("ljdap.version")

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

local S = {
  state = "idle",
  opt = nil,
  server = nil,
  ch = nil,
  busy = false,     -- Wiedereintrittssperre
  client = nil,     -- Argumente von initialize
  configured = false, -- einmal configurationDone erhalten (gibt wait frei)
  logfile = nil,
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

------------------------------------------------------------------------
-- Request-Behandlung
------------------------------------------------------------------------

local handlers = {}

function handlers.initialize(req)
  S.client = req.arguments or {}
  S.ch:respond(req, {
    supportsConfigurationDoneRequest = true,
    exceptionBreakpointFilters = json.array(),
  })
  S.ch:event("initialized", json.object())
end

function handlers.attach(req)
  S.ch:respond(req, json.object())
  local backend = S.opt.backend == "stdio" and "stdio" or (S.server and S.server.backend or "?")
  output(("ljdap %s verbunden (%s, Transport %s)\n"):format(
    VERSION, jit and jit.version or _VERSION, backend))
end

function handlers.launch(req)
  S.ch:fail(req, "launch wird erst im Starter-Modus unterstützt (geplant M4); bitte attach verwenden")
end

function handlers.setBreakpoints(req)
  local args = req.arguments or {}
  local list = json.array()
  local bps = args.breakpoints
  if type(bps) ~= "table" then
    -- veraltete Form: nur lines
    bps = {}
    if type(args.lines) == "table" then
      for i, l in ipairs(args.lines) do bps[i] = { line = l } end
    end
  end
  for i, bp in ipairs(bps) do
    local line = type(bp) == "table" and tonumber(bp.line) or nil
    list[i] = { verified = false, line = line,
                message = "Haltepunkte werden ab ljdap-Meilenstein M2 unterstützt" }
  end
  S.ch:respond(req, { breakpoints = list })
end

function handlers.setExceptionBreakpoints(req)
  S.ch:respond(req, json.object())
end

function handlers.setFunctionBreakpoints(req)
  S.ch:respond(req, { breakpoints = json.array() })
end

function handlers.configurationDone(req)
  S.ch:respond(req, json.object())
  S.state = "running"
  S.configured = true
end

function handlers.threads(req)
  S.ch:respond(req, { threads = { { id = 1, name = "main" } } })
end

local jit_for_client -- vorwärts, s. u.

local function drop_client()
  if S.ch then
    S.ch:close()
    jit_for_client(false)
  end
  S.ch = nil
  S.client = nil
  if S.server then S.state = "listening" else S.state = "idle" end
end

function handlers.disconnect(req)
  -- terminateDebuggee wird in M1 nicht ausgewertet: das Programm läuft weiter
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
  jit_for_client(true)
  log("--", "Client verbunden")
end

-- Liest und behandelt Nachrichten. ms wie Channel:read. Liefert true, wenn
-- mindestens eine Nachricht behandelt wurde.
local function service(ms)
  local any = false
  while S.ch do
    local msg, err, bad = S.ch:read(any and 0 or ms)
    if msg then
      dispatch(msg)
      any = true
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

local function hook_fn()
  M.poll()
end

local function install_hook(count)
  if count <= 0 then return end
  local h = debug.gethook()
  if h and h ~= hook_fn then
    warn("vorhandener debug.sethook-Hook (Profiler?) – Abfrage per Hook aus, ljdap.poll() nutzen")
    return
  end
  debug.sethook(hook_fn, "", count)
end

local function remove_hook()
  if debug.gethook() == hook_fn then debug.sethook() end
end

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
  if o.log then
    S.logfile = io.open(o.log, "a")
    if not S.logfile then warn("Protokolldatei nicht beschreibbar: " .. tostring(o.log)) end
    log("--", "ljdap " .. VERSION .. " Start")
  end
  if o.jit == "off" and jit then jit.off() end

  if o.backend == "stdio" then
    -- stdio: genau ein Client, immer blockierend bis configurationDone
    on_connect(transport.stdio())
    wait_configured()
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
  install_hook(o.poll)
  return true
end

--- Beendet den Agenten: trennt den Client, schließt den Server.
function M.stop()
  if S.state == "idle" then return true end
  remove_hook()
  if S.ch then
    S.ch:event("terminated", json.object())
  end
  drop_client()
  if S.server then S.server:close() end
  S.server = nil
  S.state = "idle"
  S.configured = false
  if S.logfile then S.logfile:close(); S.logfile = nil end
  return true
end

function M.state() return S.state end

return M
