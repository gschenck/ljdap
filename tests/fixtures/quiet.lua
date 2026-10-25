-- Szenario-Fixture für den stdio-Transport: schreibt nichts auf stdout.
local s = 0
for i = 1, 1000 do s = s + i end
io.stderr:write("quiet: ", s, "\n")
