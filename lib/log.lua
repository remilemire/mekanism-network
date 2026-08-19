--[[ lib/log.lua -- leveled logger: colored terminal output + rotating file.

  local log = Log.new("router", { level = "debug" })
  log:info("claim %s created", id)

Options: level ("debug"|"info"|"warn"|"error"), file (path, or false to
disable file logging), max_bytes (rotation threshold).
]]

local class = require("lib.class")

local Log = class()

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local LEVEL_COLORS = {
  debug = colors.lightGray,
  info = colors.white,
  warn = colors.yellow,
  error = colors.red,
}

function Log:init(name, opts)
  opts = opts or {}
  self.name = name
  self.level = LEVELS[opts.level or "info"] or LEVELS.info
  self.file = opts.file
  if self.file == nil then self.file = "/data/logs/" .. name .. ".log" end
  self.max_bytes = opts.max_bytes or 64 * 1024
end

function Log:_emit(level, fmt, ...)
  if LEVELS[level] < self.level then return end

  local msg = fmt
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, fmt, ...)
    msg = ok and formatted or (tostring(fmt) .. " (bad log format)")
  end
  local line = ("%s [%s] %s: %s"):format(os.date("%H:%M:%S"), level:upper(), self.name, msg)

  local colored = term.isColor()
  if colored then term.setTextColor(LEVEL_COLORS[level]) end
  print(line)
  if colored then term.setTextColor(colors.white) end

  if self.file then
    -- Logging must never take the node down; swallow disk-full etc.
    pcall(function()
      local dir = fs.getDir(self.file)
      if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
      if fs.exists(self.file) and fs.getSize(self.file) > self.max_bytes then
        if fs.exists(self.file .. ".old") then fs.delete(self.file .. ".old") end
        fs.move(self.file, self.file .. ".old")
      end
      local f = fs.open(self.file, "a")
      f.writeLine(line)
      f.close()
    end)
  end
end

function Log:debug(...) self:_emit("debug", ...) end
function Log:info(...) self:_emit("info", ...) end
function Log:warn(...) self:_emit("warn", ...) end
function Log:error(...) self:_emit("error", ...) end

return Log
