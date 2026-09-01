--[[ roles/service.lua -- a self-contained processing service.

The crushing service is just this role with crushing recipes in its config;
an enrichment or infusing service is the same code with a different config.

Since v4 there is no router: each service IS the broker for its own claims.
It accepts orders, keeps the persisted claim ledger, matches claims against
its own output chest (FIFO with per-item reservations -- cross-sender
fairness lives here, since all competition for this service's goods happens
in this one queue), delivers by pushing from its own output chest into the
ordering sender's inbox (ownership model: nothing on the network ever pulls
from a chest it doesn't own), and notifies the sender.

Delivery needs no job protocol any more -- the broker and the mover are the
same computer. The only unknown-outcome window is a reboot mid-push, which
a persisted `deliver_unresolved` flag surfaces at boot with a loud warning
before the remainder is re-pushed.
]]

local class = require("lib.class")
local util = require("lib.util")
local Node = require("lib.net")
local claims = require("lib.claims")
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
  self.node = Node.new({
    protocol = config.protocol,
    hostname = config.name,
    modem = config.modem,
    log = log,
  })
  self.handled = 0
  self.delivered = 0
end

function Service:setup()
  local d = self.config.devices
  self.input_chest = InventoryClient.new(d.input_chest)
  self.output_chest = InventoryClient.new(d.output_chest)
  if d.machine then
    self.machine = MachineClient.new(d.machine)
  end

  self.ledger = claims.ClaimLedger.new(self.config.data_dir or "/data/claims", self.log)

  -- Boot recovery: a claim flagged unresolved was mid-push when we died.
  -- The push may or may not have happened -- the one honest double-move
  -- window in this design. Warn loudly and let the deliver loop re-push
  -- the recorded remainder.
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.DELIVERING)) do
    if c.deliver_unresolved then
      self.log:warn("claim %s: delivery was interrupted mid-push before reboot -- re-pushing the remainder (small double-move risk)",
        util.short_id(c.id))
      c.deliver_unresolved = nil
      self.ledger:save(c)
    end
  end

  self.node:open()
  self.node:handle("service.request", function(body, ctx) return self:_on_request(body, ctx) end)
  self.node:handle("claim.shipped", function(body) return self:_on_claim_shipped(body) end)
  self.node:handle("claim.abort", function(body) return self:_on_claim_abort(body) end)
  self.node:handle("claim.get", function(body) return self:_on_claim_get(body) end)
  self.node:handle("claim.list", function(body) return self:_on_claim_list(body) end)
  self.node:handle("sys.status", function() return self:_status() end)
end

-- RPC handlers -----------------------------------------------------------------

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

  -- Idempotent: the claim id is the sender's request id, so a retried
  -- order replays the stored claim instead of double-booking.
  local existing = self.ledger:get(body.id)
  if existing then
    return { accepted = true, claim = existing, input_chest = self.config.devices.input_chest }
  end

  local ok, claim = pcall(claims.new, {
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
  })
  if not ok then
    error({ code = "bad_request", message = tostring(claim) })
  end

  self.ledger:save(claim)
  self.handled = self.handled + 1
  self.log:info("claim %s: accepted %d x %s from #%d -> %d x %s",
    util.short_id(claim.id), amount, body.item, ctx.from, claim.amount, claim.item)

  return { accepted = true, claim = claim, input_chest = self.config.devices.input_chest }
end

function Service:_find_or_die(claim_id)
  local c, ambiguous = self.ledger:find(tostring(claim_id or ""))
  if ambiguous then
    error({ code = "ambiguous", message = "multiple claims match that prefix" })
  end
  if not c then
    error({ code = "not_found", message = "no claim " .. tostring(claim_id) })
  end
  return c
end

function Service:_on_claim_shipped(body)
  local c = self:_find_or_die(body.claim_id)
  if c.status == claims.STATUS.CREATED then
    local shipped = math.floor(tonumber(body.amount) or c.input_amount)
    if shipped > 0 and shipped ~= c.input_amount then
      c.input_amount = shipped
      c.amount = math.floor(shipped * (c.ratio or 1))
      self.log:info("claim %s: scaled to %d x %s (partial shipment)",
        util.short_id(c.id), c.amount, c.item)
    end
    self.ledger:transition(c, claims.STATUS.IN_TRANSIT)
  end
  return { claim = c }
end

