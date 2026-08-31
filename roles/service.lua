--[[ roles/service.lua -- "computer B", a generic processing service.

The crushing service is just this role with crushing recipes in its config;
an enriching or smelting service is the same code with different recipes.
The machines themselves are passive: raw goods land in the input chest
(pushed there by the sender over the shared wired network), flow through
the factory via your local plumbing, and end up in the output chest, where
the router's matcher spots them and dispatches delivery moves.

The computer's job is bookkeeping: translate "crush my iron ingots" into a
claim for iron dust and register that claim -- with the physical chest
addresses baked in -- at the router.
]]

local class = require("lib.class")
local util = require("lib.util")
local Node = require("lib.net")
local InventoryClient = require("lib.clients.inventory")
local MachineClient = require("lib.clients.machine")

local Service = class()

function Service:init(config, log)
  assert(type(config.name) == "string", "service config needs a unique 'name'")
  assert(type(config.devices) == "table", "service config needs a 'devices' table")
  assert(type(config.recipes) == "table", "service config needs a 'recipes' table")
  assert(type(config.devices.input_chest) == "string", "service config needs devices.input_chest")
  assert(type(config.devices.output_chest) == "string", "service config needs devices.output_chest")
  self.config = config
  self.log = log
  self.router = config.router_host or "router"
  self.node = Node.new({
    protocol = config.protocol,
    hostname = config.name,
    modem = config.modem,
    log = log,
  })
  self.handled = 0
end

function Service:setup()
  local d = self.config.devices
  -- Wrapped purely to validate the wiring at boot; the actual item moves
  -- are done by senders and workers from across the network.
  self.input_chest = InventoryClient.new(d.input_chest)
  self.output_chest = InventoryClient.new(d.output_chest)
  if d.machine then
    self.machine = MachineClient.new(d.machine)
  end

  self.node:open()
  self.node:handle("service.request", function(body, ctx) return self:_on_request(body, ctx) end)
  self.node:handle("sys.status", function() return self:_status() end)
end

function Service:_on_request(body, ctx)
  if type(body.id) ~= "string" or type(body.item) ~= "string" then
    error({ code = "bad_request", message = "need id and item" })
  end
  if type(body.inbox_chest) ~= "string" then
    error({ code = "bad_request", message = "need inbox_chest (where should the goods go back to?)" })
  end
  local recipe = self.config.recipes[body.item]
  if not recipe then
    error({ code = "no_recipe", message = "no recipe for " .. body.item })
  end
  local amount = math.floor(tonumber(body.amount) or 0)
  if amount <= 0 then
    error({ code = "bad_request", message = "amount must be positive" })
  end

  -- The claim reuses the sender's request id, which makes the whole chain
  -- idempotent: a retried request maps to the same claim at the router.
  -- Chest addresses are snapshotted here, at creation, so even a claim
  -- whose shipped-notice is lost stays deliverable.
  local fields = {
    id = body.id,
    sender_id = ctx.from,
    service = self.config.name,
    input_item = body.item,
    input_amount = amount,
    item = recipe.output,
    amount = math.floor(amount * (recipe.ratio or 1)),
    ratio = recipe.ratio or 1,
    service_input_chest = self.config.devices.input_chest,
    service_output_chest = self.config.devices.output_chest,
    inbox_chest = body.inbox_chest,
  }

  local ok, res, err = self.node:request(self.router, "claim.create", { claim = fields })
  if not ok then
    error({
      code = "router_unavailable",
      message = "claim.create failed: " .. (err and (err.message or err.code) or "?"),
    })
  end

  self.handled = self.handled + 1
  self.log:info("claim %s: accepted %d x %s from #%d -> %d x %s",
    util.short_id(body.id), amount, body.item, ctx.from, fields.amount, fields.item)

  return {
    accepted = true,
    claim = res.claim,
    input_chest = self.config.devices.input_chest,
  }
end

function Service:_status()
  local recipes = {}
  for input, recipe in pairs(self.config.recipes) do
    recipes[input] = recipe.output
  end
  local status = {
    role = "service",
    name = self.config.name,
    id = os.getComputerID(),
    requests_handled = self.handled,
    recipes = recipes,
    input_chest = self.config.devices.input_chest,
    output_chest = self.config.devices.output_chest,
    output = self.output_chest:counts(),
  }
  if self.machine then status.machine = self.machine:status() end
  return status
end

function Service:tasks()
  return self.node:tasks()
end

return Service
