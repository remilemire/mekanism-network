--[[ tools/claims.lua -- inspect the router's claim ledger.

  tools/claims.lua                  -- newest 50 claims, any status
  tools/claims.lua failed           -- filter by status
  tools/claims.lua show 1a022378    -- full detail for one claim (id prefix ok)
  (append a router hostname as the last argument if it isn't "router")
]]

local args = { ... }
local mode, status_filter, show_target, router_host
if args[1] == "show" then
  mode = "show"
  show_target = args[2]
  router_host = args[3] or "router"
  if not show_target then
    printError("usage: claims show <claim-id-or-prefix> [router-host]")
    return
  end
else
  mode = "list"
  status_filter = args[1]
  router_host = args[2] or "router"
end

local here = fs.getDir(shell.getRunningProgram())
local root = fs.getDir(here)
local prefix = root == "" and "" or ("/" .. root)
package.path = prefix .. "/?.lua;" .. package.path

local Node = require("lib.net")
local Log = require("lib.log")
local util = require("lib.util")

local node = Node.new({ client = true, log = Log.new("claims", { level = "warn", file = false }) })
node:open()

local function show_claim()
  local ok, body, err = node:request(router_host, "claim.get",
    { claim_id = show_target }, { retries = 1, timeout_s = 3 })
  if not ok then
    printError("lookup failed: " .. (err and (err.message or err.code) or "?"))
    return
  end
  local c = body.claim
  local now = util.now_ms()
  local out = {}
  out[#out + 1] = "claim " .. tostring(c.id)
  out[#out + 1] = "  status:  " .. tostring(c.status)
    .. (c.abort_reason and (" (aborted: " .. tostring(c.abort_reason) .. ")") or "")
  out[#out + 1] = ("  output:  %d x %s"):format(c.amount or 0, tostring(c.item))
  out[#out + 1] = ("  input:   %d x %s"):format(c.input_amount or 0, tostring(c.input_item))
  out[#out + 1] = ("  sender:  #%s   service: %s"):format(tostring(c.sender_id), tostring(c.service))
  out[#out + 1] = ("  port: %s   dispatched: %s   received: %s"):format(
    tostring(c.port or "-"), tostring(c.dispatched or "-"), tostring(c.received or "-"))
  out[#out + 1] = "  history:"
  for _, h in ipairs(c.history or {}) do
    out[#out + 1] = ("    %-11s %s ago"):format(tostring(h.status), util.fmt_age(now - (h.at or now)))
  end
  textutils.pagedPrint(table.concat(out, "\n"))
end

local function list_claims()
  local ok, body, err = node:request(router_host, "claim.list",
    { status = status_filter }, { retries = 1, timeout_s = 3 })
  if not ok then
    printError("router unreachable: " .. (err and (err.message or err.code) or "?"))
    return
  end
  if #body.claims == 0 then
    print("no claims" .. (status_filter and (" with status " .. status_filter) or ""))
    return
  end
  local out = {
    ("%-10s %-11s %6s %-28s %-6s %s")
      :format("id", "status", "amount", "item", "sender", "age"),
  }
  for _, c in ipairs(body.claims) do
    out[#out + 1] = ("%-10s %-11s %6d %-28s #%-5d %s"):format(
      util.short_id(c.id), c.status, c.amount, c.item, c.sender_id,
      util.fmt_age((body.now or util.now_ms()) - c.created_at))
  end
  textutils.pagedPrint(table.concat(out, "\n"))
end

local tasks = node:tasks()
tasks[#tasks + 1] = mode == "show" and show_claim or list_claims

parallel.waitForAny(table.unpack(tasks))
