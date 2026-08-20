--[[ lib/clients/multi_inventory.lua -- several inventories presented as one
logical buffer.

Counting sums across members; push_item drains members in configured order
until the requested amount is satisfied. This is a read/source view only: it
cannot be a pushItems DESTINATION, because that must be a single peripheral
name. Every member must share a wired network with the inventories it
pushes into.
]]

local class = require("lib.class")
local InventoryClient = require("lib.clients.inventory")

local MultiInventoryClient = class()

function MultiInventoryClient:init(device_names)
  assert(type(device_names) == "table" and #device_names > 0,
    "multi inventory needs a non-empty list of device names")
  self.members = {}
  for i, name in ipairs(device_names) do
    self.members[i] = InventoryClient.new(name)
  end
end

function MultiInventoryClient:get_name()
  local names = {}
  for i, m in ipairs(self.members) do names[i] = m:get_name() end
  return table.concat(names, "+")
end

function MultiInventoryClient:size()
  local total = 0
  for _, m in ipairs(self.members) do total = total + m:size() end
  return total
end

--- Map of item name -> total count across every member.
function MultiInventoryClient:counts()
  local totals = {}
  for _, m in ipairs(self.members) do
    for item, n in pairs(m:counts()) do
      totals[item] = (totals[item] or 0) + n
    end
  end
  return totals
end

function MultiInventoryClient:count(item)
  return self:counts()[item] or 0
end

--- Move up to `amount` of `item` into `destination`, spilling across
--- members in order. Returns the total actually moved.
function MultiInventoryClient:push_item(destination, item, amount)
  local moved = 0
  for _, m in ipairs(self.members) do
    if moved >= amount then break end
    moved = moved + m:push_item(destination, item, amount - moved)
  end
  return moved
end

--- Config convenience: accept a single device name or a list of them and
--- return the matching client. Both share the same read/push interface.
function MultiInventoryClient.wrap(spec)
  if type(spec) == "table" then
    return MultiInventoryClient.new(spec)
  end
  return InventoryClient.new(spec)
end

return MultiInventoryClient
