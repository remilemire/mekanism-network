--[[ tools/status.lua -- ping every mekanet node and print its sys.status.
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
  -- Collect everything first, then page it: a router status alone can be
  -- several screens on a CC terminal.
  local out = { "mekanet nodes on protocol '" .. node.protocol .. "':" }
  local ids = { rednet.lookup(node.protocol) }
  if #ids == 0 then
    out[#out + 1] = "  (none found -- are the other computers running main.lua?)"
  else
    table.sort(ids)
    for _, id in ipairs(ids) do
      local ok, body = node:request(id, "sys.status", {}, { retries = 1, timeout_s = 2 })
      if ok then
        out[#out + 1] = ("== #%d  %s (%s)"):format(id, body.name or "?", body.role or "?")
        out[#out + 1] = textutils.serialize(body)
      else
        out[#out + 1] = ("== #%d  (no response)"):format(id)
      end
    end
  end
  textutils.pagedPrint(table.concat(out, "\n"))
end

-- waitForAny: exits as soon as the query task above returns.
parallel.waitForAny(table.unpack(tasks))
