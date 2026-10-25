-- ljdap.session – Zustand des Agenten und Behandlung der DAP-Requests.
--
-- Stand M2: Verbindung, Anhängen, Haltepunkte, Stepping (in/over/out),
-- Stack, Scopes und Variablen auf der Haupt-Coroutine. Coroutinen,
-- evaluate/setVariable, Fehler-Halt, Bedingungen/Logpoints und Pause
-- folgen in M3.
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

local json = require("ljdap.json")
local transport = require("ljdap.transport")
local protocol = require("ljdap.protocol")
local paths = require("ljdap.paths")
local breakpoints = require("ljdap.breakpoints")
local vars = require("ljdap.vars")
local hooks = require("ljdap.hooks")
local VERSION = require("ljdap.version")

local getinfo, getlocal, getupvalue = debug.getinfo, debug.getlocal, debug.getupvalue

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

-- Quellen des Agenten selbst: beim Steppen überspringen. Unter Windows
-- erzeugt require gemischte Trenner ("src/ljdap\\session.lua", aber
-- "src/ljdap/init.lua"), daher mit vereinheitlichten Trennern vergleichen.
local AGENT_PREFIX = (getinfo(1, "S").source:gsub("\\", "/"):match("^(@.*/)")) or "@\0"
local agent_cache = setmetatable({}, { __mode = "k" })
local function is_agent(source)
  local r = agent_cache[source]
  if r == nil then
    r = source:gsub("\\", "/"):sub(1, #AGENT_PREFIX) == AGENT_PREFIX
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
  step = nil,         -- { mode = "in"|"over"|"out", depth = n }
  stop = nil,         -- { marker, reason, depth, refs }
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

-- Ebene von Frame k des angehaltenen Programms, relativ zum Aufrufer.
-- (Ebene 1 = diese Funktion, 2 = Aufrufer; Markierung bei l -> Frame 0
-- liegt für den Aufrufer bei Ebene l.)
local function user_level(k)
  local marker = S.stop and S.stop.marker
  if not marker then return nil end
  for l = 2, 10000 do
    local i = getinfo(l, "f")
    if not i then return nil end
    if i.func == marker then return l + (k or 0) end
  end
  return nil
end

------------------------------------------------------------------------
-- Halt
------------------------------------------------------------------------

local service -- vorwärts

-- Hält das Programm an. marker: Funktion direkt unter Frame 0;
-- depth: Stacktiefe von Frame 0 (für Step over/out).
local function enter_stop(reason, marker, depth, extra)
  S.busy = true
  S.step = nil
  S.stop = { marker = marker, reason = reason, depth = depth, refs = vars.refs() }
  S.resume = false
  local body = { reason = reason, threadId = 1, allThreadsStopped = true }
  if extra then for k, v in pairs(extra) do body[k] = v end end
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

-- Zeilen-Hook. Ebenen: 1 = on_line, 2 = Hook, 3 = Programm.
local function on_line(line)
  if S.busy or not S.ch then return end
  -- Vorfilter liegt im Hook (hooks.lua): hier nur noch Treffer-Kandidaten
  local step = S.step
  local bp_line = S.bps.lines[line]
  local info = getinfo(3, "S")
  if not info then return end
  local source = info.source
  if is_agent(source) then return end
  if bp_line then
    local bp = S.bps:lookup(S.mapper:from_source(source), line)
    if bp then
      local d = 3
      while getinfo(d, "l") do d = d + 1 end
      return enter_stop("breakpoint", hooks.fn, d - 3, { hitBreakpointIds = { bp.id } })
    end
  end
  if step then
    local mode = step.mode
    local d = 3
    while getinfo(d, "l") do d = d + 1 end
    d = d - 3
    if mode == "in" or (mode == "over" and d <= step.depth) or (mode == "out" and d < step.depth) then
      return enter_stop(step.reason or "step", hooks.fn, d)
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
    exceptionBreakpointFilters = json.array(),
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
                 message = "Quelle ohne Pfad wird erst ab M3 unterstützt" }
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
  update_hooks()
end

function handlers.threads(req)
  S.ch:respond(req, { threads = { { id = 1, name = "main" } } })
end

local function frame_of(info, k)
  local name = info.name
  if info.what == "main" then name = "Hauptchunk"
  elseif info.what == "tail" then name = "(tail call)"
  elseif not name then name = "?" end
  local f = { id = k + 1, name = name, line = 0, column = 0 }
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
  local base = user_level(0)
  local frames = json.array()
  local k = 0
  while base and k < MAX_FRAMES do
    local info = getinfo(base + k, "nSl")
    if not info then break end
    if k >= first and #frames < levels then
      frames[#frames + 1] = frame_of(info, k)
    end
    k = k + 1
  end
  S.ch:respond(req, { stackFrames = frames, totalFrames = k })
end

function handlers.scopes(req)
  if not need_stop(req) then return end
  local k = (tonumber((req.arguments or {}).frameId) or 1) - 1
  local refs = S.stop.refs
  local lv = user_level(k)
  local scopes = json.array()
  if lv then
    local info = getinfo(lv, "Sf")
    if info and info.what ~= "C" and info.what ~= "tail" then
      scopes[#scopes + 1] = { name = "Lokal", presentationHint = "locals", expensive = false,
                              variablesReference = refs:add({ kind = "locals", frame = k }) }
      if getlocal(lv, -1) ~= nil then
        scopes[#scopes + 1] = { name = "Varargs", presentationHint = "arguments", expensive = false,
                                variablesReference = refs:add({ kind = "varargs", frame = k }) }
      end
      if info.func and getupvalue(info.func, 1) ~= nil then
        scopes[#scopes + 1] = { name = "Upvalues", expensive = false,
                                variablesReference = refs:add({ kind = "upvalues", frame = k }) }
      end
      local env = info.func and getfenv(info.func) or _G
      scopes[#scopes + 1] = { name = env == _G and "Global" or "Umgebung (fenv)", expensive = true,
                              variablesReference = refs:add({ kind = "value", value = env }) }
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
      local lv = user_level(item.frame)
      if lv then
        if item.kind == "locals" then
          local i = 1
          while true do
            local name, v = getlocal(lv, i)
            if not name then break end
            if name:sub(1, 1) ~= "(" then list[#list + 1] = vars.variable(refs, name, v) end
            i = i + 1
          end
        elseif item.kind == "varargs" then
          local i = 1
          while true do
            local name, v = getlocal(lv, -i)
            if not name then break end
            list[#list + 1] = vars.variable(refs, "[" .. i .. "]", v)
            i = i + 1
          end
        elseif item.kind == "upvalues" then
          local f = getinfo(lv, "f").func
          local i = 1
          while true do
            local name, v = getupvalue(f, i)
            if not name then break end
            list[#list + 1] = vars.variable(refs, name ~= "" and name or ("?" .. i), v)
            i = i + 1
          end
        end
      end
    end
  end
  S.ch:respond(req, { variables = list })
end

local function resume_with(req, step)
  if not need_stop(req) then return end
  S.step = step
  S.ch:respond(req, { allThreadsContinued = true })
  S.resume = true
end

function handlers.continue(req) resume_with(req, nil) end
function handlers.next(req) resume_with(req, { mode = "over", depth = S.stop and S.stop.depth }) end
function handlers.stepIn(req) resume_with(req, { mode = "in" }) end
function handlers.stepOut(req) resume_with(req, { mode = "out", depth = S.stop and S.stop.depth }) end

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
