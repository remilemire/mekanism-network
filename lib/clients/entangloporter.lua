--[[ lib/clients/entangloporter.lua — client for Mekanism's quantum
entangloporter peripheral. Frequencies are how items teleport between sites,
so ensure_frequency() is the workhorse: idempotent, creates on demand, and
verifies the switch actually took. ]]

local class = require("lib.class")
local util = require("lib.util")

local EntangloporterClient = class()

function EntangloporterClient:init(device_name)
  self.device_name = device_name
  self.device = util.require_peripheral(device_name, "quantum entangloporter")
end

function EntangloporterClient:get_name()
  return self.device_name
end

--- Current frequency name, or nil if none is selected.
--- (Some Mekanism builds return a table instead of a plain name; normalize.)
function EntangloporterClient:get_frequency()
  local ok, freq = pcall(self.device.getFrequency)
  if not ok or freq == nil then return nil end
  if type(freq) == "table" then return freq.key or freq.name end
  return freq
end

function EntangloporterClient:has_frequency(name)
  local ok, has = pcall(self.device.hasFrequency, name)
  return ok and has or false
end

function EntangloporterClient:create_frequency(name)
  return self.device.createFrequency(name)
end

function EntangloporterClient:set_frequency(name)
  return self.device.setFrequency(name)
end

--- Make sure this porter sits on `name`, creating the frequency if needed.
--- Safe to call repeatedly; errors loudly if the switch does not stick.
function EntangloporterClient:ensure_frequency(name)
  if self:get_frequency() == name then return end
  if not self:has_frequency(name) then
    -- Another computer may create it concurrently; that race is harmless.
    pcall(self.device.createFrequency, name)
  end
  self.device.setFrequency(name)
  local now = self:get_frequency()
  if now ~= name then
    error(("%s refused frequency %q (stuck on %q)")
      :format(self.device_name, name, tostring(now)), 0)
  end
end

return EntangloporterClient
