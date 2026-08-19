--[[ lib/claims.lua — claim model, state machine, and persistent ledger.

A claim is the router's promise to deliver processed goods back to a sender:

  {
    id = "…",                  -- equals the original request id (idempotency!)
    sender_id = 12,            -- computer id to deliver to
    service = "crusher-1",
    input_item = "minecraft:iron_ingot", input_amount = 72,
    item = "mekanism:dust_iron", amount = 72, ratio = 1,
    status = "created", created_at = …, updated_at = …,
    history = { {status="created", at=…}, … },
    port = 3, dispatched = 72, received = 72,  -- filled in as delivery happens
  }

Lifecycle:
  created ──> in_transit ──> arrived ──> delivering ──> completed
     │             │            │            │
     ├─> expired   ├─> expired  └─> failed   └─> failed
     └─> failed    └─> failed
  (created may also jump straight to arrived: if the sender's "shipped"
  notice is lost, the router still promotes the claim when goods show up.)
]]

local class = require("lib.class")
local util = require("lib.util")
local JsonStore = require("lib.store")

local claims = {}

claims.STATUS = {
  CREATED = "created",
  IN_TRANSIT = "in_transit",
  ARRIVED = "arrived",
  DELIVERING = "delivering",
  COMPLETED = "completed",
  FAILED = "failed",
  EXPIRED = "expired",
}

local TRANSITIONS = {
  created    = { in_transit = true, arrived = true, expired = true, failed = true },
  in_transit = { arrived = true, expired = true, failed = true },
  arrived    = { delivering = true, failed = true },
  delivering = { completed = true, failed = true },
  -- completed / failed / expired are terminal
}

claims.TERMINAL = { completed = true, failed = true, expired = true }

--- Build and stamp a fresh claim from raw fields (validates them).
function claims.new(fields)
  assert(type(fields) == "table", "claim fields required")
  assert(type(fields.id) == "string" and #fields.id > 0, "claim.id required")
  assert(type(fields.sender_id) == "number", "claim.sender_id required")
  assert(type(fields.item) == "string" and #fields.item > 0, "claim.item required")
  local amount = math.floor(tonumber(fields.amount) or 0)
  assert(amount > 0, "claim.amount must be a positive number")

  local now = util.now_ms()
  return {
    id = fields.id,
    sender_id = fields.sender_id,
    service = fields.service,
    input_item = fields.input_item,
    input_amount = math.floor(tonumber(fields.input_amount) or amount),
    item = fields.item,
    amount = amount,
    ratio = tonumber(fields.ratio) or 1,
    status = claims.STATUS.CREATED,
    created_at = now,
    updated_at = now,
    history = { { status = claims.STATUS.CREATED, at = now } },
  }
end

--- Move a claim to a new status, enforcing the state machine.
function claims.transition(claim, to)
  local allowed = TRANSITIONS[claim.status]
  if not allowed or not allowed[to] then
    error(("invalid claim transition %s -> %s (claim %s)")
      :format(tostring(claim.status), tostring(to), util.short_id(claim.id)), 0)
  end
  claim.status = to
  claim.updated_at = util.now_ms()
  claim.history[#claim.history + 1] = { status = to, at = claim.updated_at }
end

--- ClaimLedger — in-memory index over a JsonStore, one JSON file per claim,
--- with an archive directory for finished claims.
local ClaimLedger = class()

function ClaimLedger:init(dir, log)
  self.store = JsonStore.new(dir)
  self.archive_store = JsonStore.new(fs.combine(dir, "archive"))
  self.log = log
  self.cache = self.store:all(log)
  local n = 0
  for _ in pairs(self.cache) do n = n + 1 end
  if log then log:info("claim ledger: loaded %d live claims from %s", n, dir) end
end

function ClaimLedger:get(id)
  return self.cache[id]
end

function ClaimLedger:save(claim)
  self.cache[claim.id] = claim
  self.store:put(claim.id, claim)
end

function ClaimLedger:transition(claim, to)
  claims.transition(claim, to)
  self:save(claim)
end

--- Claims in any of the given statuses, oldest first.
function ClaimLedger:by_status(...)
  local want = {}
  for _, s in ipairs({ ... }) do want[s] = true end
  local out = {}
  for _, c in pairs(self.cache) do
    if want[c.status] then out[#out + 1] = c end
  end
  table.sort(out, function(a, b) return a.created_at < b.created_at end)
  return out
end

function ClaimLedger:all()
  return self.cache
end

function ClaimLedger:archive(id)
  local c = self.cache[id]
  if not c then return end
  self.archive_store:put(id, c)
  self.store:delete(id)
  self.cache[id] = nil
end

claims.ClaimLedger = ClaimLedger

return claims
