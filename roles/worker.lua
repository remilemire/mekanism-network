--[[ roles/worker.lua -- a move executor.

Workers are pure software muscle on the shared wired network: the router
hands them delivery jobs ("move up to N of item X from chest A to chest B")
and they execute with pushItems. Run as many as you like -- each one adds a
parallel lane of item movement.

Idempotency: job results are PERSISTED by job id, and move.exec replays a
stored result instead of moving again. This store -- not the in-memory RPC
dedup cache -- is the backbone: it survives reboots and outlives the cache
TTL, which is exactly when the router asks "did you already do this?" via
job.result before daring to re-dispatch a job elsewhere.
]]

local class = require("lib.class")
local util = require("lib.util")
local Node = require("lib.net")
local JsonStore = require("lib.store")
local InventoryClient = require("lib.clients.inventory")

local Worker = class()

function Worker:init(config, log)
  assert(type(config.name) == "string", "worker config needs a unique 'name'")
  self.config = config
  self.log = log
  self.router = config.router_host or "router"
  self.node = Node.new({
    protocol = config.protocol,
    hostname = config.name,
    modem = config.modem,
    log = log,
  })
  self.results = JsonStore.new(config.data_dir or "/data/worker")
  self.jobs_done = 0
  self.last_job = nil
end

function Worker:setup()
  self.node:open()
  self.node:handle("move.exec", function(body, ctx) return self:_on_move(body, ctx) end)
  self.node:handle("job.result", function(body) return self:_on_job_result(body) end)
  self.node:handle("sys.status", function() return self:_status() end)
end

function Worker:_on_move(body, ctx)
  -- Replay first: a duplicate job id must never move items twice.
  local done = self.results:get(ctx.id)
  if done then return { moved = done.moved, replayed = true } end

  if type(body.from) ~= "string" or type(body.to) ~= "string"
      or type(body.item) ~= "string" then
    error({ code = "bad_request", message = "need from, to, item" })
  end
  local amount = math.floor(tonumber(body.amount) or 0)
  if amount <= 0 then
    error({ code = "bad_request", message = "amount must be positive" })
  end
  -- Wired-modem names renumber when modems are replaced; give the router a
  -- structured error it can hold-and-retry on instead of a crash.
  if not peripheral.isPresent(body.from) then
    error({ code = "chest_missing", message = body.from .. " is not on this network" })
  end
  if not peripheral.isPresent(body.to) then
    error({ code = "chest_missing", message = body.to .. " is not on this network" })
  end

  local moved = InventoryClient.new(body.from):push_item(body.to, body.item, amount)
  self.results:put(ctx.id, { moved = moved, at = util.now_ms() })
  self.jobs_done = self.jobs_done + 1
  self.last_job = { id = ctx.id, item = body.item, moved = moved, to = body.to }
  self.log:info("job %s: moved %d x %s  %s -> %s",
    tostring(ctx.id), moved, body.item, body.from, body.to)
  return { moved = moved }
end

function Worker:_on_job_result(body)
  local done = self.results:get(tostring(body.job_id or ""))
  if not done then
    error({ code = "not_found", message = "no result for that job" })
  end
  return { moved = done.moved, at = done.at }
end

function Worker:_status()
  return {
    role = "worker",
    name = self.config.name,
    id = os.getComputerID(),
    jobs_done = self.jobs_done,
    last_job = self.last_job,
  }
end

function Worker:tasks()
  local tasks = self.node:tasks()
  -- Heartbeat: registration is just the first heartbeat. The router drops
  -- workers that go silent, so this doubles as liveness.
  tasks[#tasks + 1] = function()
    while true do
      local ok, _, err = self.node:request(self.router, "worker.register",
        { name = self.config.name }, { retries = 1, timeout_s = 3 })
      if not ok then
        self.log:debug("router not answering registration (%s); will retry",
          err and err.code or "?")
      end
      sleep(self.config.heartbeat_s or 30)
    end
  end
  -- Result pruning: old job outcomes are only useful within the window the
  -- router might still ask about them.
  tasks[#tasks + 1] = function()
    while true do
      sleep(300)
      local ok, err = pcall(function()
        local cutoff = util.now_ms() - (self.config.result_retention_s or 3600) * 1000
        for _, id in ipairs(self.results:ids()) do
          local r = self.results:get(id)
          if not r or (r.at or 0) < cutoff then self.results:delete(id) end
        end
      end)
      if not ok then self.log:error("result pruning failed: %s", tostring(err)) end
    end
  end
  return tasks
end

return Worker
