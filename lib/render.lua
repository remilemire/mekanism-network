--[[ lib/render.lua -- shared terminal rendering for the tools.

Colored segment lines with keypress paging, plus the small formatters every
tool wants. Colors degrade to plain text on non-color terminals.
]]

local render = {}

render.STATUS_COLORS = {
  created = colors.lightGray,
  in_transit = colors.yellow,
  arrived = colors.orange,
  delivering = colors.yellow,
  completed = colors.green,
  failed = colors.red,
  expired = colors.red,
}
render.STATUS_ORDER = { "created", "in_transit", "arrived", "delivering", "completed", "failed", "expired" }
render.ROLE_COLORS = {
  router = colors.lightBlue,
  service = colors.orange,
  sender = colors.lime,
  worker = colors.cyan,
}

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

--- render.line(color1, text1, color2, text2, ...) -- one colored line,
--- pausing on a full screen so nothing scrolls away.
function render.line(...)
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
function render.short_item(name)
  return (tostring(name):gsub("^.-:", ""))
end

--- "40 iron_ingot, 12 gold_ingot, +2 more" from an item -> count map.
function render.fmt_counts(t, max_entries)
  max_entries = max_entries or 3
  local entries = {}
  for item, n in pairs(t or {}) do entries[#entries + 1] = { item = item, n = n } end
  if #entries == 0 then return "empty" end
  table.sort(entries, function(a, b) return a.n > b.n end)
  local parts = {}
  for i = 1, math.min(#entries, max_entries) do
    parts[#parts + 1] = entries[i].n .. " " .. render.short_item(entries[i].item)
  end
  if #entries > max_entries then
    parts[#parts + 1] = "+" .. (#entries - max_entries) .. " more"
  end
  return table.concat(parts, ", ")
end

function render.status_color(status)
  return render.STATUS_COLORS[status] or colors.white
end

return render