function Service:_on_claim_abort(body)
  local c = self:_find_or_die(body.claim_id)
  if c.status == claims.STATUS.FAILED then return { claim = c } end
  if claims.TERMINAL[c.status] then
    error({ code = "too_late", message = "claim is already " .. c.status })
  end
  if c.status == claims.STATUS.ARRIVED or c.status == claims.STATUS.DELIVERING then
    self.log:warn("claim %s: aborted while %s -- its goods become stock for future claims",
      util.short_id(c.id), c.status)
  end
  c.abort_reason = body.reason
  self.ledger:transition(c, claims.STATUS.FAILED)
  self.log:info("claim %s: aborted (%s)", util.short_id(c.id), tostring(body.reason))
  return { claim = c }
end

function Service:_on_claim_get(body)
  return { claim = self:_find_or_die(body.claim_id) }
end

function Service:_on_claim_list(body)
  local list
  if body.status then
    list = self.ledger:by_status(body.status)
  else
    list = {}
    for _, c in pairs(self.ledger:all()) do list[#list + 1] = c end
    table.sort(list, function(a, b) return a.created_at > b.created_at end)
  end
  local rows = {}
  for i = 1, math.min(#list, body.limit or 50) do
    local c = list[i]
    rows[#rows + 1] = {
      id = c.id, status = c.status, item = c.item, amount = c.amount,
      sender_id = c.sender_id, created_at = c.created_at,
      dispatched = c.dispatched, received = c.received, service = c.service,
    }
  end
  return { claims = rows, now = util.now_ms() }
end

-- Matching ---------------------------------------------------------------------

function Service:_match_tick()
  local ok, counts = pcall(function() return self.output_chest:counts() end)
  if not ok then
    if util.now_ms() - (self.chest_nag_at or 0) > 30000 then
      self.chest_nag_at = util.now_ms()
      self.log:warn("cannot read the output chest (%s); matching is on hold", tostring(counts))
    end
    return
  end

  -- Goods earmarked by claims further along must not count for new ones.
  local reserved = {}
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.ARRIVED, claims.STATUS.DELIVERING)) do
    local remaining = (c.amount or 0) - (c.dispatched or 0)
    if remaining > 0 then
      reserved[c.item] = (reserved[c.item] or 0) + remaining
    end
  end

  -- FIFO over open claims, oldest first (by_status sorts by created_at):
  -- this is where cross-sender fairness is enforced.
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.CREATED, claims.STATUS.IN_TRANSIT)) do
    local avail = (counts[c.item] or 0) - (reserved[c.item] or 0)
    if avail >= c.amount then
      self.ledger:transition(c, claims.STATUS.ARRIVED)
      reserved[c.item] = (reserved[c.item] or 0) + c.amount
      self.log:info("claim %s: %d x %s ready for #%d",
        util.short_id(c.id), c.amount, c.item, c.sender_id)
    end
  end
end

-- Delivery ---------------------------------------------------------------------

function Service:_deliver_tick()
  local now = util.now_ms()
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.ARRIVED, claims.STATUS.DELIVERING)) do
    if (c.next_attempt_at or 0) <= now then
      self:_deliver(c)
      return -- one delivery per tick keeps the logs legible
    end
  end
end

function Service:_deliver(c)
  local dst = c.inbox_chest
  if type(dst) ~= "string" then
    self.log:warn("claim %s: missing inbox address -- failing it", util.short_id(c.id))
    self.ledger:transition(c, claims.STATUS.FAILED)
    return
  end
  local remaining = (c.amount or 0) - (c.dispatched or 0)
  if remaining <= 0 then
    self:_complete(c)
    return
  end
  if not peripheral.isPresent(dst) then
    if util.now_ms() - (c.last_nag or 0) > 30000 then
      c.last_nag = util.now_ms()
      self.log:warn("claim %s: inbox %s is not on the network; delivery on hold",
        util.short_id(c.id), dst)
    end
    c.next_attempt_at = util.now_ms() + 10 * 1000
    self.ledger:save(c)
    return
  end

  -- Persist the unresolved flag BEFORE pushing so a reboot mid-push is
  -- detected at boot instead of silently double-moving.
  c.deliver_unresolved = true
  if c.status == claims.STATUS.ARRIVED then
    self.ledger:transition(c, claims.STATUS.DELIVERING)
  else
    self.ledger:save(c)
  end

  local moved = 0
  local ok, err = pcall(function()
    moved = self.output_chest:push_item(dst, c.item, remaining)
  end)
  c.deliver_unresolved = nil
  if not ok then
    c.next_attempt_at = util.now_ms() + 10 * 1000
    self.ledger:save(c)
    self.log:warn("claim %s: delivery push failed (%s); will retry",
      util.short_id(c.id), tostring(err))
    return
  end

  c.dispatched = (c.dispatched or 0) + moved
  self.delivered = self.delivered + moved
  if c.dispatched >= (c.amount or 0) then
    self:_complete(c)
  else
    -- Partial: the inbox chest was full. Retry the remainder shortly.
    c.next_attempt_at = util.now_ms() + (moved > 0 and 5 or 10) * 1000
    self.ledger:save(c)
    self.log:info("claim %s: partial delivery %d/%d; will push the remainder",
      util.short_id(c.id), c.dispatched, c.amount)
  end
