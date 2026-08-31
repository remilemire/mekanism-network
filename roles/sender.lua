--[[ roles/sender.lua -- "computer A".

Watches an input buffer for items that have a configured route, orders
processing from the matching service, and ships the raw goods itself: one
pushItems hop over the shared wired network straight into the service's
input chest. Deliveries land in this sender's inbox chest (moved there by
the router's workers); the sender's only receiving duty is trickling the
inbox onward into the result chest, which your machines may drain freely.

There is no arrival-counting machinery any more -- pushItems return values
made every transfer transactional, and the router tracks delivered amounts
authoritatively. delivery.landed notifications are a fast-path nudge; the
janitor's claim.get reconciliation is the guarantee.

Local state:
  * a persistent ledger (one JSON per order) so reboots don't lose track
  * self.active[claim_id] = input item -- in-flight orders; up to
    batch.max_inflight claims per item type may be outstanding at once
]]

local class = require("lib.class")
local util = require("lib.util")
local Node = require("lib.net")
local JsonStore = require("lib.store")
local InventoryClient = require("lib.clients.inventory")

local Sender = class()

function Sender:init(config, log)
  assert(type(config.name) == "string", "sender config needs a unique 'name'")
  assert(type(config.devices) == "table", "sender config needs a 'devices' table")
  assert(type(config.devices.inbox_inventory) == "string",
    "sender config needs devices.inbox_inventory (deliveries land there)")
  self.config = config
  self.log = log
  self.router = config.router_host or "router"
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
end

function Sender:setup()
  local d = self.config.devices
  self.input_buffer = InventoryClient.new(d.input_buffer)
  self.inbox_inventory = InventoryClient.new(d.inbox_inventory)
  self.result_inventory = InventoryClient.new(d.result_inventory)

  self.node:open()

  self.node:handle("delivery.landed", function(body) return self:_on_landed(body) end)
  self.node:handle("sys.status", function() return self:_status() end)

  -- Anything in the inbox is from an already-settled delivery; hand it on.
  self:_drain_inbox()
  self:_resume()
end

-- Boot recovery ----------------------------------------------------------------

function Sender:_resume()
  for id, entry in pairs(self.ledger:all(self.log)) do
    if entry.status == "shipped" then
      self.active[id] = entry.input_item
      self.log:warn("resuming claim %s: %s shipped before reboot, delivery pending",
        util.short_id(id), tostring(entry.input_item))
    end
  end
end

-- Ordering ---------------------------------------------------------------------

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

