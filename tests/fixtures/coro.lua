-- Szenario-Fixture: Coroutinen. Zeilennummern in tests/scenarios/test_m3.py.
-- Argument 1: Laufzeit in Sekunden für die Schleife am Ende (0 = keine).
local function erzeuger(start)
  local wert = start
  while wert < start + 3 do
    wert = wert + 1                    -- 6
    coroutine.yield(wert)              -- 7
  end
  return "fertig"                      -- 9
end

local co = coroutine.create(erzeuger)
local summe = 0
for _ = 1, 4 do
  local ok, v = coroutine.resume(co, 10)   -- 15
  if type(v) == "number" then summe = summe + v end
end
local gen = coroutine.wrap(function() coroutine.yield(1); coroutine.yield(2) end)
summe = summe + gen() + gen()          -- 19
local sekunden = tonumber(arg and arg[1]) or 0
local ende = os.time() + sekunden
local spaet = coroutine.create(function()
  while true do
    local x = os.time()                -- 24
    coroutine.yield(x)
  end
end)
while os.time() < ende do
  coroutine.resume(spaet)
  require("ljdap").poll()
end
io.stdout:write("coro: ", summe, "\n")
io.stdout:flush()
