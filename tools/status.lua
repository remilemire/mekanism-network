--[[ tools/status.lua — ping every mekanet node and print its sys.status.
Run from any computer on the network with a modem:  tools/status.lua ]]

local here = fs.getDir(shell.getRunningProgram())
local root = fs.getDir(here)
local prefix = root == "" and "" or ("/" .. root)
package.path = prefix .. "/?.lua;" .. package.path

local Node = require("lib.net")
local Log = require("lib.log")

local node = Node.new({ log = Log.new("status", { level = "warn", file = false }) })
node:open()

local tasks = node:tasks()
tasks[#tasks + 1] = function()
  print("mekanet nodes on protocol '" .. node.protocol .. "':")
  local ids = { rednet.lookup(node.protocol) }
  if #ids == 0 then
    print("  (none found — are the other computers running main.lua?)")
    return
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local ok, body = node:request(id, "sys.status", {}, { retries = 1, timeout_s = 2 })
    if ok then
      print(("== #%d  %s (%s)"):format(id, body.name or "?", body.role or "?"))
      print(textutils.serialize(body))
    else
      print(("== #%d  (no response)"):format(id))
    end
  end
end

-- waitForAny: exits as soon as the query task above returns.
parallel.waitForAny(table.unpack(tasks))