function Sender:_place_order(item, service, amount)
  local request_id = util.uuid()
  self.log:info("ordering %d x %s from %s", amount, item, service)

  local ok, body, err = self.node:request(service, "service.request", {
    id = request_id, item = item, amount = amount,
    inbox_chest = self.inbox_inventory:get_name(),
  })
  if not ok then
    self.log:warn("order for %s rejected by %s: %s",
      item, service, err and (err.message or err.code) or "?")
    return
  end
  local claim = body.claim

  -- Ship straight into the service's input chest over the wired network.
  local moved, push_err = 0, nil
  local pushed = pcall(function()
    moved = self.input_buffer:push_item(body.input_chest, item, claim.input_amount)
  end)
  if not pushed then
    self.log:warn("claim %s: cannot reach %s -- aborting",
      util.short_id(claim.id), tostring(body.input_chest))
    self.node:request(self.router, "claim.abort", {
      claim_id = claim.id, reason = "ship_failed",
    })
    return
  end
  if moved == 0 then
    self.log:warn("claim %s: could not move any %s (buffer empty, or %s full?) -- aborting",
      util.short_id(claim.id), item, tostring(body.input_chest))
    self.node:request(self.router, "claim.abort", {
      claim_id = claim.id, reason = "nothing_to_ship",
    })
    return
  end

  -- Tell the router how much actually shipped so it can scale the claim.
  -- Not fatal if lost: the janitor re-sends it, and the router promotes
  -- claims when goods physically show up in the service output chest.
  local ok2, _, err2 = self.node:request(self.router, "claim.shipped", {
    claim_id = claim.id, amount = moved,
  })
  if not ok2 then
    self.log:warn("claim %s: shipped notice failed (%s); janitor will re-send",
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
  self.log:info("claim %s: shipped %d x %s to %s",
    util.short_id(claim.id), moved, item, body.input_chest)
end

-- Receiving --------------------------------------------------------------------

--- Advisory fast path: the router says the goods are in our inbox chest.
function Sender:_on_landed(body)
  local entry = self.ledger:get(body.claim_id)
  if entry then
    entry.status = "completed"
    entry.received = math.floor(tonumber(body.moved) or 0)
    entry.updated_at = util.now_ms()
    self.ledger:put(body.claim_id, entry)
  end
  self.active[body.claim_id] = nil
  self.log:info("claim %s: %d items landed in the inbox",
    util.short_id(body.claim_id), tonumber(body.moved) or 0)
  self:_drain_inbox()
  return { ok = true }
end

--- Hand everything in the inbox chest onward to the result inventory. The
--- inbox is the delivery landing pad (workers push here so a full result
--- chest can't stall a delivery); the result chest is what your machines
--- may freely drain.
function Sender:_drain_inbox()
  local moved = 0
  for item, n in pairs(self.inbox_inventory:counts()) do
    moved = moved + self.inbox_inventory:push_item(self.result_inventory:get_name(), item, n)
  end
  if moved > 0 then
    self.log:debug("moved %d items from the inbox to %s",
      moved, self.result_inventory:get_name())
  end
  local left = 0
  for _, n in pairs(self.inbox_inventory:counts()) do left = left + n end
  if left == 0 then
    self.drain_stuck_since = nil
    self.drain_nag_at = nil
  else
    self.drain_stuck_since = self.drain_stuck_since or util.now_ms()
    if util.now_ms() - self.drain_stuck_since > 60000
        and util.now_ms() - (self.drain_nag_at or 0) > 60000 then
      self.drain_nag_at = util.now_ms()
      self.log:warn("%d items waiting in the inbox for %s -- the result inventory keeps running out of room",
        left, util.fmt_age(util.now_ms() - self.drain_stuck_since))
    end
  end
end

-- Janitor ----------------------------------------------------------------------

function Sender:_janitor_tick()
  local now = util.now_ms()

  self:_drain_inbox()

  for id, entry in pairs(self.ledger:all()) do
    if (entry.status == "completed" or entry.status == "failed")
        and now - (entry.updated_at or 0) > 3600 * 1000 then
      self.ledger:delete(id)
    end
  end

  -- Reconcile with the router. landed notices are advisory; this loop is
  -- what guarantees order slots free up and lost messages heal.
  for id, item in pairs(util.shallow_copy(self.active)) do
    local entry = self.ledger:get(id)
    local ok, body, err = self.node:request(self.router, "claim.get",
      { claim_id = id }, { retries = 1 })
    if ok and body.claim then
      local s = body.claim.status
      if s == "completed" then
        if entry then
          entry.status = "completed"
          entry.received = body.claim.received
          entry.updated_at = now
          self.ledger:put(id, entry)
        end
        self.active[id] = nil
      elseif s == "failed" or s == "expired" then
        self.log:warn("claim %s (%s) ended as %s at the router -- freeing the order slot",
          util.short_id(id), tostring(item), s)
        if entry then
          entry.status = "failed"
          entry.updated_at = now
          self.ledger:put(id, entry)
        end
        self.active[id] = nil
      elseif s == "created" and entry and entry.status == "shipped" then
        -- Our shipped notice was lost; re-send so the claim scales/advances.
        self.node:request(self.router, "claim.shipped",
          { claim_id = id, amount = entry.moved }, { retries = 1 })
      end
    elseif not ok and err and err.code == "not_found" then
      -- Router archived it, meaning it finished a while ago.
      self.active[id] = nil
      if entry then
        entry.status = "completed"
        entry.updated_at = now
        self.ledger:put(id, entry)
      end
    end
  end
end

-- Status & tasks ---------------------------------------------------------------

function Sender:_status()
  return {
    role = "sender",
    name = self.config.name,
    id = os.getComputerID(),
    active_orders = self.active,
    input_buffer = self.input_buffer:counts(),
    inbox_buffer = self.inbox_inventory:counts(),
  }
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
