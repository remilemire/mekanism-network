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

local node = Node.new({ client = true, log = Log.new("status", { level = "warn", file = false }) })
node:open()

-- Rendering ------------------------------------------------------------------

local ROLE_COLORS = { router = colors.lightBlue, service = colors.orange, sender = colors.lime }
local STATUS_COLORS = {
  created = colors.lightGray,
  in_transit = colors.yellow,
  arrived = colors.orange,
  delivering = colors.yellow,
  completed = colors.green,
  failed = colors.red,
  expired = colors.red,
}
local STATUS_ORDER = { "created", "in_transit", "arrived", "delivering", "completed", "failed", "expired" }

local term_w, term_h = term.getSize()
local printed = 0

local function pause_if_full(lines)
  printed = printed + lines
  if printed < term_h - 2 then return end
  if term.isColor() then term.setTextColor(colors.gray) end
  write("-- more --")
  os.pullEvent("key")
  local _, y = term.getCursorPos()
  term.setCursorPos(1, y)
  term.clearLine()
  printed = 0
end

--- line(color1, text1, color2, text2, ...) -- one colored line, with paging.
local function line(...)
  local segs = { ... }
  local len = 0
  for i = 1, #segs, 2 do
    if term.isColor() then term.setTextColor(segs[i]) end
    write(segs[i + 1])
    len = len + #segs[i + 1]
  end
  if term.isColor() then term.setTextColor(colors.white) end
  print()
  pause_if_full(math.max(1, math.ceil(len / term_w)))
end

--- "minecraft:iron_ingot" -> "iron_ingot" (ids are long; screens are 51 wide)
local function short_item(name)
  return (tostring(name):gsub("^.-:", ""))
end

--- "40 iron_ingot, 12 gold_ingot, +2 more" from an item -> count map.
local function fmt_counts(t, max_entries)
  max_entries = max_entries or 3
  local entries = {}
  for item, n in pairs(t or {}) do entries[#entries + 1] = { item = item, n = n } end
  if #entries == 0 then return "empty" end
  table.sort(entries, function(a, b) return a.n > b.n end)
  local parts = {}
  for i = 1, math.min(#entries, max_entries) do
    parts[#parts + 1] = entries[i].n .. " " .. short_item(entries[i].item)
  end
  if #entries > max_entries then
    parts[#parts + 1] = "+" .. (#entries - max_entries) .. " more"
  end
  return table.concat(parts, ", ")
end

local function count_keys(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local function render_router(body)
  local segs = { colors.gray, "  claims: " }
  local any = false
  for _, s in ipairs(STATUS_ORDER) do
    local n = body.claims and body.claims[s]
    if n and n > 0 then
      any = true
      segs[#segs + 1] = STATUS_COLORS[s]
      segs[#segs + 1] = n .. " " .. s .. "  "
    end
  end
  if not any then
    segs[#segs + 1] = colors.lightGray
    segs[#segs + 1] = "none"
  end
  line(table.unpack(segs))

  local locked, total = 0, #(body.ports or {})
  for _, port in ipairs(body.ports or {}) do
    if port.claim and port.claim ~= "free" then locked = locked + 1 end
  end
  line(colors.gray, "  ports:  ", locked > 0 and colors.yellow or colors.white,
    ("%d/%d locked"):format(locked, total))
  line(colors.gray, "  intake: ", colors.white, fmt_counts(body.intake))
end

local function render_service(body)
  line(colors.gray, "  recipes: ", colors.white, tostring(count_keys(body.recipes)),
    colors.gray, "   handled: ", colors.white, tostring(body.requests_handled or 0))
  line(colors.gray, "  ship to: ", colors.white, tostring(body.input_frequency))
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
  if body.receiving then
    line(colors.gray, "  incoming: ", colors.orange, ("%d %s (%s)"):format(
      body.receiving.amount or 0, short_item(body.receiving.item), body.receiving.claim or "?"))
  end
  line(colors.gray, "  buffer: ", colors.white, fmt_counts(body.input_buffer))
  if count_keys(body.inbox_buffer) > 0 then
    line(colors.gray, "  inbox:  ", colors.yellow, fmt_counts(body.inbox_buffer))
  end
end

local RENDERERS = { router = render_router, service = render_service, sender = render_sender }

local function render_node(id, body)
  if not body then
    line(colors.red, ("== #%d  (no response)"):format(id))
    return
  end
  local role = tostring(body.role or "?")
  line(ROLE_COLORS[role] or colors.white, ("== #%d %s "):format(id, body.name or "?"),
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
