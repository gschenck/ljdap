-- Szenario-Fixture: programmatischer Haltepunkt.
local dbg = require("ljdap")

local function arbeite(wert)
  local doppelt = wert * 2
  local angehalten = dbg.breakhere()          -- 6
  io.stdout:write("breakhere: ", tostring(angehalten), " ", doppelt, "\n")
  return doppelt
end

arbeite(21)
io.stdout:flush()
