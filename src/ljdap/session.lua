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
    supportsTerminateRequest = true,
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
  S.launched = req.command == "launch"
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

-- launch: Das Programm läuft bereits (vom Editor gestartet, typisch über
-- den Starter-Modus `lua ljdap.lua --port … skript.lua`); ljdap verhält sich
-- wie bei attach, beendet das Programm aber beim Trennen (Stopp-Knopf).
function handlers.launch(req)
  handlers.attach(req)
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
  -- C- und Tail-Call-Rahmen am Boden (Interpreter, Agent-Aufrufer) abschneiden
  while #list > 1 and list[#list].info
    and (list[#list].info.what == "C" or list[#list].info.what == "tail") do
    list[#list] = nil
  end
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

local function terminate_program()
  if S.ch then S.ch:event("terminated", json.object()) end
  drop_client()
  if S.server then S.server:close() end
  io.stdout:flush()
  os.exit(1, true)
end

-- disconnect: Programm läuft weiter, außer terminateDebuggee = true oder
-- (bei launch) nicht ausdrücklich false.
function handlers.disconnect(req)
  local args = req.arguments or {}
  local kill = args.terminateDebuggee == true or (S.launched and args.terminateDebuggee ~= false)
  S.ch:respond(req, json.object())
  if kill then terminate_program() end
  drop_client()
end

function handlers.terminate(req)
  S.ch:respond(req, json.object())
  terminate_program()
end

-- Programmende (aus ljdap.errors.run_script): Client informieren.
local function on_exit(code)
  if S.ch then
    S.ch:event("exited", { exitCode = code })
    S.ch:event("terminated", json.object())
    S.ch:close()
  end
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
errors.on_exit = on_exit

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
