-- Szenario-Fixture für Haltepunkte, Stepping und Variablen.
-- Zeilennummern werden in tests/scenarios/test_m2.py verwendet: nur am
-- Dateiende ergänzen, nicht dazwischen einfügen.
local Punkt = setmetatable({}, { __tostring = function(p) return "Punkt" end })
local zaehler = 0                              -- Upvalue für inc()

local function inc(n)
  zaehler = zaehler + n                        -- 8
  return zaehler                               -- 9
end

local function rechne(a, b)
  local summe = a + b                          -- 13
  local t = { 1, 2, x = "ä\1\255", [true] = 3, nested = { tief = 42 } }
  inc(1)                                       -- 15
  local r = inc(summe)                         -- 16
  -- Kommentarzeile                            -- 17

  return r * 2, t                              -- 19
end

local function varg(...)
  local n = select("#", ...)                   -- 23
  return n                                     -- 24
end

local ergebnis, tab = rechne(3, 4)             -- 27
varg("eins", 2, nil)                           -- 28
local p = setmetatable({}, getmetatable(Punkt)) -- 29
io.stdout:write("steps: ", ergebnis, " ", tostring(p), " ", tab.nested.tief, "\n") -- 30
io.stdout:flush()
