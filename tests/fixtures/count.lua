-- Szenario-Fixture: schreibt Start, rechnet eine Weile, schreibt Ende.
-- Argument 1: Laufzeit in Sekunden (Vorgabe 0 = sofort fertig).
-- Argument 2: "poll" ruft ljdap.poll() in der Schleife (Hauptschleifen-Muster).
local seconds = tonumber(arg and arg[1]) or 0
local use_poll = arg and arg[2] == "poll"
io.stdout:write("fixture: start\n")
io.stdout:flush()

local function work(n)
  local s = 0
  for i = 1, n do s = s + i % 7 end
  return s
end

local deadline = os.time() + seconds
local total = 0
repeat
  total = total + work(100000)
  if use_poll then require("ljdap").poll() end
until os.time() >= deadline

io.stdout:write("fixture: ende ", tostring(total > 0), "\n")
io.stdout:flush()
