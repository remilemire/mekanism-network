--[[ roles/router.lua — "computer C", the claim broker and delivery hub.

Owns the claim ledger (persisted as one JSON per claim, so a reboot resumes
exactly where it left off) and the bank of delivery ports: N chests that
each drain into their own entangloporter on a fixed frequency.

Loops:
  * rpc server     — claim.create / claim.shipped / claim.abort /
                     delivery.received / claim.get / claim.list / sys.status
  * intake watcher — matches goods arriving in the intake buffer against
                     open claims (FIFO, with reservations so two claims for
                     the same item can't both count the same dust)
  * delivery loop  — offers arrived claims to their sender, locks a port,
                     moves the goods, and notifies the sender
  * janitor        — expires stale claims, nags about stuck deliveries,
                     archives finished ones, re-asserts port frequencies
]]

local class = require("lib.class")
local util = require("lib.util")
local Node = require("lib.net")
local claims = require("lib.claims")
local InventoryClient = require("lib.clients.inventory")
local EntangloporterClient = require("lib.clients.entangloporter")

local Router = class()

function Router:init(config, log)
  assert(type(config.name) == "string", "router config needs a 'name'")
  assert(type(config.devices) == "table", "router config needs a 'devices' table")
  assert(type(config.ports) == "table" and #config.ports > 0,
    "router config needs at least one delivery port")
  assert(type(config.intake_frequency) == "string", "router config needs 'intake_frequency'")
  self.config = config
  self.log = log
  self.node = Node.new({
    protocol = config.protocol,
    hostname = config.name,
    modem = config.modem,
    log = log,
  })
  self.port_locks = {} -- port index -> claim id
end

function Router:setup()
  local d = self.config.devices
  self.intake_inventory = InventoryClient.new(d.intake_inventory)
  self.intake_porter = EntangloporterClient.new(d.intake_porter)
  self.intake_porter:ensure_frequency(self.config.intake_frequency)

  self.port_porters = {}
  for i, port in ipairs(self.config.ports) do
    assert(type(port.inventory) == "string" and type(port.porter) == "string"
      and type(port.frequency) == "string",
      "port " .. i .. " needs inventory, porter, and frequency")
    -- Wrapping validates the chest exists even though only pushItems uses it.
    InventoryClient.new(port.inventory)
    self.port_porters[i] = EntangloporterClient.new(port.porter)
    self.port_porters[i]:ensure_frequency(port.frequency)
  end

  self.ledger = claims.ClaimLedger.new(self.config.data_dir or "/data/claims", self.log)

  -- Reboot recovery: claims that were mid-delivery keep their port locked so
  -- we don't hand the same lane to someone else.
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.DELIVERING)) do
    if c.port and self.config.ports[c.port] then
      self.port_locks[c.port] = c.id
      self.log:warn("claim %s: resumed mid-delivery on port %d", util.short_id(c.id), c.port)
    end
  end

  self.node:open()
  self.node:handle("claim.create", function(body) return self:_on_claim_create(body) end)
  self.node:handle("claim.shipped", function(body) return self:_on_claim_shipped(body) end)
  self.node:handle("claim.abort", function(body) return self:_on_claim_abort(body) end)
  self.node:handle("delivery.received", function(body) return self:_on_delivery_received(body) end)
  self.node:handle("claim.get", function(body) return self:_on_claim_get(body) end)
  self.node:handle("claim.list", function(body) return self:_on_claim_list(body) end)
  self.node:handle("sys.status", function() return self:_status() end)
end

-- RPC handlers ---------------------------------------------------------------

function Router:_get_or_die(claim_id)
  local c = self.ledger:get(claim_id)
  if not c then
    error({ code = "not_found", message = "no claim " .. tostring(claim_id) })
  end
  return c
end

function Router:_on_claim_create(body)
  local fields = body and body.claim
  if type(fields) ~= "table" then
    error({ code = "bad_request", message = "claim fields required" })
  end

  -- Idempotent: a retried create for the same id returns the existing claim.
  local existing = self.ledger:get(fields.id)
  if existing then return { claim = existing } end

  local ok, claim = pcall(claims.new, fields)
  if not ok then
    error({ code = "bad_request", message = tostring(claim) })
  end

  self.ledger:save(claim)
  self.log:info("claim %s: created — expecting %d x %s for #%d (via %s)",
    util.short_id(claim.id), claim.amount, claim.item, claim.sender_id,
    tostring(claim.service))
  return { claim = claim }
end

