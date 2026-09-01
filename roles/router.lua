--[[ roles/router.lua -- "computer C", the claim broker and delivery
dispatcher.

Owns the claim ledger (persisted one JSON per claim, so a reboot resumes
where it left off) and moves NOTHING itself. Under the ownership model
every delivery is executed by the service that owns the output chest: the
router commands `deliver.exec` and the service pushes the goods into the
ordering sender's inbox. The router only ever READS chests (matching).

Loops:
  * rpc server       -- claim.create / claim.shipped / claim.abort /
                        claim.get / claim.list / sys.status
  * match tick       -- per service output chest, FIFO with per-item
                        reservations, promotes claims to `arrived`
  * dispatcher pool  -- N coroutines that command services to deliver and
                        reconcile unknown outcomes via job.result
  * janitor          -- expires stale claims, nags about stuck deliveries,
                        prunes the archive, watches disk space

Delivery idempotency: each dispatch gets job id "<claim_id>-d<seq>" with
the seq persisted BEFORE anything is sent. RPC retries reuse the id (the
service replays its persisted result); a deliberate re-dispatch bumps seq.
After a timeout the router asks the service job.result before retrying --
services are static, so there is no reassignment and the only surviving
double-move window is a service reboot between its push and its result
write, which job.result surfaces as "interrupted" with a loud warning.
]]

local class = require("lib.class")
local util = require("lib.util")
local Node = require("lib.net")
local claims = require("lib.claims")
local InventoryClient = require("lib.clients.inventory")

local Router = class()

function Router:init(config, log)
  assert(type(config.name) == "string", "router config needs a 'name'")
  self.config = config
  self.log = log
  self.node = Node.new({
    protocol = config.protocol,
    hostname = config.name,
    modem = config.modem,
    log = log,
  })
  self.chest_clients = {} -- peripheral name -> InventoryClient
  self.chest_nags = {}    -- peripheral name -> last unreadable-warning time
  self.service_busy = {}  -- service hostname -> claim id with a job in flight
  self.claim_busy = {}    -- claim id -> being handled by a dispatcher
  self.jobs_inflight = {} -- job id -> true
end

function Router:setup()
  self.ledger = claims.ClaimLedger.new(self.config.data_dir or "/data/claims", self.log)

  for _, c in ipairs(self.ledger:by_status(claims.STATUS.DELIVERING)) do
    self.log:warn("claim %s: was mid-delivery before reboot; will reconcile via job.result",
      util.short_id(c.id))
  end

  self.node:open()
  self.node:handle("claim.create", function(body) return self:_on_claim_create(body) end)
  self.node:handle("claim.shipped", function(body) return self:_on_claim_shipped(body) end)
  self.node:handle("claim.abort", function(body) return self:_on_claim_abort(body) end)
  self.node:handle("claim.get", function(body) return self:_on_claim_get(body) end)
  self.node:handle("claim.list", function(body) return self:_on_claim_list(body) end)
  self.node:handle("sys.status", function() return self:_status() end)
end

-- Chest access -----------------------------------------------------------------

function Router:_chest(name)
  local client = self.chest_clients[name]
  if client then return client end
  local ok, created = pcall(InventoryClient.new, name)
  if not ok then return nil, created end
  self.chest_clients[name] = created
  return created
end

function Router:_chest_counts(name)
  local client, err = self:_chest(name)
  if not client then return nil, err end
  local ok, counts = pcall(function() return client:counts() end)
  if not ok then
    self.chest_clients[name] = nil -- modem replaced? re-wrap next time
    return nil, counts
  end
  return counts
end

function Router:_nag_chest(name, err)
  if util.now_ms() - (self.chest_nags[name] or 0) > 30 * 1000 then
    self.chest_nags[name] = util.now_ms()
    self.log:warn("cannot read %s (%s); its claims are on hold", name, tostring(err))
  end
end

-- RPC handlers -----------------------------------------------------------------

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
  local existing = self.ledger:get(fields.id)
  if existing then return { claim = existing } end

  local ok, claim = pcall(claims.new, fields)
  if not ok then
    error({ code = "bad_request", message = tostring(claim) })
  end

  self.ledger:save(claim)
  self.log:info("claim %s: created -- expecting %d x %s in %s for #%d",
    util.short_id(claim.id), claim.amount, claim.item,
    claim.service_output_chest, claim.sender_id)
  return { claim = claim }
end

function Router:_on_claim_shipped(body)
  local c = self:_get_or_die(body.claim_id)
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

