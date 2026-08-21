--[[ roles/sender.lua -- "computer A".

Watches an input buffer for items that have a configured route, orders
processing from the matching service, ships the raw goods through its outbox
entangloporter, and receives finished goods on its inbox entangloporter when
the router calls with a delivery offer.

Local state:
  * a persistent ledger (one JSON per order) so reboots don't lose track
  * self.active[claim_id] = input item -- in-flight orders; up to
    batch.max_inflight claims per item type may be outstanding at once
  * self.pending -- the single delivery currently being received (the sender
    has one inbox porter, so deliveries are serialized; concurrent offers
    get a structured "busy" error and the router retries later)
]]

local class = require("lib.class")
local util = require("lib.util")
local Node = require("lib.net")
local JsonStore = require("lib.store")
local InventoryClient = require("lib.clients.inventory")
local EntangloporterClient = require("lib.clients.entangloporter")

local WAKE = "mekanet:sender_wake"

local Sender = class()

function Sender:init(config, log)
  assert(type(config.name) == "string", "sender config needs a unique 'name'")
  assert(type(config.devices) == "table", "sender config needs a 'devices' table")
  self.config = config
  self.log = log
  self.router = config.router_host or "router"
  self.idle_frequency = config.idle_frequency or ("mekanet.idle." .. os.getComputerID())
  self.node = Node.new({
    protocol = config.protocol,
    hostname = config.name,
    modem = config.modem,
    log = log,
  })
  self.ledger = JsonStore.new(config.data_dir or "/data/sender")
  -- Config routes are service -> {items}; invert to item -> service for the
  -- order loop. Errors here (duplicate items) surface before anything runs.
  self.item_routes = util.invert_routes(config.routes)
  self.active = {}
  self.pending = nil
end

function Sender:setup()
  local d = self.config.devices
  self.input_buffer = InventoryClient.new(d.input_buffer)
  self.outbox_inventory = InventoryClient.new(d.outbox_inventory)
  self.result_inventory = InventoryClient.new(d.result_inventory)
  self.outbox_porter = EntangloporterClient.new(d.outbox_porter)
  self.inbox_porter = EntangloporterClient.new(d.inbox_porter)

  self.node:open()

  -- Park the inbox on a private idle frequency so stray items on a shared
  -- delivery frequency can't leak in between deliveries.
  self.inbox_porter:ensure_frequency(self.idle_frequency)

  self.node:handle("delivery.offer", function(body) return self:_on_offer(body) end)
  self.node:handle("delivery.dispatched", function(body) return self:_on_dispatched(body) end)
  self.node:handle("sys.status", function() return self:_status() end)

  self:_resume()
end

-- Boot recovery --------------------------------------------------------------

function Sender:_resume()
  for id, entry in pairs(self.ledger:all(self.log)) do
    if entry.status == "shipped" then
      self.active[id] = entry.input_item
      self.log:warn("resuming claim %s: %s shipped before reboot, awaiting delivery",
        util.short_id(id), entry.input_item)
    elseif entry.status == "receiving" then
      -- The inbox porter keeps its frequency across reboots, so the goods
      -- almost certainly flowed into the result inventory while we were
      -- down. Confirm optimistically; the router is the source of truth and
      -- tools/claims.lua will show anything that disagrees.
      entry.status = "confirm_pending"
      entry.received = entry.received or entry.amount
      entry.updated_at = util.now_ms()
      self.ledger:put(id, entry)
      self.active[id] = entry.input_item
      self.log:warn("claim %s was mid-delivery during reboot; will confirm receipt",
        util.short_id(id))
    elseif entry.status == "confirm_pending" then
      self.active[id] = entry.input_item
    end
  end
end

-- Ordering -------------------------------------------------------------------

function Sender:_order_tick()
  local batch = self.config.batch or {}
  local max_inflight = batch.max_inflight or 4
  local inflight = {}
  for _, item in pairs(self.active) do
    inflight[item] = (inflight[item] or 0) + 1
  end
  for item, service in pairs(self.item_routes) do
    if (inflight[item] or 0) < max_inflight then
      local count = self.input_buffer:count(item)
      -- batch.min keeps items trickling in through pipes from fragmenting
      -- into many tiny claims; one order per item per tick does the rest.
      if count >= (batch.min or 1) then
        self:_place_order(item, service, math.min(count, batch.max or 64))
      end
    end
  end
end

--- Safe to retune the outbox porter to `frequency`? True when it already
--- sits there, or once the outbox chest has fully drained. Retuning with
--- leftovers inside would teleport a previous shipment to the wrong service.
function Sender:_await_outbox_ready(frequency)
  local deadline = util.now_ms() + (self.config.outbox_drain_timeout_s or 30) * 1000
  while true do
    if self.outbox_porter:get_frequency() == frequency then return true end
    local leftovers = 0
    for _, n in pairs(self.outbox_inventory:counts()) do leftovers = leftovers + n end
    if leftovers == 0 then return true end
    if util.now_ms() > deadline then return false end
    sleep(1)
  end
