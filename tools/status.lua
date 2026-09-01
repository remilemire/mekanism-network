--[[ tools/status.lua -- compact, color-coded status of every mekanet node.

  tools/status.lua       -- summary view
  tools/status.lua -v    -- full raw dump of every sys.status payload
]]

local args = { ... }
local verbose = args[1] == "-v" or args[1] == "--verbose"

local here = fs.getDir(shell.getRunningProgram())
local root = fs.getDir(here)
local prefix = root == "" and "" or ("/" .. root)
package.path = prefix .. "/?.lua;" .. package.path

local Node = require("lib.net")
local Log = require("lib.log")
local render = require("lib.render")

local line, fmt_counts, short_item = render.line, render.fmt_counts, render.short_item

local node = Node.new({ client = true, log = Log.new("status", { level = "warn", file = false }) })
node:open()

-- Per-role renderers ----------------------------------------------------------

local function count_keys(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local function render_router(body)
  local segs = { colors.gray, "  claims: " }
  local any = false
  for _, s in ipairs(render.STATUS_ORDER) do
    local n = body.claims and body.claims[s]
    if n and n > 0 then
      any = true
      segs[#segs + 1] = render.status_color(s)
      segs[#segs + 1] = n .. " " .. s .. "  "
    end
  end
  if not any then
    segs[#segs + 1] = colors.lightGray
    segs[#segs + 1] = "none"
  end
  line(table.unpack(segs))

  local parts = {}
  for service, n in pairs(body.services or {}) do
    parts[#parts + 1] = service .. ": " .. n
  end
  table.sort(parts)
  line(colors.gray, "  queues: ", #parts > 0 and colors.white or colors.lightGray,
    #parts == 0 and "empty" or table.concat(parts, ", "))
end

local function render_service(body)
  line(colors.gray, "  recipes: ", colors.white, tostring(count_keys(body.recipes)),
    colors.gray, "   handled: ", colors.white, tostring(body.requests_handled or 0))
  line(colors.gray, "  output: ", colors.white, fmt_counts(body.output))
end


local function render_sender(body)
  local per_item = {}
  for _, item in pairs(body.active_orders or {}) do
    per_item[item] = (per_item[item] or 0) + 1
  end
  local parts = {}
  for item, n in pairs(per_item) do parts[#parts + 1] = n .. "x " .. short_item(item) end
  line(colors.gray, "  orders: ", #parts > 0 and colors.yellow or colors.lightGray,
    #parts == 0 and "none" or table.concat(parts, ", "))
  line(colors.gray, "  buffer: ", colors.white, fmt_counts(body.input_buffer))
  if count_keys(body.outbox) > 0 then
    line(colors.gray, "  outbox: ", colors.yellow, fmt_counts(body.outbox))
  end
  if count_keys(body.inbox_buffer) > 0 then
    line(colors.gray, "  inbox:  ", colors.yellow, fmt_counts(body.inbox_buffer))
  end
end

local RENDERERS = {
  router = render_router,
  service = render_service,
  sender = render_sender,
}

local function render_node(id, body)
  if not body then
    line(colors.red, ("== #%d  (no response)"):format(id))
    return
  end
  local role = tostring(body.role or "?")
  line(render.ROLE_COLORS[role] or colors.white, ("== #%d %s "):format(id, body.name or "?"),
    colors.gray, "(" .. role .. ")")
  local renderer = RENDERERS[role]
  if renderer then renderer(body) else line(colors.lightGray, "  (nothing to show)") end
end

-- Main -----------------------------------------------------------------------

local tasks = node:tasks()
tasks[#tasks + 1] = function()
  local ids = { rednet.lookup(node.protocol) }
  if #ids == 0 then
    print("no mekanet nodes found -- are the other computers running main.lua?")
    return
  end
  table.sort(ids)

  if verbose then
    local out = {}
    for _, id in ipairs(ids) do
      local ok, body = node:request(id, "sys.status", {}, { retries = 1, timeout_s = 2 })
      if ok then
        out[#out + 1] = ("== #%d  %s (%s)"):format(id, body.name or "?", body.role or "?")
        out[#out + 1] = textutils.serialize(body)
      else
        out[#out + 1] = ("== #%d  (no response)"):format(id)
      end
    end
    textutils.pagedPrint(table.concat(out, "\n"))
    return
  end

  line(colors.white, "mekanet status ", colors.gray, "(" .. node.protocol .. ", -v for raw)")
  for _, id in ipairs(ids) do
    local ok, body = node:request(id, "sys.status", {}, { retries = 1, timeout_s = 2 })
    render_node(id, ok and body or nil)
  end
end

parallel.waitForAny(table.unpack(tasks))
