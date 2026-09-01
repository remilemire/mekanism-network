--[[ tools/claims.lua -- inspect (and rescue) claims across every service.

  tools/claims.lua                  -- newest claims from all services
  tools/claims.lua failed           -- filter by status
  tools/claims.lua show 1a022378    -- full detail for one claim (id prefix ok)
  tools/claims.lua abort 1a022378   -- operator escape hatch: fail a claim
                                       (its goods recycle into service stock)
  (append a service hostname as the last argument to target just one)
]]

local args = { ... }
local mode, status_filter, target, explicit_host
if args[1] == "show" or args[1] == "abort" then
  mode = args[1]
  target = args[2]
  explicit_host = args[3]
  if not target then
    printError("usage: claims " .. mode .. " <claim-id-or-prefix> [service-host]")
    return
  end
else
  mode = "list"
  status_filter = args[1]
  explicit_host = args[2]
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

--- Every service on the network (or just the explicitly named one).
local function service_hosts()
  if explicit_host then return { explicit_host } end
  local hosts = {}
  local ids = { rednet.lookup(node.protocol) }
  table.sort(ids)
  for _, id in ipairs(ids) do
    local ok, body = node:request(id, "sys.status", {}, { retries = 0, timeout_s = 2 })
    if ok and body.role == "service" and body.name then
      hosts[#hosts + 1] = body.name
    end
  end
  return hosts
end

local function print_claim(c)
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
    tostring(c.dispatched or 0) .. "/" .. tostring(c.amount or 0))
  line(colors.gray, "  history:")
  for _, h in ipairs(c.history or {}) do
    line(render.status_color(h.status), ("    %-11s"):format(tostring(h.status)),
      colors.gray, util.fmt_age(now - (h.at or now)) .. " ago")
  end
end

--- Ask each service in turn until one knows the claim. Returns the reply
--- body, or nil after reporting why.
local function find_on_services(method, extra)
  local hosts = service_hosts()
  if #hosts == 0 then
    printError("no services found -- are they running main.lua?")
    return nil
  end
  for _, host in ipairs(hosts) do
    local req = { claim_id = target }
    for k, v in pairs(extra or {}) do req[k] = v end
    local ok, body, err = node:request(host, method, req, { retries = 1, timeout_s = 3 })
    if ok then return body end
    local code = err and err.code
    if code == "ambiguous" then
      printError("multiple claims on " .. host .. " match that prefix -- use more characters")
      return nil
    elseif code ~= "not_found" and code ~= "timeout" then
      printError(host .. ": " .. (err and (err.message or code) or "?"))
      return nil
    end
  end
  printError("no claim matches " .. tostring(target) .. " on any service")
  return nil
end

local function show_claim()
  local body = find_on_services("claim.get")
  if body then print_claim(body.claim) end
end

local function abort_claim()
  local body = find_on_services("claim.abort", { reason = "manual" })
  if body then
    line(colors.white, "claim " .. tostring(body.claim.id), colors.gray, " is now ",
      render.status_color(body.claim.status), tostring(body.claim.status))
  end
end

local function list_claims()
  local hosts = service_hosts()
  if #hosts == 0 then
    printError("no services found -- are they running main.lua?")
    return
  end
  local rows = {}
  local now = util.now_ms()
  for _, host in ipairs(hosts) do
    local ok, body = node:request(host, "claim.list",
      { status = status_filter }, { retries = 1, timeout_s = 3 })
    if ok then
      now = body.now or now
      for _, c in ipairs(body.claims) do rows[#rows + 1] = c end
    else
      printError(host .. " did not answer; its claims are missing below")
    end
  end
  if #rows == 0 then
    print("no claims" .. (status_filter and (" with status " .. status_filter) or ""))
    return
  end
  table.sort(rows, function(a, b) return (a.created_at or 0) > (b.created_at or 0) end)

  line(colors.gray, ("%-8s %-10s %3s %-12s %-8s %s")
    :format("id", "status", "amt", "item", "service", "age"))
  for i = 1, math.min(#rows, 50) do
    local c = rows[i]
    line(
      colors.white, ("%-8s "):format(util.short_id(c.id)),
      render.status_color(c.status), ("%-10s "):format(tostring(c.status)),
      colors.white, ("%3d "):format(c.amount or 0),
      colors.lightGray, ("%-12s "):format(render.short_item(c.item):sub(1, 12)),
      colors.white, ("%-8s "):format(tostring(c.service or "?"):sub(1, 8)),
      colors.gray, util.fmt_age(now - (c.created_at or now)))
  end
end

local MODES = { show = show_claim, abort = abort_claim, list = list_claims }

local tasks = node:tasks()
tasks[#tasks + 1] = MODES[mode]

parallel.waitForAny(table.unpack(tasks))
