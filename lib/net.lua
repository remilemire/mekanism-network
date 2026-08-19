--[[ lib/net.lua -- rednet RPC node.

One Node per computer. Design goals:

  * A single coroutine owns rednet.receive, so role code never fights over
    modem events. Requests made from other coroutines wait on a custom
    "mekanet:res" event queued by that loop.
  * At-least-once delivery with idempotent handling: a request keeps its id
    across retries. The server caches responses by request id ("seen" cache)
    and replays them when the response was lost, and drops duplicates that
    arrive while the original is still being handled.
  * Handlers run on a worker coroutine, one at a time, so a handler may
    itself call node:request() (e.g. the crushing service calling the
    router) without deadlocking the receive loop.

Envelope format (v1):
  { v=1, kind="req", id=<uuid>, method="claim.create", body={...}, from=<id> }
  { v=1, kind="res", id=<uuid>, ok=true,  body={...}, from=<id> }
  { v=1, kind="res", id=<uuid>, ok=false, err={code=..., message=...}, from=<id> }

Handlers: function(body, ctx) -> response body table. Raise error({code=...})
for a structured failure; string errors become {code="handler_error"}.
]]

local class = require("lib.class")
local util = require("lib.util")

local EV_RES = "mekanet:res"
local EV_JOB = "mekanet:job"

local Node = class()

function Node:init(opts)
  opts = opts or {}
  self.protocol = opts.protocol or "mekanet"
  self.hostname = opts.hostname
  self.modem_name = opts.modem
  self.log = opts.log
  self.request_timeout_s = opts.request_timeout_s or 3
  self.request_retries = opts.request_retries or 4
  self.seen_ttl_ms = (opts.seen_ttl_s or 300) * 1000

  self.handlers = {}
  self.queue = {}        -- inbound requests waiting for the worker
  self.responses = {}    -- response envelopes keyed by request id
  self.seen = {}         -- request id -> {status="pending"|"done", res, at}
  self.lookup_cache = {} -- hostname -> computer id

  self:handle("sys.ping", function()
    return { pong = true, id = os.getComputerID(), hostname = self.hostname }
  end)
  self:handle("sys.status", function()
    return { role = "unknown", id = os.getComputerID(), hostname = self.hostname }
  end)
end

function Node:open()
  local modem
  if self.modem_name then
    modem = peripheral.wrap(self.modem_name)
    if not modem then
      error(("modem %q not found; attached: %s")
        :format(self.modem_name, table.concat(peripheral.getNames(), ", ")), 0)
    end
  else
    modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
        or peripheral.find("modem")
    if not modem then
      error("no modem attached -- this computer needs a (preferably wireless) modem", 0)
    end
  end

  local side = peripheral.getName(modem)
  if not rednet.isOpen(side) then rednet.open(side) end

  if self.hostname then
    local ok, err = pcall(rednet.host, self.protocol, self.hostname)
    if not ok then
      error(("cannot claim hostname %q on protocol %q (already taken by another computer?): %s")
        :format(self.hostname, self.protocol, tostring(err)), 0)
    end
  end

  if self.log then
    self.log:info("rednet up on %s as #%d (%s / %s)",
      side, os.getComputerID(), self.hostname or "anonymous", self.protocol)
  end
end

function Node:handle(method, fn)
  self.handlers[method] = fn
end

--- Resolve a target to a computer id. Numbers pass through; hostnames are
--- looked up over rednet and cached until a request to them times out.
function Node:resolve(target)
  if type(target) == "number" then return target end
  local cached = self.lookup_cache[target]
  if cached then return cached end
  local id = rednet.lookup(self.protocol, target)
  if id then self.lookup_cache[target] = id end
  return id
end

