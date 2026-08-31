--[[ main.lua -- mekanet entrypoint.

Every computer runs this on startup. It reads config.lua (which must sit
next to this file and return a table with at least a `role`), builds the
matching role, and supervises it: if the role crashes, it logs the error and
restarts after a short backoff. Ctrl+T terminates cleanly.
]]

local root = fs.getDir(shell.getRunningProgram())
local prefix = root == "" and "" or ("/" .. root)
package.path = prefix .. "/?.lua;" .. package.path

math.randomseed((os.epoch("utc") % 2 ^ 31) + os.getComputerID() * 7919)

local ROLE_MODULES = {
  sender = "roles.sender",
  service = "roles.service",
  router = "roles.router",
  worker = "roles.worker",
}

local config_path = fs.combine(root, "config.lua")
if not fs.exists(config_path) then
  printError("No config.lua found next to main.lua (/" .. config_path .. ")")
  printError("Copy an example from /" .. fs.combine(root, "examples") .. " and edit the device names.")
  printError("Run /" .. fs.combine(root, "tools/devices.lua") .. " to list attached peripherals.")
  return
end

local chunk, load_err = loadfile("/" .. config_path)
if not chunk then
  printError("config.lua does not parse: " .. tostring(load_err))
  return
end
local ok, config = pcall(chunk)
if not ok or type(config) ~= "table" then
  printError("config.lua must return a table: " .. tostring(config))
  return
end
if not ROLE_MODULES[config.role] then
  printError(("unknown role %q -- expected one of: sender, service, router, worker")
    :format(tostring(config.role)))
  return
end

local Log = require("lib.log")
local log = Log.new(config.name or config.role, config.log)

while true do
  local ran, err = pcall(function()
    local Role = require(ROLE_MODULES[config.role])
    local role = Role.new(config, log)
    role:setup()
    local tasks = role:tasks()
    log:info("running %s '%s' with %d tasks -- hold Ctrl+T to stop",
      config.role, config.name or "?", #tasks)
    parallel.waitForAll(table.unpack(tasks))
  end)

  if not ran then
    if tostring(err):find("Terminated") then
      log:info("terminated by user")
      return
    end
    log:error("crashed: %s", tostring(err))
  end

  local delay = config.restart_delay_s or 5
  log:warn("restarting in %ds (Ctrl+T to stop)", delay)
  local slept = pcall(sleep, delay)
  if not slept then return end -- terminated during the backoff
end