function Router:_on_claim_abort(body)
  -- Accepts id prefixes so the operator escape hatch (claims abort <id>)
  -- can use the short ids the tools print.
  local c, ambiguous = self.ledger:find(tostring(body.claim_id or ""))
  if ambiguous then
    error({ code = "ambiguous", message = "multiple claims match that prefix" })
  end
  if not c then
    error({ code = "not_found", message = "no claim " .. tostring(body.claim_id) })
  end
  if c.status == claims.STATUS.FAILED then return { claim = c } end
  if claims.TERMINAL[c.status] then
    error({ code = "too_late", message = "claim is already " .. c.status })
  end
  -- arrived/delivering aborts are the operator escape hatch for a stuck
  -- service; goods already produced simply become stock for future claims.
  if c.status == claims.STATUS.ARRIVED or c.status == claims.STATUS.DELIVERING then
    self.log:warn("claim %s: aborted while %s -- its goods become service stock",
      util.short_id(c.id), c.status)
  end
  c.abort_reason = body.reason
  self.ledger:transition(c, claims.STATUS.FAILED)
  self.log:info("claim %s: aborted (%s)", util.short_id(c.id), tostring(body.reason))
  return { claim = c }
end

function Router:_on_claim_get(body)
  local c, ambiguous = self.ledger:find(tostring(body.claim_id or ""))
  if ambiguous then
    error({ code = "ambiguous", message = "multiple claims match that prefix" })
  end
  if not c then
    error({ code = "not_found", message = "no claim " .. tostring(body.claim_id) })
  end
  return { claim = c }
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
      dispatched = c.dispatched, received = c.received,
      deliver_seq = c.deliver_seq, service = c.service,
    }
  end
  return { claims = rows, now = util.now_ms() }
end

-- Matching ---------------------------------------------------------------------

function Router:_match_tick()
  local by_chest = {}
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.CREATED, claims.STATUS.IN_TRANSIT)) do
    local chest = c.service_output_chest
    if type(chest) == "string" then
      by_chest[chest] = by_chest[chest] or {}
      table.insert(by_chest[chest], c) -- by_status is oldest-first already
    end
  end

  -- Goods earmarked by claims further along must not count for new ones.
  local reserved = {} -- chest -> item -> amount
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.ARRIVED, claims.STATUS.DELIVERING)) do
    local chest = c.service_output_chest
    if chest then
      local remaining = (c.amount or 0) - (c.dispatched or 0)
      if remaining > 0 then
        reserved[chest] = reserved[chest] or {}
        reserved[chest][c.item] = (reserved[chest][c.item] or 0) + remaining
      end
    end
  end

  for chest, bucket in pairs(by_chest) do
    local counts, err = self:_chest_counts(chest)
    if not counts then
      self:_nag_chest(chest, err)
    else
      local r = reserved[chest] or {}
      for _, c in ipairs(bucket) do
        local avail = (counts[c.item] or 0) - (r[c.item] or 0)
        if avail >= c.amount then
          self.ledger:transition(c, claims.STATUS.ARRIVED)
          r[c.item] = (r[c.item] or 0) + c.amount
          self.log:info("claim %s: %d x %s ready in %s",
            util.short_id(c.id), c.amount, c.item, chest)
        end
      end
    end
  end
end

-- Delivery dispatch ------------------------------------------------------------

--- Pick the oldest claim that needs dispatcher attention and mark it busy.
--- Cooperative scheduling makes check-and-mark atomic within a coroutine.
function Router:_next_deliverable()
  local now = util.now_ms()
  for _, c in ipairs(self.ledger:by_status(claims.STATUS.ARRIVED, claims.STATUS.DELIVERING)) do
    if (c.next_attempt_at or 0) <= now
        and not self.claim_busy[c.id] and not self.service_busy[c.service or ""] then
      self.claim_busy[c.id] = true
      return c
    end
  end
  return nil
end

function Router:_dispatch(c)
  local dst = c.inbox_chest
  if type(c.service) ~= "string" or type(dst) ~= "string" then
    self.log:warn("claim %s: missing service or inbox address -- failing it", util.short_id(c.id))
    self.ledger:transition(c, claims.STATUS.FAILED)
    return
  end
  local remaining = (c.amount or 0) - (c.dispatched or 0)
  if remaining <= 0 then
    self:_complete(c)
    return
  end

  -- Persist the job identity BEFORE sending anything: a rebooted router
  -- must ask job.result about this id, never re-dispatch blindly.
  c.deliver_seq = (c.deliver_seq or 0) + 1
  c.deliver_unresolved = true
  if c.status == claims.STATUS.ARRIVED then
    self.ledger:transition(c, claims.STATUS.DELIVERING)
  else
    self.ledger:save(c)
  end

  local job_id = c.id .. "-d" .. c.deliver_seq
  self.service_busy[c.service] = c.id
  self.jobs_inflight[job_id] = true

  local moved, fail_code
  local ok, body, err = self.node:request(c.service, "deliver.exec", {
    to = dst, item = c.item, amount = remaining,
  }, { id = job_id, timeout_s = 5, retries = 2 })
  if ok then moved = body.moved else fail_code = err and err.code or "timeout" end

  self.jobs_inflight[job_id] = nil
  self.service_busy[c.service] = nil

  if moved == nil then
    -- A clean structured refusal means nothing moved; a timeout leaves the
    -- outcome unknown (the job may be queued behind other work on the
    -- service), so keep the unresolved flag and let reconciliation query
    -- job.result before any re-dispatch.
    if fail_code == "chest_missing" or fail_code == "bad_request" then
      c.deliver_unresolved = nil
    end
    c.next_attempt_at = util.now_ms() + 10 * 1000
    self.ledger:save(c)
    self.log:warn("claim %s: deliver job %s did not finish (%s); will retry",
      util.short_id(c.id), job_id, tostring(fail_code))
    return
  end

  self:_apply_move(c, moved)
