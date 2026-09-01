--[[ tools/claims.lua -- inspect (and rescue) the router's claim ledger.

  tools/claims.lua                  -- newest 50 claims, any status
  tools/claims.lua failed           -- filter by status
  tools/claims.lua show 1a022378    -- full detail for one claim (id prefix ok)
  tools/claims.lua abort 1a022378   -- operator escape hatch: fail a claim
                                       (its goods recycle into service stock)
  (append a router hostname as the last argument if it isn't "router")
]]

local args = { ... }
local mode, status_filter, target, router_host
if args[1] == "show" or args[1] == "abort" then
  mode = args[1]
  target = args[2]
  router_host = args[3] or "router"
  if not target then
    printError("usage: claims " .. mode .. " <claim-id-or-prefix> [router-host]")
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
local render = require("lib.render")

local line = render.line

local node = Node.new({ client = true, log = Log.new("claims", { level = "warn", file = false }) })
node:open()

--- Full forensic view of one claim. Item ids are shown unabbreviated here
--- on purpose: id mismatches are exactly what this view is for.
local function abort_claim()
  local ok, body, err = node:request(router_host, "claim.abort",
    { claim_id = target, reason = "manual" }, { retries = 1, timeout_s = 3 })
  if not ok then
    printError("abort failed: " .. (err and (err.message or err.code) or "?"))
    return
  end
  line(colors.white, "claim " .. tostring(body.claim.id),
    colors.gray, " is now ", render.status_color(body.claim.status), tostring(body.claim.status))
end

local function show_claim()
  local ok, body, err = node:request(router_host, "claim.get",
    { claim_id = target }, { retries = 1, timeout_s = 3 })
  if not ok then
    printError("lookup failed: " .. (err and (err.message or err.code) or "?"))
    return
  end
  local c = body.claim
  local now = util.now_ms()
  line(colors.white, "claim " .. tostring(c.id))
  line(colors.gray, "  status:  ", render.status_color(c.status), tostring(c.status),
    colors.red, c.abort_reason and ("  (" .. tostring(c.abort_reason) .. ")") or "")
  line(colors.gray, "  output:  ", colors.white, ("%d x %s"):format(c.amount or 0, tostring(c.item)))
  line(colors.gray, "  input:   ", colors.white, ("%d x %s"):format(c.input_amount or 0, tostring(c.input_item)))
  line(colors.gray, "  sender:  ", colors.white, "#" .. tostring(c.sender_id),
    colors.gray, "   service: ", colors.white, tostring(c.service))
  line(colors.gray, "  from:    ", colors.white, tostring(c.service_output_chest))
  line(colors.gray, "  to:      ", colors.white, tostring(c.inbox_chest))
  line(colors.gray, "  moved: ", colors.white,
    tostring(c.dispatched or 0) .. "/" .. tostring(c.amount or 0),
    colors.gray, "   job seq: ", colors.white, tostring(c.deliver_seq or "-"))
  line(colors.gray, "  history:")
  for _, h in ipairs(c.history or {}) do
    line(render.status_color(h.status), ("    %-11s"):format(tostring(h.status)),
      colors.gray, util.fmt_age(now - (h.at or now)) .. " ago")
  end
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
  local now = body.now or util.now_ms()
  line(colors.gray, ("%-8s %-10s %4s %-15s %-3s %s")
    :format("id", "status", "amt", "item", "snd", "age"))
  for _, c in ipairs(body.claims) do
    line(
      colors.white, ("%-8s "):format(util.short_id(c.id)),
      render.status_color(c.status), ("%-10s "):format(tostring(c.status)),
      colors.white, ("%4d "):format(c.amount or 0),
      colors.lightGray, ("%-15s "):format(render.short_item(c.item):sub(1, 15)),
      colors.white, ("#%-2s "):format(tostring(c.sender_id)),
      colors.gray, util.fmt_age(now - (c.created_at or now)))
  end
end

local MODES = { show = show_claim, abort = abort_claim, list = list_claims }

local tasks = node:tasks()
tasks[#tasks + 1] = MODES[mode]

parallel.waitForAny(table.unpack(tasks))