end

function Sender:_place_order(item, service, amount)
  local request_id = util.uuid()
  self.log:info("ordering %d x %s from %s", amount, item, service)

  local ok, body, err = self.node:request(service, "service.request", {
    id = request_id, item = item, amount = amount,
  })
  if not ok then
    self.log:warn("order for %s rejected by %s: %s",
      item, service, err and (err.message or err.code) or "?")
    return
  end
  local claim = body.claim

  -- Point our outbox at the service's intake frequency and ship -- but only
  -- once any previous shipment has finished draining out of the outbox.
  if not self:_await_outbox_ready(body.input_frequency) then
    self.log:warn("claim %s: outbox still draining toward %s -- aborting, will retry later",
      util.short_id(claim.id), tostring(self.outbox_porter:get_frequency()))
    self.node:request(self.router, "claim.abort", {
      claim_id = claim.id, reason = "outbox_blocked",
    })
    return
  end
  self.outbox_porter:ensure_frequency(body.input_frequency)
  local moved = self.input_buffer:push_item(self.outbox_inventory:get_name(), item, claim.input_amount)
  if moved == 0 then
    self.log:warn("claim %s: nothing left to ship, aborting", util.short_id(claim.id))
    self.node:request(self.router, "claim.abort", {
      claim_id = claim.id, reason = "nothing_to_ship",
    })
    return
  end

  -- Tell the router how much actually left the building so it can scale the
  -- claim. Not fatal if this is lost: the router also promotes claims when
  -- the goods physically show up at its intake.
  local ok2, _, err2 = self.node:request(self.router, "claim.shipped", {
    claim_id = claim.id, amount = moved,
  })
  if not ok2 then
    self.log:warn("claim %s: shipped notice failed (%s); router will catch up at intake",
      util.short_id(claim.id), err2 and err2.code or "?")
  end

  self.ledger:put(claim.id, {
    claim_id = claim.id,
    input_item = item,
    output_item = claim.item,
    amount = math.floor(moved * (claim.ratio or 1)),
    moved = moved,
    status = "shipped",
    updated_at = util.now_ms(),
  })
  self.active[claim.id] = item
  self.log:info("claim %s: shipped %d x %s", util.short_id(claim.id), moved, item)
end

-- Delivery handlers (called by the router) -----------------------------------

function Sender:_on_offer(body)
  if self.pending and self.pending.claim_id ~= body.claim_id then
    error({ code = "busy", message = "already receiving " .. util.short_id(self.pending.claim_id) })
  end
  if not self.pending then
    self.pending = {
      claim_id = body.claim_id,
      item = body.item,
      amount = body.amount,
      frequency = body.frequency,
      baseline = self.result_inventory:count(body.item),
      offered_at = util.now_ms(),
    }
  end
  -- Re-offers of the same claim land here too and are harmless.
  self.inbox_porter:ensure_frequency(body.frequency)

  local entry = self.ledger:get(body.claim_id)
  if entry then
    entry.status = "receiving"
    entry.updated_at = util.now_ms()
    self.ledger:put(body.claim_id, entry)
  else
    self.log:warn("offer for claim %s we have no record of -- accepting (router is the source of truth)",
      util.short_id(body.claim_id))
  end

  os.queueEvent(WAKE)
  self.log:info("claim %s: inbox tuned to %s, awaiting %d x %s",
    util.short_id(body.claim_id), body.frequency, body.amount, body.item)
  return { ready = true }
end

function Sender:_on_dispatched(body)
  if self.pending and self.pending.claim_id == body.claim_id then
    self.pending.amount = body.amount -- the router reports what it actually moved
    self.pending.dispatched_at = util.now_ms()
  else
    -- We lost the offer state (rebooted between offer and dispatch).
    -- Rebuild what we can; the receive timeout accepts a partial count if
    -- the baseline guess turns out to be off.
    self.log:warn("dispatch for claim %s without a matching offer -- rebuilding state",
      util.short_id(body.claim_id))
    self.pending = {
      claim_id = body.claim_id,
      item = body.item,
      amount = body.amount,
      frequency = body.frequency,
      baseline = self.result_inventory:count(body.item),
      offered_at = util.now_ms(),
      dispatched_at = util.now_ms(),
    }
    if body.frequency then self.inbox_porter:ensure_frequency(body.frequency) end
  end
  os.queueEvent(WAKE)
  return { ok = true }
end

-- Receiving ------------------------------------------------------------------

function Sender:_receipt_task()
  while true do
    if not self.pending then
      os.pullEvent(WAKE)
    else
      local ok, err = pcall(function() self:_receipt_tick() end)
      if not ok then
        self.log:error("receipt tick failed: %s", tostring(err))
        sleep(2)
      end
    end
  end
end