function Router:_on_claim_shipped(body)
  local c = self:_get_or_die(body.claim_id)
  if c.status == claims.STATUS.CREATED then
    -- The sender reports how much actually shipped; scale the claim to match.
    local shipped = math.floor(tonumber(body.amount) or c.input_amount)
    if shipped > 0 and shipped ~= c.input_amount then
      c.input_amount = shipped
      c.amount = math.floor(shipped * (c.ratio or 1))
      self.log:info("claim %s: scaled to %d x %s (partial shipment)",
        util.short_id(c.id), c.amount, c.item)
    end
    self.ledger:transition(c, claims.STATUS.IN_TRANSIT)
  end
  -- Any later status means the notice is a late retry; that's fine.
  return { claim = c }
end

function Router:_on_claim_abort(body)
  local c = self:_get_or_die(body.claim_id)
  if c.status == claims.STATUS.FAILED then return { claim = c } end
  if c.status == claims.STATUS.CREATED or c.status == claims.STATUS.IN_TRANSIT then
    c.abort_reason = body.reason
    self.ledger:transition(c, claims.STATUS.FAILED)
    self.log:info("claim %s: aborted (%s)", util.short_id(c.id), tostring(body.reason))
    return { claim = c }
  end
  error({ code = "too_late", message = "claim is already " .. c.status })
end

function Router:_on_delivery_received(body)
  local c = self:_get_or_die(body.claim_id)
  if c.status == claims.STATUS.COMPLETED then return { claim = c } end -- idempotent
  if c.status ~= claims.STATUS.DELIVERING then
    error({ code = "bad_state", message = "claim is " .. c.status .. ", not delivering" })
  end
  c.received = math.floor(tonumber(body.received) or c.amount)
  self.ledger:transition(c, claims.STATUS.COMPLETED)
  if c.port then self.port_locks[c.port] = nil end
  self.log:info("claim %s: completed — #%d confirmed %d x %s (port %s freed)",
    util.short_id(c.id), c.sender_id, c.received, c.item, tostring(c.port))
  return { claim = c }
end

function Router:_on_claim_get(body)
  return { claim = self:_get_or_die(body.claim_id) }
end

function Router:_on_claim_list(body)
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
      port = c.port, dispatched = c.dispatched, received = c.received,
    }
  end
  return { claims = rows, now = util.now_ms() }
end

-- Intake matching -------------------------------------------------------------

function Router:_intake_tick()
  local counts = self.intake_inventory:counts()

  -- Goods already earmarked for claims further along must not be counted
  -- toward claims still waiting.
  local reserved = {}
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.ARRIVED, claims.STATUS.DELIVERING)) do
    if c.status == claims.STATUS.ARRIVED or not c.dispatched then
      reserved[c.item] = (reserved[c.item] or 0) + c.amount
    end
  end

  -- FIFO over open claims. "created" is included deliberately: if the
  -- sender's shipped-notice was lost, or the intake simply has stock on
  -- hand, the claim is fulfilled from what's physically there.
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.CREATED, claims.STATUS.IN_TRANSIT)) do
    local avail = (counts[c.item] or 0) - (reserved[c.item] or 0)
    if avail >= c.amount then
      self.ledger:transition(c, claims.STATUS.ARRIVED)
      reserved[c.item] = (reserved[c.item] or 0) + c.amount
      self.log:info("claim %s: %d x %s ready at intake", util.short_id(c.id), c.amount, c.item)
    end
  end
end

-- Delivery -------------------------------------------------------------------

function Router:_free_port()
  for i = 1, #self.config.ports do
    if not self.port_locks[i] then return i end
  end
  return nil
end

function Router:_delivery_tick()
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.ARRIVED)) do
    if (c.next_attempt_at or 0) <= util.now_ms() then
      local port_i = self:_free_port()
      if not port_i then return end -- every lane busy; try next tick
      self:_deliver(c, port_i)
      return -- one delivery per tick keeps the logs legible
    end
  end
end

