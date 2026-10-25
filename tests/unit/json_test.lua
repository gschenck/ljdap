local T = dofile("tests/unit/t.lua")
local json = require("ljdap.json")
local eq, check, case = T.eq, T.check, T.case

case("Skalare", function()
  eq(json.encode(nil), "null")
  eq(json.encode(true), "true")
  eq(json.encode(false), "false")
  eq(json.encode(json.null), "null")
  eq(json.encode(0), "0")
  eq(json.encode(-17), "-17")
  eq(json.encode(4711), "4711")
  eq(json.encode(2 ^ 40), "1099511627776")
  eq(json.encode(2 ^ 53 - 1), "9007199254740991")
  eq(json.encode(0.5), "0.5")
  eq(tonumber(json.encode(-1.25e-7)), -1.25e-7)
  eq(json.encode(0 / 0), "null")
  eq(json.encode(math.huge), "null")
  eq(json.encode(-math.huge), "null")
end)

case("Strings", function()
  eq(json.encode("abc"), '"abc"')
  eq(json.encode('a"b\\c'), '"a\\"b\\\\c"')
  eq(json.encode("z\n\r\t\b\f"), '"z\\n\\r\\t\\b\\f"')
  eq(json.encode("\0\1\31\127"), '"\\u0000\\u0001\\u001f\\u007f"')
  eq(json.encode("Größe äöü €"), '"Größe äöü €"')
  eq(json.encode("😀"), '"😀"')
  -- ungültiges UTF-8 -> U+FFFD
  eq(json.encode("a\255b"), '"a\239\191\189b"')
  eq(json.encode("\195"), '"\239\191\189"', "abgeschnittene Folge")
  eq(json.encode("\192\128"), '"\239\191\189\239\191\189"', "überlange Kodierung")
  eq(json.encode("\237\160\128"), '"\239\191\189\239\191\189\239\191\189"', "Surrogat")
  eq(json.encode("\244\144\128\128"):sub(1, 4), '"\239\191\189', "> U+10FFFF")
end)

case("Tabellen", function()
  eq(json.encode({}), "{}")
  eq(json.encode(json.array()), "[]")
  eq(json.encode({ 1, 2, 3 }), "[1,2,3]")
  eq(json.encode({ 1, nil, 3 }), "[1,null,3]")
  eq(json.encode({ a = 1 }), '{"a":1}')
  eq(json.encode({ { x = json.array() } }), '[{"x":[]}]')
  eq(json.encode(json.object({ 1, 2 })), '{"1":1,"2":2}')
  local ok = pcall(json.encode, { 1, 2, x = 3 })
  check(ok, "gemischte Tabelle wird Objekt")
  ok = pcall(json.encode, json.array({ 1, x = 1 }))
  check(not ok, "markiertes Array mit Fremdschlüssel wirft")
  local t = {}; t.self = t
  ok = pcall(json.encode, t)
  check(not ok, "Zyklus wirft")
  ok = pcall(json.encode, { f = print })
  check(not ok, "Funktion wirft")
  ok = pcall(json.encode, { [1] = 1, [1000] = 2 })
  check(not ok, "dünn besetzte Tabelle wirft")
  -- dieselbe Tabelle zweimal (kein Zyklus) ist erlaubt
  local shared = { 1 }
  eq(json.encode({ shared, shared }), "[[1],[1]]")
end)

case("Dekodieren Grundformen", function()
  eq(json.decode("true"), true)
  eq(json.decode(" false "), false)
  eq(json.decode("null"), json.null)
  eq(json.decode("0"), 0)
  eq(json.decode("-12.5e2"), -1250)
  eq(json.decode("1E3"), 1000)
  eq(json.decode('"x\\u00e4\\n"'), "xä\n")
  eq(json.decode('"\\ud83d\\ude00"'), "😀")
  eq(json.decode('"\\ud83d"'), "\239\191\189", "einsames hohes Surrogat")
  eq(json.decode('"\\udc00x"'), "\239\191\189x", "einsames tiefes Surrogat")
  eq(json.decode('"a\\/b"'), "a/b")
  eq(json.decode('[1,[2,{"a":[]}]]'), { 1, { 2, { a = {} } } })
  eq(json.decode('{"a":1,"b":"c"}'), { a = 1, b = "c" })
end)

case("null-Behandlung", function()
  local t = json.decode('{"condition":null,"line":5}')
  eq(t.condition, nil, "null im Objekt entfällt")
  eq(t.line, 5)
  t = json.decode('{"condition":null}', { keep_null = true })
  eq(t.condition, json.null, "keep_null")
  t = json.decode("[1,null,3]")
  eq(#t, 3)
  eq(t[2], json.null, "null im Array bleibt Platzhalter")
  eq(json.encode(t), "[1,null,3]", "Rundlauf")
end)

case("leere Arrays bleiben Arrays", function()
  eq(json.encode(json.decode("[]")), "[]")
  eq(json.encode(json.decode('{"a":[]}')), '{"a":[]}')
  eq(json.encode(json.decode("{}")), "{}")
end)

case("Fehler", function()
  local bad = { "", "{", "[1,", '{"a"}', '{"a":}', "[1 2]", "tru", "01x", '"abc',
    '"a\\x"', '"a\\u12"', '"a\tb"', "1 2", "{a:1}", "-", "[,]" }
  for _, s in ipairs(bad) do
    local v, err = json.decode(s)
    check(v == nil and type(err) == "string", "muss fehlschlagen: " .. s)
  end
  local v, err = json.decode(nil)
  check(v == nil and err:find("Text erwartet"), "nil")
  v, err = json.decode(string.rep("[", 300) .. string.rep("]", 300))
  check(v == nil and err:find("zu tief"), "Schachtelungsgrenze")
end)

case("Rundlauf DAP-Nachricht", function()
  local msg = {
    seq = 7, type = "response", request_seq = 3, success = true, command = "initialize",
    body = { supportsConfigurationDoneRequest = true,
             exceptionBreakpointFilters = json.array() },
  }
  local back = json.decode(json.encode(msg))
  eq(back, { seq = 7, type = "response", request_seq = 3, success = true,
             command = "initialize",
             body = { supportsConfigurationDoneRequest = true, exceptionBreakpointFilters = {} } })
end)

case("Zahlen-Rundlauf", function()
  for _, x in ipairs{ 0.1, 1 / 3, 123456.789, -2 ^ 52, 1e300, 5e-324, 2 ^ 53 + 2 } do
    eq(json.decode(json.encode(x)), x, "Rundlauf " .. tostring(x))
  end
end)

case("Locale mit Dezimalkomma", function()
  local old = os.setlocale(nil, "numeric")
  local set = os.setlocale("de_DE.UTF-8", "numeric") or os.setlocale("de_DE.utf8", "numeric")
    or os.setlocale("German_Germany.1252", "numeric")
  if not set then
    io.stderr:write("  (übersprungen: keine deutsche Locale)\n")
    return
  end
  local ok, err = pcall(function()
    eq(json.encode(0.5), "0.5", "Kodieren unter " .. set)
    eq(json.encode({ x = -2.25 }), '{"x":-2.25}')
    eq(json.decode("1.5"), 1.5, "Dekodieren unter " .. set)
    eq(json.decode("[2.5e1]")[1], 25)
  end)
  os.setlocale(old, "numeric")
  if not ok then error(err, 0) end
end)

T.finish()
