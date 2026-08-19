--[[ lib/clients/inventory.lua -- client for CC's generic inventory peripheral
(chests, barrels, and most modded inventories on a wired network). ]]

local class = require("lib.class")
local util = require("lib.util")

local InventoryClient = class()

function InventoryClient:init(device_name)
  self.device_name = device_name
  self.device = util.require_peripheral(device_name, "inventory")
end

function InventoryClient:get_name()
  return self.device_name
end

-- Raw passthroughs ----------------------------------------------------------

function InventoryClient:size()
  return self.device.size()
end

function InventoryClient:list()
  return self.device.list()
end

function InventoryClient:get_item_detail(slot)
  return self.device.getItemDetail(slot)
end

function InventoryClient:push_items(destination, from_slot, limit, to_slot)
  return self.device.pushItems(destination, from_slot, limit, to_slot)
end

function InventoryClient:pull_items(source, from_slot, limit, to_slot)
  return self.device.pullItems(source, from_slot, limit, to_slot)
end

-- Conveniences --------------------------------------------------------------

--- Map of item name -> total count across all slots.
function InventoryClient:counts()
  local totals = {}
  for _, stack in pairs(self.device.list()) do
    totals[stack.name] = (totals[stack.name] or 0) + stack.count
  end
  return totals
end

function InventoryClient:count(item)
  return self:counts()[item] or 0
end

--- Move up to `amount` of `item` into the inventory named `destination`
--- (which must share a wired network with this one). Returns items moved.
function InventoryClient:push_item(destination, item, amount)
  local moved = 0
  for slot, stack in pairs(self.device.list()) do
    if moved >= amount then break end
    if stack.name == item then
      moved = moved + (self.device.pushItems(destination, slot, amount - moved) or 0)
    end
  end
  return moved
end

return InventoryClient
