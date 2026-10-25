-- Kleines Testgerüst für tests/unit/*_test.lua (ohne Abhängigkeiten).
-- Setzt package.path auf src/ und bietet check/eq/run.

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local T = { failures = 0, count = 0 }

local function show(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

local function deep_eq(a, b, seen)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  seen = seen or {}
  if seen[a] == b then return true end
  seen[a] = b
  for k, v in pairs(a) do
    if not deep_eq(v, b[k], seen) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end
T.deep_eq = deep_eq

function T.check(cond, msg)
  T.count = T.count + 1
  if not cond then
    T.failures = T.failures + 1
    local info = debug.getinfo(2, "Sl")
    io.stderr:write(string.format("  FEHLER %s:%d: %s\n", info.short_src, info.currentline, msg or "Bedingung falsch"))
  end
  return cond
end

function T.eq(got, want, msg)
  T.count = T.count + 1
  if not deep_eq(got, want) then
    T.failures = T.failures + 1
    local info = debug.getinfo(2, "Sl")
    io.stderr:write(string.format("  FEHLER %s:%d: %s\n    erhalten: %s\n    erwartet: %s\n",
      info.short_src, info.currentline, msg or "ungleich", show(got), show(want)))
  end
end

--- Führt fn aus; Ausnahmen zählen als Fehler.
function T.case(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    T.failures = T.failures + 1
    io.stderr:write("  AUSNAHME in ", name, ": ", tostring(err), "\n")
  end
end

function T.finish()
  if T.failures > 0 then
    io.stderr:write(string.format("  %d von %d Prüfungen fehlgeschlagen\n", T.failures, T.count))
  end
  os.exit(T.failures == 0 and 0 or 1)
end

return T
