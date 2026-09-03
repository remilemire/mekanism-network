--[[ lib/monitor.lua -- MonitorView: draw colored rows on a CC monitor.

A monitor exposes the same API as `term`, so the view writes directly on
the wrapped peripheral object -- never term.redirect -- which keeps the
computer's own terminal (and its log output) untouched. Layout adapts to
whatever monitor is attached: rows truncate to the width, and callers ask
`size()` to budget their rows. The monitor is optional hardware: attach
failures return false instead of raising, so a role keeps running
without it and can retry later.

Rows use the same segment convention as lib/render.line:
  { color1, "text1", color2, "text2", ... }
A color may also be a table { fg = ..., bg = ... } to paint the background
(that is how solid pixels are drawn -- CC's block glyph is a dither).
]]

local class = require("lib.class")

local MonitorView = class()

function MonitorView:init(device_name, opts)
  opts = opts or {}
  self.device_name = device_name
  self.scale = opts.scale or 0.5
  self.mon = nil
end

--- Wrap (or re-wrap after a detach) the peripheral. Returns true when usable.
function MonitorView:_attach()
  if self.mon then
    if pcall(self.mon.getSize) then return true end
    self.mon = nil -- detached; fall through and try to re-wrap
  end
  local mon = peripheral.wrap(self.device_name)
  if not mon or type(mon.setTextScale) ~= "function" then return false end
  local ok = pcall(function()
    mon.setTextScale(self.scale)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
  end)
  if not ok then return false end
  self.mon = mon
  return true
end

--- Width and height in characters, or nil when the monitor is unavailable.
function MonitorView:size()
  if not self:_attach() then return nil end
  local ok, w, h = pcall(self.mon.getSize)
  if not ok then
    self.mon = nil
    return nil
  end
  return w, h
end

--- Clear the monitor and draw `rows` top to bottom, truncating each row to
--- the width and dropping rows past the bottom. Returns false (never
--- raises) when the monitor is unavailable.
function MonitorView:draw(rows)
  if not self:_attach() then return false end
  local mon = self.mon
  local ok = pcall(function()
    local w, h = mon.getSize()
    local color = mon.isColor()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    for y = 1, math.min(#rows, h) do
      mon.setCursorPos(1, y)
      local remaining = w
      local segs = rows[y]
      for i = 1, #segs, 2 do
        if remaining <= 0 then break end
        local text = tostring(segs[i + 1] or "")
        if #text > remaining then text = text:sub(1, remaining) end
        local spec = segs[i]
        local fg, bg = spec, colors.black
        if type(spec) == "table" then
          fg, bg = spec.fg or colors.white, spec.bg or colors.black
        end
        if color then
          mon.setTextColor(fg or colors.white)
          mon.setBackgroundColor(bg)
        else
          -- Basic monitors only accept black/white/grays.
          mon.setBackgroundColor(bg == colors.black and colors.black or colors.white)
        end
        mon.write(text)
        remaining = remaining - #text
      end
    end
    mon.setBackgroundColor(colors.black)
    if color then mon.setTextColor(colors.white) end
  end)
  if not ok then
    self.mon = nil
    return false
  end
  return true
end

-- Big titles ------------------------------------------------------------------

-- A 3x5 block font: five rows per glyph, "#" = pixel. Monitors have one
-- text scale for the whole screen, so this is how a title gets "bigger".
local FONT = {
  A = { ".#.", "#.#", "###", "#.#", "#.#" }, B = { "##.", "#.#", "##.", "#.#", "##." },
  C = { ".##", "#..", "#..", "#..", ".##" }, D = { "##.", "#.#", "#.#", "#.#", "##." },
  E = { "###", "#..", "##.", "#..", "###" }, F = { "###", "#..", "##.", "#..", "#.." },
  G = { ".##", "#..", "#.#", "#.#", ".##" }, H = { "#.#", "#.#", "###", "#.#", "#.#" },
  I = { "###", ".#.", ".#.", ".#.", "###" }, J = { "..#", "..#", "..#", "#.#", ".#." },
  K = { "#.#", "#.#", "##.", "#.#", "#.#" }, L = { "#..", "#..", "#..", "#..", "###" },
  M = { "#.#", "###", "###", "#.#", "#.#" }, N = { "##.", "#.#", "#.#", "#.#", "#.#" },
  O = { ".#.", "#.#", "#.#", "#.#", ".#." }, P = { "##.", "#.#", "##.", "#..", "#.." },
  Q = { ".#.", "#.#", "#.#", "###", ".##" }, R = { "##.", "#.#", "##.", "#.#", "#.#" },
  S = { ".##", "#..", ".#.", "..#", "##." }, T = { "###", ".#.", ".#.", ".#.", ".#." },
  U = { "#.#", "#.#", "#.#", "#.#", "###" }, V = { "#.#", "#.#", "#.#", "#.#", ".#." },
  W = { "#.#", "#.#", "###", "###", "#.#" }, X = { "#.#", "#.#", ".#.", "#.#", "#.#" },
  Y = { "#.#", "#.#", ".#.", ".#.", ".#." }, Z = { "###", "..#", ".#.", "#..", "###" },
  ["0"] = { "###", "#.#", "#.#", "#.#", "###" }, ["1"] = { ".#.", "##.", ".#.", ".#.", "###" },
  ["2"] = { "##.", "..#", ".#.", "#..", "###" }, ["3"] = { "###", "..#", ".##", "..#", "###" },
  ["4"] = { "#.#", "#.#", "###", "..#", "..#" }, ["5"] = { "###", "#..", "##.", "..#", "##." },
  ["6"] = { ".##", "#..", "###", "#.#", "###" }, ["7"] = { "###", "..#", ".#.", ".#.", ".#." },
  ["8"] = { "###", "#.#", "###", "#.#", "###" }, ["9"] = { "###", "#.#", "###", "..#", "##." },
  [" "] = { "...", "...", "...", "...", "..." }, ["-"] = { "...", "...", "###", "...", "..." },
  ["."] = { "...", "...", "...", "...", ".#." }, ["!"] = { ".#.", ".#.", ".#.", "...", ".#." },
  [":"] = { "...", ".#.", "...", ".#.", "..." }, ["/"] = { "..#", "..#", ".#.", "#..", "#.." },
  ["'"] = { ".#.", ".#.", "...", "...", "..." }, ["&"] = { ".#.", "#.#", ".#.", "#.#", ".##" },
}
local BLANK = { "...", "...", "...", "...", "..." }

--- Render `text` as 5 rows of block letters (4 columns per character),
--- painting lit pixels as `color` backgrounds, or nil when it would not
--- fit in `width`. Lowercase is folded to uppercase; unknown characters
--- render blank.
function MonitorView.big_rows(text, color, width)
  text = tostring(text):upper()
  if #text * 4 - 1 > width then return nil end
  local rows = {}
  for r = 1, 5 do
    local bits = {}
    for i = 1, #text do
      bits[#bits + 1] = (FONT[text:sub(i, i)] or BLANK)[r]
    end
    local line = table.concat(bits, ".") -- one blank column between letters
    -- Run-length encode into segments: lit runs paint the background.
    local segs = {}
    local pos = 1
    while pos <= #line do
      local ch = line:sub(pos, pos)
      local stop = pos
      while stop <= #line and line:sub(stop, stop) == ch do stop = stop + 1 end
      segs[#segs + 1] = (ch == "#") and { bg = color } or colors.white
      segs[#segs + 1] = string.rep(" ", stop - pos)
      pos = stop
    end
    rows[r] = segs
  end
  return rows
end

return MonitorView
