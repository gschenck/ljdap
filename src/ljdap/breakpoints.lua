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
