-- Szenario-Fixture: Fehler. Argument 1: "uncaught", "raised" oder "coro".
local art = arg and arg[1] or "uncaught"

local function teile(a, b)
  if b == 0 then
    error("Division durch null")       -- 6
  end
  return a / b
end

local function rechne(t)
  return t.feld.wert                   -- 12 (t.feld ist nil)
end

if art == "raised" then
  local ok, err = pcall(teile, 1, 0)   -- 16
  io.stdout:write("raised: ", tostring(ok), " ", tostring(err):match("Division durch null") or "?", "\n")
elseif art == "coro" then
  local co = coroutine.create(function() rechne({}) end)
  local ok, err = coroutine.resume(co)
  io.stdout:write("coro: ", tostring(ok), "\n")
else
  io.stdout:write("vor dem Fehler\n")
  io.stdout:flush()
  rechne({})                           -- 25
end
io.stdout:flush()