end

function Service:_complete(c)
  if c.status == claims.STATUS.ARRIVED then
    self.ledger:transition(c, claims.STATUS.DELIVERING)
  end
  if c.status ~= claims.STATUS.DELIVERING then
    return -- aborted out from under us; leave it be
  end
  c.received = c.dispatched or 0
  self.ledger:transition(c, claims.STATUS.COMPLETED)
  self.log:info("claim %s: delivered %d x %s to #%d",
    util.short_id(c.id), c.dispatched or 0, c.item, c.sender_id)
  -- Advisory nudge; the sender's janitor reconciliation is the guarantee.
  self.node:request(c.sender_id, "delivery.landed", {
    claim_id = c.id, moved = c.dispatched,
  }, { retries = 1, timeout_s = 3 })
end

-- Janitor ----------------------------------------------------------------------

function Service:_janitor_tick()
  local now = util.now_ms()
  local ttl_ms = (self.config.claim_ttl_s or 900) * 1000
  local stuck_ms = (self.config.stuck_after_s or 300) * 1000
  local retention_ms = (self.config.retention_s or 3600) * 1000

  for _, c in ipairs(self.ledger:by_status(claims.STATUS.CREATED, claims.STATUS.IN_TRANSIT)) do
    if now - c.updated_at > ttl_ms then
      self.ledger:transition(c, claims.STATUS.EXPIRED)
      self.log:warn("claim %s: expired after %s -- its goods recycle into stock for future claims",
        util.short_id(c.id), util.fmt_age(now - c.created_at))
    end
  end

  for _, c in ipairs(self.ledger:by_status(claims.STATUS.DELIVERING)) do
    if now - c.updated_at > stuck_ms and now - (c.last_nag or 0) > 60000 then
      c.last_nag = now
      self.ledger:save(c)
      self.log:warn("claim %s: delivering for %s (%d/%d moved) -- inbox %s full or offline?",
        util.short_id(c.id), util.fmt_age(now - c.updated_at),
        c.dispatched or 0, c.amount or 0, tostring(c.inbox_chest))
    end
  end

  for _, c in ipairs(self.ledger:by_status(
    claims.STATUS.COMPLETED, claims.STATUS.FAILED, claims.STATUS.EXPIRED)) do
    if now - c.updated_at > retention_ms then
      self.ledger:archive(c.id)
    end
  end

  -- Storage hygiene, every ~10 minutes (and once right after boot).
  if now - (self.archive_pruned_at or 0) > 600 * 1000 then
    self.archive_pruned_at = now
    local pruned = self.ledger:prune_archive((self.config.archive_retention_s or 86400) * 1000)
    if pruned > 0 then
      self.log:info("pruned %d archived claims", pruned)
    end
    local free = fs.getFreeSpace("/")
    if free < 100 * 1024 then
      self.log:warn("only %dKB of disk space left -- claim persistence fails at zero",
        math.floor(free / 1024))
    end
  end
end

-- Status & tasks ---------------------------------------------------------------

function Service:_status()
  local recipes = {}
  for input, recipe in pairs(self.config.recipes) do
    recipes[input] = recipe.output
  end
  local by_status = {}
  for _, c in pairs(self.ledger:all()) do
    by_status[c.status] = (by_status[c.status] or 0) + 1
  end
  local status = {
    role = "service",
    name = self.config.name,
    id = os.getComputerID(),
    requests_handled = self.handled,
    items_delivered = self.delivered,
    recipes = recipes,
    claims = by_status,
    input_chest = self.config.devices.input_chest,
    output_chest = self.config.devices.output_chest,
    output = self.output_chest:counts(),
  }
  if self.machine then status.machine = self.machine:status() end
  return status
end

function Service:tasks()
  local tasks = self.node:tasks()
  local function loop(name, fn, interval)
    return function()
      while true do
        local ok, err = pcall(fn)
        if not ok then self.log:error("%s failed: %s", name, tostring(err)) end
        sleep(interval)
      end
    end
  end
  tasks[#tasks + 1] = loop("match tick", function() self:_match_tick() end, self.config.poll_s or 2)
  tasks[#tasks + 1] = loop("deliver tick", function() self:_deliver_tick() end, 1)
  tasks[#tasks + 1] = loop("janitor", function() self:_janitor_tick() end, 15)
  return tasks
end

return Service