function Sender:_receipt_tick()
  local p = self.pending
  if not p then return end

  -- Self-heal: someone fiddling with the porter GUI shouldn't strand a delivery.
  self.inbox_porter:ensure_frequency(p.frequency)

  local arrived = self.result_inventory:count(p.item) - p.baseline
  local waited = util.now_ms() - (p.dispatched_at or p.offered_at)
  local timeout_ms = (self.config.receive_timeout_s or 60) * 1000

  if arrived >= p.amount then
    self:_finish_delivery(p, arrived)
  elseif p.dispatched_at and arrived > 0 and waited > timeout_ms then
    self.log:warn("claim %s: accepting partial delivery (%d/%d)",
      util.short_id(p.claim_id), arrived, p.amount)
    self:_finish_delivery(p, arrived)
  else
    if waited > 2 * timeout_ms and util.now_ms() - (p.last_nag or 0) > 30000 then
      p.last_nag = util.now_ms()
      self.log:warn("claim %s: still waiting on delivery (%d/%d after %s) -- check the pipes",
        util.short_id(p.claim_id), arrived, p.amount, util.fmt_age(waited))
    end
    sleep(1)
  end
end

function Sender:_finish_delivery(p, received)
  local ok = self.node:request(self.router, "delivery.received", {
    claim_id = p.claim_id, received = received,
  })

  local entry = self.ledger:get(p.claim_id) or { claim_id = p.claim_id }
  entry.received = received
  entry.status = ok and "completed" or "confirm_pending"
  entry.updated_at = util.now_ms()
  self.ledger:put(p.claim_id, entry)

  -- The goods are physically here, so free the order slot either way; the
  -- janitor keeps retrying the router confirmation if it failed.
  self.active[p.claim_id] = nil

  self.inbox_porter:ensure_frequency(self.idle_frequency)
  self.pending = nil
  self.log:info("claim %s: received %d x %s%s",
    util.short_id(p.claim_id), received, p.item,
    ok and "" or " (router confirmation still pending)")
end

-- Janitor --------------------------------------------------------------------

function Sender:_janitor_tick()
  local now = util.now_ms()

  for id, entry in pairs(self.ledger:all()) do
    if entry.status == "confirm_pending" then
      -- The router never acknowledged our receipt; keep retrying so its
      -- delivery port doesn't stay locked forever.
      local ok = self.node:request(self.router, "delivery.received", {
        claim_id = id, received = entry.received or entry.amount,
      }, { retries = 1 })
      if ok then
        entry.status = "completed"
        entry.updated_at = now
        self.ledger:put(id, entry)
        self.active[id] = nil
        self.log:info("claim %s: receipt confirmed after retry", util.short_id(id))
      end
    elseif (entry.status == "completed" or entry.status == "failed")
        and now - (entry.updated_at or 0) > 3600 * 1000 then
      self.ledger:delete(id)
    end
  end

  -- Reconcile in-flight orders with the router: claims can expire or fail
  -- over there, and without this the order slot would leak forever.
  for id, item in pairs(util.shallow_copy(self.active)) do
    local entry = self.ledger:get(id)
    if not entry or entry.status == "shipped" then
      local ok, body, err = self.node:request(self.router, "claim.get",
        { claim_id = id }, { retries = 1 })
      if ok and body.claim then
        local s = body.claim.status
        if s == "failed" or s == "expired" then
          self.log:warn("claim %s (%s) ended as %s at the router -- freeing the order slot",
            util.short_id(id), tostring(item), s)
          if entry then
            entry.status = "failed"
            entry.updated_at = now
            self.ledger:put(id, entry)
          end
          self.active[id] = nil
        end
      elseif not ok and err and err.code == "not_found" then
        -- The router archived it, meaning it finished a while ago.
        self.active[id] = nil
        if entry then
          entry.status = "completed"
          entry.updated_at = now
          self.ledger:put(id, entry)
        end
      end
    end
  end
end

-- Status & tasks -------------------------------------------------------------

function Sender:_status()
  local status = {
    role = "sender",
    name = self.config.name,
    id = os.getComputerID(),
    active_orders = self.active,
    input_buffer = self.input_buffer:counts(),
  }
  if self.pending then
    status.receiving = {
      claim = util.short_id(self.pending.claim_id),
      item = self.pending.item,
      amount = self.pending.amount,
    }
  end
  return status
end

function Sender:tasks()
  local tasks = self.node:tasks()
  tasks[#tasks + 1] = function()
    while true do
      local ok, err = pcall(function() self:_order_tick() end)
      if not ok then self.log:error("order tick failed: %s", tostring(err)) end
      sleep(self.config.poll_s or 2)
    end
  end
  tasks[#tasks + 1] = function() self:_receipt_task() end
  tasks[#tasks + 1] = function()
    while true do
      local ok, err = pcall(function() self:_janitor_tick() end)
      if not ok then self.log:error("janitor failed: %s", tostring(err)) end
      sleep(30)
    end
  end
  return tasks
end

return Sender