end

function Router:_reconcile(c)
  if c.deliver_unresolved then
    local job_id = c.id .. "-d" .. (c.deliver_seq or 0)
    local ok, body, err = self.node:request(c.service, "job.result",
      { job_id = job_id }, { retries = 1, timeout_s = 3 })
    if ok then
      self:_apply_move(c, body.moved)
      return
    end
    local code = err and err.code
    if code == "not_found" then
      c.deliver_unresolved = nil -- the service never received it; safe to retry
      self.ledger:save(c)
    elseif code == "interrupted" then
      -- The service rebooted between pushing and recording the result --
      -- the one honest double-move window left in this design.
      self.log:warn("claim %s: job %s was interrupted mid-move on %s -- re-dispatching (small double-move risk)",
        util.short_id(c.id), job_id, tostring(c.service))
      c.deliver_unresolved = nil
      self.ledger:save(c)
    else
      -- Service unreachable; it is static, so wait rather than guess. The
      -- janitor's stuck-nag makes prolonged outages visible, and
      -- `claims abort` is the operator escape hatch.
      c.next_attempt_at = util.now_ms() + 10 * 1000
      self.ledger:save(c)
      return
    end
  end

  if (c.amount or 0) - (c.dispatched or 0) > 0 then
    self:_dispatch(c)
  else
    self:_complete(c)
  end
end

function Router:_apply_move(c, moved)
  moved = math.floor(tonumber(moved) or 0)
  c.dispatched = (c.dispatched or 0) + moved
  c.deliver_unresolved = nil
  if c.dispatched >= (c.amount or 0) then
    self:_complete(c)
  else
    -- Partial: the inbox chest was full, or the output raced another claim.
    c.next_attempt_at = util.now_ms() + (moved > 0 and 5 or 10) * 1000
    self.ledger:save(c)
    self.log:info("claim %s: partial delivery %d/%d; will move the remainder",
      util.short_id(c.id), c.dispatched, c.amount)
  end
end

function Router:_complete(c)
  if c.status == claims.STATUS.ARRIVED then
    self.ledger:transition(c, claims.STATUS.DELIVERING)
  end
  if c.status ~= claims.STATUS.DELIVERING then
    return -- aborted out from under the dispatcher; leave it be
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

function Router:_janitor_tick()
  local now = util.now_ms()
  local ttl_ms = (self.config.claim_ttl_s or 900) * 1000
  local stuck_ms = (self.config.stuck_after_s or 300) * 1000
  local retention_ms = (self.config.retention_s or 3600) * 1000

  for _, c in ipairs(self.ledger:by_status(claims.STATUS.CREATED, claims.STATUS.IN_TRANSIT)) do
    if now - c.updated_at > ttl_ms then
      self.ledger:transition(c, claims.STATUS.EXPIRED)
      self.log:warn("claim %s: expired after %s in %s -- goods may be sitting in %s unclaimed",
        util.short_id(c.id), util.fmt_age(now - c.created_at), c.status,
        tostring(c.service_output_chest))
    end
  end

  for _, c in ipairs(self.ledger:by_status(claims.STATUS.DELIVERING)) do
    if now - c.updated_at > stuck_ms and now - (c.last_nag or 0) > 60000 then
      c.last_nag = now
      self.ledger:save(c)
      self.log:warn("claim %s: delivering for %s (%d/%d moved) -- inbox %s full, or chest offline?",
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

function Router:_status()
  local by_status = {}
  local pending = {}
  for _, c in pairs(self.ledger:all()) do
    by_status[c.status] = (by_status[c.status] or 0) + 1
    if not claims.TERMINAL[c.status] and c.service then
      pending[c.service] = (pending[c.service] or 0) + 1
    end
  end
  return {
    role = "router",
    name = self.config.name,
    id = os.getComputerID(),
    claims = by_status,
    services = pending,
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
  tasks[#tasks + 1] = loop("match tick", function() self:_match_tick() end, self.config.poll_s or 2)
  tasks[#tasks + 1] = loop("janitor", function() self:_janitor_tick() end, 15)
  -- Dispatcher pool: each coroutine handles one claim at a time, so this is
  -- also the cap on concurrent deliver moves in flight.
  for i = 1, self.config.dispatchers or 4 do
    tasks[#tasks + 1] = loop("dispatcher " .. i, function()
      local c = self:_next_deliverable()
      if c then
        local ok, err = pcall(function()
          if c.status == claims.STATUS.ARRIVED then self:_dispatch(c) else self:_reconcile(c) end
        end)
        self.claim_busy[c.id] = nil
        if not ok then error(err, 0) end
      end
    end, 1)
  end
  return tasks
end

return Router
