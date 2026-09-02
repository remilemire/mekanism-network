--[[ roles/sender.lua -- "computer A".

Watches an input buffer for items that have a configured route, orders
processing from the matching service, and moves goods under the ownership
model: this computer only ever pushes items OUT of chests it owns.

  input buffer -> outbox        (stage: the commitment + outgoing audit point)
  outbox -> service input chest (transport; janitor retries leftovers)
  inbox -> result chest         (drain; the inbox is the incoming audit point)

Deliveries are pushed INTO the inbox by the owning service -- this sender
never reaches into anyone else's chest. There is no router (v4): claims
live at the service that accepted them, so all bookkeeping RPCs go
straight to services. delivery.landed notifications are a fast-path
nudge; the janitor's per-service claim.get reconciliation is the
guarantee.

Local state:
  * a persistent ledger (one JSON per order) so reboots don't lose track
  * a persistent service -> input chest cache, so outbox leftovers stay
    shippable long after the claims that staged them are forgotten
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
  assert(type(config.devices.outbox_inventory) == "string",
    "sender config needs devices.outbox_inventory (outgoing staging chest)")
  assert(type(config.devices.inbox_inventory) == "string",
    "sender config needs devices.inbox_inventory (deliveries land there)")
  self.config = config
  self.log = log
  self.node = Node.new({
    protocol = config.protocol,
    hostname = config.name,
    modem = config.modem,
    log = log,
  })
  local data_dir = config.data_dir or "/data/sender"
  self.ledger = JsonStore.new(data_dir)
  self.chest_store = JsonStore.new(fs.combine(data_dir, "chests"))
  self.service_chests = {} -- service hostname -> input chest name
  -- Config routes are service -> {items}; invert to item -> service for the
  -- order loop. Errors here (duplicate items) surface before anything runs.
  self.item_routes = util.invert_routes(config.routes)
  self.active = {}
end

function Sender:setup()
  local d = self.config.devices
  self.input_buffer = InventoryClient.new(d.input_buffer)
  self.outbox_inventory = InventoryClient.new(d.outbox_inventory)
  self.inbox_inventory = InventoryClient.new(d.inbox_inventory)
  self.result_inventory = InventoryClient.new(d.result_inventory)

  for service, entry in pairs(self.chest_store:all(self.log)) do
    self.service_chests[service] = entry.input_chest
  end

  self.node:open()

  self.node:handle("delivery.landed", function(body) return self:_on_landed(body) end)
  self.node:handle("sys.status", function() return self:_status() end)

  -- Anything in the inbox is from an already-settled delivery; anything in
  -- the outbox is committed goods still awaiting transport.
  self:_drain_inbox()
  self:_resume()
  self:_push_outbox()
end

-- Boot recovery ----------------------------------------------------------------

function Sender:_resume()
  for id, entry in pairs(self.ledger:all(self.log)) do
    if entry.status == "shipped" then
      self.active[id] = entry.input_item
      self.log:warn("resuming claim %s: %s staged before reboot, delivery pending",
        util.short_id(id), tostring(entry.input_item))
    elseif entry.status == "staging" then
      -- Rebooted mid-staging: how much reached the outbox is unknowable
      -- (it commingles with other claims' goods). Report the requested
      -- amount as an upper bound; a shortfall just means the claim waits
      -- and expires while its goods recycle into service stock.
      entry.status = "shipped"
      entry.staged = entry.requested
      entry.moved = entry.requested
      entry.updated_at = util.now_ms()
      self.ledger:put(id, entry)
      self.active[id] = entry.input_item
      if entry.service then
        self.node:request(entry.service, "claim.shipped",
          { claim_id = id, amount = entry.requested }, { retries = 1 })
      end
      self.log:warn("claim %s: rebooted mid-staging; reported %d as an upper bound",
        util.short_id(id), entry.requested or 0)
    end
  end
end

-- Ordering ---------------------------------------------------------------------

function Sender:_order_tick()
  -- Backpressure: if the inbox can't fully drain (result inventory full),
  -- stop placing new orders -- deliveries would only pile up behind the
  -- clog. In-flight claims still land in the inbox; that's what it's for.
  if self.drain_stuck_since then
    self:_drain_inbox() -- keep trying; clears the flag once space frees
    if self.drain_stuck_since then
      if util.now_ms() - (self.order_pause_nag_at or 0) > 60000 then
        self.order_pause_nag_at = util.now_ms()
        self.log:warn("orders paused: inbox undrained for %s (result inventory full?)",
          util.fmt_age(util.now_ms() - self.drain_stuck_since))
      end
      return
    end
    self.order_pause_nag_at = nil
    self.log:info("inbox drained; orders resume")
  end

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

  -- Remember where this service receives goods: the janitor needs it to
  -- re-push outbox leftovers long after this claim is forgotten.
  if type(body.input_chest) == "string" and self.service_chests[service] ~= body.input_chest then
    self.service_chests[service] = body.input_chest
    self.chest_store:put(service, { input_chest = body.input_chest })
  end

  -- Ledger BEFORE moving anything: a reboot mid-staging must know this
  -- claim may have committed goods (see _resume). The service hostname is
  -- recorded because that's where every later question about it goes.
  self.ledger:put(claim.id, {
    claim_id = claim.id,
    service = service,
    input_item = item,
    output_item = claim.item,
    requested = claim.input_amount,
    status = "staging",
    updated_at = util.now_ms(),
  })
  self.active[claim.id] = item

  -- Stage: commit goods into our outbox, the outgoing verification point.
  local staged = self.input_buffer:push_item(self.outbox_inventory:get_name(), item, claim.input_amount)

  local entry = self.ledger:get(claim.id) or { claim_id = claim.id, input_item = item }
  entry.staged = staged
  entry.moved = staged
  entry.amount = math.floor(staged * (claim.ratio or 1))
  entry.status = staged > 0 and "shipped" or "failed"
  entry.updated_at = util.now_ms()
  self.ledger:put(claim.id, entry)

  if staged == 0 then
    self.log:warn("claim %s: could not stage any %s (buffer empty, or outbox full?) -- aborting",
      util.short_id(claim.id), item)
    self.node:request(service, "claim.abort", {
      claim_id = claim.id, reason = "nothing_to_ship",
    })
    self.active[claim.id] = nil
    return
  end

  -- The staged amount IS the commitment the service scales the claim to.
  -- Not fatal if lost: the janitor re-sends it, and the service promotes
  -- claims when goods physically reach its output chest.
  local ok2, _, err2 = self.node:request(service, "claim.shipped", {
    claim_id = claim.id, amount = staged,
  })
  if not ok2 then
    self.log:warn("claim %s: shipped notice failed (%s); janitor will re-send",
      util.short_id(claim.id), err2 and err2.code or "?")
  end
  self.log:info("claim %s: staged %d x %s", util.short_id(claim.id), staged, item)

  -- Best-effort transport now; the janitor retries whatever stays behind.
  self:_push_outbox()
end

-- Transport --------------------------------------------------------------------

function Sender:_outbox_warn(msg)
  if util.now_ms() - (self.outbox_warn_at or 0) > 30000 then
    self.outbox_warn_at = util.now_ms()
    self.log:warn("outbox: %s", msg)
  end
end

--- Push outbox contents onward to each item's service input chest. Safe
--- under multi-claim commingling: every item maps to exactly one service
--- (invert_routes enforces it) and the service credits arrivals FIFO, so
--- totals staged == totals destined regardless of whose items move first.
function Sender:_push_outbox()
  if self.outbox_busy then return end
  self.outbox_busy = true
  local ok, err = pcall(function() self:_push_outbox_inner() end)
  self.outbox_busy = false
  if not ok then error(err, 0) end
end

function Sender:_push_outbox_inner()
  for item, n in pairs(self.outbox_inventory:counts()) do
    local service = self.item_routes[item]
    local dest = service and self.service_chests[service]
    if dest then
      local ok, err = pcall(function()
        self.outbox_inventory:push_item(dest, item, n)
      end)
      if not ok then
        self:_outbox_warn(("cannot reach %s (%s)"):format(dest, tostring(err)))
      end
    elseif service then
      self:_outbox_warn(("no known input chest for %s yet"):format(service))
    else
      self:_outbox_warn(("%s has no route and is stuck"):format(item))
    end
  end

  local left = 0
  for _, n in pairs(self.outbox_inventory:counts()) do left = left + n end
  if left == 0 then
    self.outbox_stuck_since = nil
    self.outbox_nag_at = nil
  else
    self.outbox_stuck_since = self.outbox_stuck_since or util.now_ms()
    if util.now_ms() - self.outbox_stuck_since > 60000
        and util.now_ms() - (self.outbox_nag_at or 0) > 60000 then
      self.outbox_nag_at = util.now_ms()
      self.log:warn("%d items waiting in the outbox for %s -- service input chest full or unreachable?",
        left, util.fmt_age(util.now_ms() - self.outbox_stuck_since))
    end
  end
end

-- Receiving --------------------------------------------------------------------

--- Advisory fast path: a service says the goods are in our inbox chest.
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
--- inbox is the incoming audit point (only deliveries land there); the
--- result chest is what your machines may freely drain.
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
  self:_push_outbox()

  for id, entry in pairs(self.ledger:all()) do
    if (entry.status == "completed" or entry.status == "failed")
        and now - (entry.updated_at or 0) > 3600 * 1000 then
      self.ledger:delete(id)
    end
  end

  -- Reconcile with each claim's service. landed notices are advisory; this
  -- loop is what guarantees order slots free up and lost messages heal.
  for id, item in pairs(util.shallow_copy(self.active)) do
    local entry = self.ledger:get(id)
    local host = entry and entry.service
    if not host then
      -- Pre-v4 or corrupted entry: nowhere to ask, so free the slot.
      self.log:warn("claim %s (%s) has no recorded service -- freeing the order slot",
        util.short_id(id), tostring(item))
      self.active[id] = nil
    else
      local ok, body, err = self.node:request(host, "claim.get",
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
          self.log:warn("claim %s (%s) ended as %s at %s -- freeing the order slot",
            util.short_id(id), tostring(item), s, host)
          if entry then
            entry.status = "failed"
            entry.updated_at = now
            self.ledger:put(id, entry)
          end
          self.active[id] = nil
        elseif s == "created" and entry and entry.status == "shipped" then
          -- Our shipped notice was lost; re-send so the claim scales/advances.
          self.node:request(host, "claim.shipped",
            { claim_id = id, amount = entry.staged or entry.moved }, { retries = 1 })
        end
      elseif not ok and err and err.code == "not_found" then
        -- The service archived it, meaning it finished a while ago.
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

-- Status & tasks ---------------------------------------------------------------

function Sender:_status()
  return {
    role = "sender",
    name = self.config.name,
    id = os.getComputerID(),
    active_orders = self.active,
    orders_paused = self.drain_stuck_since ~= nil or nil,
    input_buffer = self.input_buffer:counts(),
    outbox = self.outbox_inventory:counts(),
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
