--[[ roles/service.lua -- "computer B", a generic processing service.

The crushing service is just this role with crushing recipes in its config;
an enriching or smelting service is the same code with different recipes.
Raw goods land in the input chest (pushed there by the sender), flow
through the factory via your local plumbing, and end up in the output
chest.

Under the ownership model this computer is also the delivery arm for its
own output chest: the router commands `deliver.exec` and the SERVICE
pushes the goods into the ordering sender's inbox -- nothing on the
network ever pulls from a chest it doesn't own. Job results persist by
job id so retries replay instead of double-moving, and `job.result` lets
the router reconcile unknown outcomes (including "interrupted": we
rebooted after marking a job running but before recording its result).
]]

local class = require("lib.class")
local util = require("lib.util")
local Node = require("lib.net")
local JsonStore = require("lib.store")
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
  self.results = JsonStore.new(config.data_dir or "/data/service")
  self.handled = 0
  self.delivered = 0
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
  self.node:handle("deliver.exec", function(body, ctx) return self:_on_deliver(body, ctx) end)
  self.node:handle("job.result", function(body) return self:_on_job_result(body) end)
  self.node:handle("sys.status", function() return self:_status() end)
end

--- Execute one delivery: push goods from OUR output chest into the given
--- inbox. The body carries no authority over the source -- ownership means
--- this computer only ever moves items out of its own chests.
function Service:_on_deliver(body, ctx)
  -- Replay first: a duplicate job id must never move items twice.
  local done = self.results:get(ctx.id)
  if done and done.status == "done" then
    return { moved = done.moved, replayed = true }
  end

  if type(body.to) ~= "string" or type(body.item) ~= "string" then
    error({ code = "bad_request", message = "need to and item" })
  end
  local amount = math.floor(tonumber(body.amount) or 0)
  if amount <= 0 then
    error({ code = "bad_request", message = "amount must be positive" })
  end
  if not peripheral.isPresent(body.to) then
    error({ code = "chest_missing", message = body.to .. " is not on this network" })
  end

  -- Mark the job running before touching items: if we reboot mid-push,
  -- job.result answers "interrupted" and the router warns loudly instead
  -- of silently re-dispatching a move that may have happened.
  self.results:put(ctx.id, { status = "running", at = util.now_ms() })
  local moved = self.output_chest:push_item(body.to, body.item, amount)
  self.results:put(ctx.id, { status = "done", moved = moved, at = util.now_ms() })

  self.delivered = self.delivered + moved
  self.log:info("job %s: delivered %d x %s -> %s", tostring(ctx.id), moved, body.item, body.to)
  return { moved = moved }
end

function Service:_on_job_result(body)
  local done = self.results:get(tostring(body.job_id or ""))
  if not done then
    error({ code = "not_found", message = "no result for that job" })
  end
  -- A "running" record can only be observed after a reboot: job.result
  -- queues behind the job itself on this node's serial handler loop, so a
  -- still-executing job would have finished before we answered.
  if done.status ~= "done" then
    error({ code = "interrupted", message = "job was interrupted mid-move" })
  end
  return { moved = done.moved, at = done.at }
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

  -- Fewer retries than default: this runs on the serial handler loop, and
  -- a long stall here delays queued deliver.exec jobs behind it.
  local ok, res, err = self.node:request(self.router, "claim.create",
    { claim = fields }, { retries = 2 })
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
    items_delivered = self.delivered,
    recipes = recipes,
    input_chest = self.config.devices.input_chest,
    output_chest = self.config.devices.output_chest,
    output = self.output_chest:counts(),
  }
  if self.machine then status.machine = self.machine:status() end
  return status
end

function Service:tasks()
  local tasks = self.node:tasks()
  -- Job results only matter while the router might still ask about them.
  tasks[#tasks + 1] = function()
    while true do
      sleep(300)
      local ok, err = pcall(function()
        local cutoff = util.now_ms() - (self.config.result_retention_s or 3600) * 1000
        for _, id in ipairs(self.results:ids()) do
          local r = self.results:get(id)
          if not r or (r.at or 0) < cutoff then self.results:delete(id) end
        end
      end)
      if not ok then self.log:error("result pruning failed: %s", tostring(err)) end
    end
  end
  return tasks
end

return Service