function Router:_deliver(c, port_i)
  local port = self.config.ports[port_i]

  -- Negotiate first, lock after: the sender must confirm its inbox porter is
  -- tuned to this port's frequency before any items move.
  local ok, _, err = self.node:request(c.sender_id, "delivery.offer", {
    claim_id = c.id, item = c.item, amount = c.amount, frequency = port.frequency,
  }, { timeout_s = 3, retries = 2 })

  if not ok then
    local code = err and err.code or "unknown"
    c.next_attempt_at = util.now_ms() + (code == "busy" and 5 or 15) * 1000
    self.ledger:save(c)
    if code == "busy" then
      self.log:debug("claim %s: sender #%d busy, retrying shortly", util.short_id(c.id), c.sender_id)
    else
      self.log:warn("claim %s: offer to #%d failed (%s), retrying later",
        util.short_id(c.id), c.sender_id, code)
    end
    return
  end

  self.port_locks[port_i] = c.id
  c.port = port_i
  self.ledger:transition(c, claims.STATUS.DELIVERING)

  local moved = self.intake_inventory:push_item(port.inventory, c.item, c.amount)
  c.dispatched = moved
  self.ledger:save(c)
  if moved < c.amount then
    self.log:warn("claim %s: only %d/%d x %s made it to port %d — intake shortfall",
      util.short_id(c.id), moved, c.amount, c.item, port_i)
  end

  local ok2 = self.node:request(c.sender_id, "delivery.dispatched", {
    claim_id = c.id, item = c.item, amount = moved, frequency = port.frequency,
  })
  if not ok2 then
    -- Not fatal: the sender watches its inbox from the offer onward and its
    -- receive timeout will confirm whatever physically arrives.
    self.log:warn("claim %s: dispatch notice to #%d failed; sender will confirm from its inbox",
      util.short_id(c.id), c.sender_id)
  end

  self.log:info("claim %s: dispatched %d x %s to #%d via port %d (%s)",
    util.short_id(c.id), moved, c.item, c.sender_id, port_i, port.frequency)
end

-- Janitor --------------------------------------------------------------------

function Router:_janitor_tick()
  local now = util.now_ms()
  local ttl_ms = (self.config.claim_ttl_s or 900) * 1000
  local stuck_ms = (self.config.stuck_after_s or 300) * 1000
  local retention_ms = (self.config.retention_s or 3600) * 1000

  for _, c in ipairs(self.ledger:by_status(claims.STATUS.CREATED, claims.STATUS.IN_TRANSIT)) do
    if now - c.updated_at > ttl_ms then
      self.ledger:transition(c, claims.STATUS.EXPIRED)
      self.log:warn("claim %s: expired after %s in %s — goods may be sitting in intake unclaimed",
        util.short_id(c.id), util.fmt_age(now - c.created_at), c.status)
    end
  end

  for _, c in ipairs(self.ledger:by_status(claims.STATUS.DELIVERING)) do
    if now - c.updated_at > stuck_ms and now - (c.last_nag or 0) > 60000 then
      c.last_nag = now
      self.ledger:save(c)
      -- Deliberately keep the port locked: freeing it would let a new claim
      -- mix its items into an unconfirmed delivery. A human (or the sender's
      -- confirm-retry janitor) resolves this.
      self.log:warn("claim %s: delivery unconfirmed for %s on port %s — sender #%d asleep?",
        util.short_id(c.id), util.fmt_age(now - c.updated_at), tostring(c.port), c.sender_id)
    end
  end

  for _, c in ipairs(self.ledger:by_status(
    claims.STATUS.COMPLETED, claims.STATUS.FAILED, claims.STATUS.EXPIRED)) do
    if now - c.updated_at > retention_ms then
      self.ledger:archive(c.id)
    end
  end

  -- Re-assert static frequencies; a stray GUI click shouldn't derail lanes.
  self.intake_porter:ensure_frequency(self.config.intake_frequency)
  for i, porter in ipairs(self.port_porters) do
    porter:ensure_frequency(self.config.ports[i].frequency)
  end
end

-- Status & tasks -------------------------------------------------------------

function Router:_status()
  local by_status = {}
  for _, c in pairs(self.ledger:all()) do
    by_status[c.status] = (by_status[c.status] or 0) + 1
  end
  local ports = {}
  for i, port in ipairs(self.config.ports) do
    ports[i] = {
      frequency = port.frequency,
      claim = self.port_locks[i] and util.short_id(self.port_locks[i]) or "free",
    }
  end
  return {
    role = "router",
    name = self.config.name,
    id = os.getComputerID(),
    claims = by_status,
    ports = ports,
    intake = self.intake_inventory:counts(),
  }
end

function Router:tasks()
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
  tasks[#tasks + 1] = loop("intake tick", function() self:_intake_tick() end, self.config.poll_s or 2)
  tasks[#tasks + 1] = loop("delivery tick", function() self:_delivery_tick() end, self.config.poll_s or 2)
  tasks[#tasks + 1] = loop("janitor", function() self:_janitor_tick() end, 15)
  return tasks
end

return Router
