-- Szenario-Fixture: Pause und setVariable. Läuft, bis `laufen` falsch wird
-- (oder nach 20 s Sicherheitsgrenze).
local laufen = true
local n = 0
local grenze = os.time() + 20
while laufen and os.time() < grenze do
  n = n + 1                            -- 7
end
io.stdout:write("schleife: ", tostring(laufen), " ", tostring(n > 0), "\n")
io.stdout:flush()
