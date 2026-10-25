-- Messprogramm: Funktionsaufrufe, Schleifen, Tabellen. Gibt CPU-Zeit aus.
local function f(x) return x * 2 + 1 end      -- 2
local t0 = os.clock()
local acc, tab = 0, {}
for i = 1, 3000000 do
  acc = acc + f(i) % 7
  if i % 1000 == 0 then tab[#tab + 1] = acc end
end
io.stdout:write(string.format("bench: %.3f s (%d)\n", os.clock() - t0, #tab))
io.stdout:flush()
