--[[ lib/dashboard.lua -- the shared monitor dashboard for roles.

A role hands over its `monitor` config block and a function that builds
rows for a w x h screen; the dashboard owns the MonitorView, the refresh
loop, the spinner, and the throttled missing/back warnings. The header and
layout helpers keep every role's screen consistent:

  title (yellow) ................... marker (spinner / PAUSED)
  description (optional, gray)
  ---------------------------------------------------------
  <role-specific label + body rows, capped with "+N more">
  <footer rows>

Config: { device, title, description, scale, refresh_s }.
]]

local class = require("lib.class")
local MonitorView = require("lib.monitor")

local SPINNER = { "|", "/", "-", "\\" }

local Dashboard = class()

--- opts: { config = <monitor config>, log = <Log>, rows = function(w, h) }
function Dashboard:init(opts)
  assert(type(opts.config) == "table" and type(opts.config.device) == "string",
    "dashboard needs a monitor config with a device")
  self.config = opts.config
  self.log = opts.log
  self.rows_fn = opts.rows
  self.view = MonitorView.new(opts.config.device, { scale = opts.config.scale })
  self.spinner = 0
end

--- Advance and return the spinner frame (call once per frame while busy).
function Dashboard:spin()
  self.spinner = (self.spinner % #SPINNER) + 1
  return SPINNER[self.spinner]
end

--- Header rows: title with a right-aligned marker, the optional
--- description, and a rule.
function Dashboard:header(w, title, marker, marker_color)
  marker = marker or ""
  title = tostring(title):sub(1, math.max(1, w - #marker - 1))
  local rows = {
    { colors.yellow, title,
      colors.white, string.rep(" ", math.max(1, w - #title - #marker)),
      marker_color or colors.white, marker },
  }
  local desc = self.config.description
  if desc and #tostring(desc) > 0 then
    rows[#rows + 1] = { colors.lightGray, tostring(desc) }
  end
  rows[#rows + 1] = { colors.gray, string.rep("-", w) }
  return rows
end

--- Assemble header + body + footer for a screen h rows tall. The footer
--- keeps its place (dropping trailing rows only on tiny screens); the body
--- gets whatever is left, ending in "+N more" when it doesn't all fit.
function Dashboard.layout(h, header, body, footer, empty_text)
  local foot = {}
  for i, row in ipairs(footer or {}) do foot[i] = row end
  while #foot > 0 and h - #header - #foot < 1 do table.remove(foot) end

  local rows = {}
  for _, row in ipairs(header) do rows[#rows + 1] = row end
  local budget = h - #header - #foot
  if #body == 0 then
    if budget >= 1 and empty_text then rows[#rows + 1] = { colors.gray, empty_text } end
  elseif budget >= 1 then
    -- Overflow: keep one row for the "+N more" tail, but never let the tail
    -- crowd out the last real row on a tiny screen.
    local shown = #body <= budget and #body or math.max(1, budget - 1)
    for i = 1, shown do rows[#rows + 1] = body[i] end
    if shown < #body and shown < budget then
      rows[#rows + 1] = { colors.gray, ("  +%d more"):format(#body - shown) }
    end
  end
  for _, row in ipairs(foot) do rows[#rows + 1] = row end
  return rows
end

function Dashboard:_warn(fmt, ...)
  if (os.epoch("utc") - (self.warn_at or 0)) > 60000 then
    self.warn_at = os.epoch("utc")
    self.warned = true
    self.log:warn(fmt, ...)
  end
end

--- The refresh loop, ready to hand to parallel.waitForAll.
function Dashboard:task()
  return function()
    while true do
      local available = false
      local ok, err = pcall(function()
        local w, h = self.view:size()
        if not w then return end
        available = self.view:draw(self.rows_fn(w, h))
      end)
      if not ok then
        self:_warn("monitor draw failed: %s", tostring(err))
      elseif not available then
        self:_warn("monitor '%s' not found; will keep trying", tostring(self.config.device))
      elseif self.warned then
        self.warned = nil
        self.log:info("monitor '%s' is back", tostring(self.config.device))
      end
      sleep(available and (self.config.refresh_s or 1) or 30)
    end
  end
end

return Dashboard