--- Send a request and wait for the matching response.
--- Retries reuse the same request id, so the far side can deduplicate and
--- replay. Returns (true, body) or (false, nil, err) with err.code set.
function Node:request(target, method, body, opts)
  opts = opts or {}
  local timeout_s = opts.timeout_s or self.request_timeout_s
  local retries = opts.retries
  if retries == nil then retries = self.request_retries end

  local id = util.uuid()
  local env = {
    v = 1, kind = "req", id = id, method = method,
    body = body or {}, from = os.getComputerID(),
  }

  for attempt = 1, retries + 1 do
    local dest = self:resolve(target)
    if dest then
      rednet.send(dest, env, self.protocol)
      local timer = os.startTimer(timeout_s)
      while true do
        local ev, p1 = os.pullEvent()
        if ev == EV_RES and p1 == id then
          os.cancelTimer(timer)
          local res = self.responses[id]
          self.responses[id] = nil
          if res and res.ok then return true, res.body or {} end
          return false, nil, (res and res.err) or { code = "error" }
        elseif ev == "timer" and p1 == timer then
          break -- this attempt timed out; fall through to retry
        end
      end
    end
    -- A stale hostname mapping is one reason for silence; re-look it up.
    if type(target) == "string" then self.lookup_cache[target] = nil end
    if attempt <= retries then sleep(math.min(0.5 * attempt, 2)) end
  end

  return false, nil, {
    code = "timeout",
    message = ("%s to %s got no response"):format(method, tostring(target)),
  }
end

function Node:_net_loop()
  while true do
    local from, msg = rednet.receive(self.protocol)
    if type(msg) == "table" and msg.v == 1 and type(msg.id) == "string" then
      if msg.kind == "req" then
        local seen = self.seen[msg.id]
        if not seen then
          self.seen[msg.id] = { status = "pending", at = util.now_ms() }
          self.queue[#self.queue + 1] = { from = from, env = msg }
          os.queueEvent(EV_JOB)
        elseif seen.status == "done" then
          -- The response was lost in transit; replay the cached one.
          rednet.send(from, seen.res, self.protocol)
        end
        -- status "pending": duplicate while the handler runs -- drop it, the
        -- client keeps retrying and will hit the cache once we finish.
      elseif msg.kind == "res" then
        self.responses[msg.id] = msg
        os.queueEvent(EV_RES, msg.id)
      end
    end
  end
end

function Node:_worker_loop()
  while true do
    -- Cooperative scheduling: nothing can enqueue between this check and the
    -- pullEvent, because the net loop only runs while we are yielded.
    if #self.queue == 0 then os.pullEvent(EV_JOB) end
    local job = table.remove(self.queue, 1)
    if job then
      local env = job.env
      local res = { v = 1, kind = "res", id = env.id, from = os.getComputerID() }
      local handler = self.handlers[env.method]
      if not handler then
        res.ok, res.err = false, { code = "unknown_method", message = env.method }
      else
        local ok, out = pcall(handler, env.body or {}, {
          from = job.from, method = env.method, id = env.id,
        })
        if ok then
          res.ok, res.body = true, out or {}
        else
          res.ok = false
          if type(out) == "table" then
            res.err = out
          else
            res.err = { code = "handler_error", message = tostring(out) }
          end
          if self.log and res.err.code ~= "busy" then
            self.log:warn("handler %s failed: %s",
              env.method, res.err.message or res.err.code)
          end
        end
      end
      self.seen[env.id] = { status = "done", res = res, at = util.now_ms() }
      rednet.send(job.from, res, self.protocol)
    end
  end
end

function Node:_janitor_loop()
  while true do
    sleep(30)
    local cutoff = util.now_ms() - self.seen_ttl_ms
    local stale = {}
    for id, entry in pairs(self.seen) do
      if entry.at < cutoff then stale[#stale + 1] = id end
    end
    for _, id in ipairs(stale) do self.seen[id] = nil end
  end
end

--- The coroutines this node needs. Roles append their own loops and hand
--- the whole set to parallel.waitForAll.
function Node:tasks()
  return {
    function() self:_net_loop() end,
    function() self:_worker_loop() end,
    function() self:_janitor_loop() end,
  }
end

return Node
