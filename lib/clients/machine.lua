--[[ lib/clients/machine.lua -- thin client for a Mekanism machine (crusher,
enrichment chamber, factory, ...). The network moves items around the machine
rather than through its API, so this client is for observability: energy and
activity readouts in sys.status / heartbeat logs. Every accessor is
pcall-guarded because method names vary a little between Mekanism versions. ]]

local class = require("lib.class")
local util = require("lib.util")

local MachineClient = class()

function MachineClient:init(device_name)
  self.device_name = device_name
  self.device = util.require_peripheral(device_name, "mekanism machine")
end

function MachineClient:get_name()
  return self.device_name
end

--- Call an arbitrary peripheral method safely: returns value or nil.
function MachineClient:call(method, ...)
  local fn = self.device[method]
  if type(fn) ~= "function" then return nil end
  local ok, result = pcall(fn, ...)
  if ok then return result end
  return nil
end

--- Energy buffer fill as 0..1, or nil if the machine doesn't report it.
function MachineClient:energy_pct()
  return self:call("getEnergyFilledPercentage")
end

--- Rough "is it doing something" signal, nil if unavailable.
function MachineClient:status()
  return {
    name = self.device_name,
    energy_pct = self:energy_pct(),
    redstone_mode = self:call("getRedstoneMode"),
  }
end

return MachineClient
