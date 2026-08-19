--[[ roles/service.lua — "computer B", a generic processing service.

The crushing service is just this role with crushing recipes in its config;
an enriching or smelting service is the same code with different recipes and
frequencies. The machines themselves are passive: items teleport in on the
input porter, flow through the factory via your pipes, and teleport out on
the output porter toward the router's intake.

The computer's job is bookkeeping: translate "crush my iron ingots" into a
claim for iron dust and register that claim with the router.
]]

local class = require("lib.class")
local util = require("lib.util")
local Node = require("lib.net")
local EntangloporterClient = require("lib.clients.entangloporter")
local MachineClient = require("lib.clients.machine")

local Service = class()

function Service:init(config, log)
  assert(type(config.name) == "string", "service config needs a unique 'name'")
  assert(type(config.devices) == "table", "service config needs a 'devices' table")
  assert(type(config.recipes) == "table", "service config needs a 'recipes' table")
  assert(type(config.input_frequency) == "string", "service config needs 'input_frequency'")
  assert(type(config.output_frequency) == "string", "service config needs 'output_frequency'")
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
  self.input_porter = EntangloporterClient.new(d.input_porter)
  self.output_porter = EntangloporterClient.new(d.output_porter)
  if d.machine then
    self.machine = MachineClient.new(d.machine)
  end

  self.input_porter:ensure_frequency(self.config.input_frequency)
  self.output_porter:ensure_frequency(self.config.output_frequency)

  self.node:open()
  self.node:handle("service.request", function(body, ctx) return self:_on_request(body, ctx) end)
  self.node:handle("sys.status", function() return self:_status() end)
end

function Service:_on_request(body, ctx)
  if type(body.id) ~= "string" or type(body.item) ~= "string" then
    error({ code = "bad_request", message = "need id and item" })
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
  local fields = {
    id = body.id,
    sender_id = ctx.from,
    service = self.config.name,
    input_item = body.item,
    input_amount = amount,
    item = recipe.output,
    amount = math.floor(amount * (recipe.ratio or 1)),
    ratio = recipe.ratio or 1,
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
    input_frequency = self.config.input_frequency,
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
    input_frequency = self.config.input_frequency,
  }
  if self.machine then status.machine = self.machine:status() end
  return status
end

--- Periodically re-assert porter frequencies so a stray GUI click can't
--- silently detach this service from the network.
function Service:_heal_tick()
  self.input_porter:ensure_frequency(self.config.input_frequency)
  self.output_porter:ensure_frequency(self.config.output_frequency)
end

function Service:tasks()
  local tasks = self.node:tasks()
  tasks[#tasks + 1] = function()
    while true do
      local ok, err = pcall(function() self:_heal_tick() end)
      if not ok then self.log:error("frequency heal failed: %s", tostring(err)) end
      sleep(60)
    end
  end
  return tasks
end

return Service
