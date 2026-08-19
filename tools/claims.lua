--[[ tools/claims.lua — list claims from the router's ledger.

  tools/claims.lua                  -- newest 50 claims, any status
  tools/claims.lua in_transit       -- filter by status
  tools/claims.lua arrived my-router -- optional second arg: router hostname
]]

local args = { ... }
local status_filter = args[1]
local router_host = args[2] or "router"

local here = fs.getDir(shell.getRunningProgram())
local root = fs.getDir(here)
local prefix = root == "" and "" or ("/" .. root)
package.path = prefix .. "/?.lua;" .. package.path

local Node = require("lib.net")
local Log = require("lib.log")
local util = require("lib.util")

local node = Node.new({ log = Log.new("claims", { level = "warn", file = false }) })
node:open()

local tasks = node:tasks()
tasks[#tasks + 1] = function()
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
  print(("%-10s %-11s %6s %-28s %-6s %s")
    :format("id", "status", "amount", "item", "sender", "age"))
  for _, c in ipairs(body.claims) do
    print(("%-10s %-11s %6d %-28s #%-5d %s"):format(
      util.short_id(c.id), c.status, c.amount, c.item, c.sender_id,
      util.fmt_age((body.now or util.now_ms()) - c.created_at)))
  end
end

parallel.waitForAny(table.unpack(tasks))
