--[[ lib/util.lua -- small shared helpers. ]]

local util = {}

--- Milliseconds since epoch (consistent across computers in the same world).
function util.now_ms()
  return os.epoch("utc")
end

local counter = 0

--- Unique-enough id: timestamp + computer id + monotonic counter + noise.
--- Collisions would require two ids minted on the same computer in the same
--- millisecond with the same counter value, which the counter prevents.
function util.uuid()
  counter = (counter + 1) % 0x10000
  return string.format("%x-%x-%x-%x",
    os.epoch("utc"), os.getComputerID(), counter, math.random(0, 0xFFFF))
end

--- First 8 chars of an id, for logs.
function util.short_id(id)
  return tostring(id):sub(1, 8)
end

--- "42s", "3m07s", "1h04m" from a millisecond duration.
function util.fmt_age(ms)
  local s = math.floor((ms or 0) / 1000)
  if s < 60 then return s .. "s" end
  local m = math.floor(s / 60)
  if m < 60 then return string.format("%dm%02ds", m, s % 60) end
  return string.format("%dh%02dm", math.floor(m / 60), m % 60)
end

function util.shallow_copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

--- A fixed-rate task for parallel.waitForAll: runs fn every interval_s
--- seconds measured start-to-start, so the work itself never stretches the
--- period (sleeping AFTER the work would make a 2s poll with 1s of work a
--- 3s poll). An overrun simply starts the next run right away, with a
--- debug line saying so; errors are logged and never take the node down.
function util.every(name, interval_s, fn, log)
  return function()
    while true do
      local started = os.clock()
      local ok, err = pcall(fn)
      if not ok and log then log:error("%s failed: %s", name, tostring(err)) end
      local took = os.clock() - started
      if took > interval_s and log then
        log:debug("%s ran %.1fs, longer than its %ss interval", name, took, tostring(interval_s))
      end
      sleep(math.max(0.05, interval_s - took))
    end
  end
end

--- Invert a service -> {items} routes table into item -> service, refusing
--- ambiguity: every item may be routed to exactly one service.
function util.invert_routes(routes)
  local by_item = {}
  for service, items in pairs(routes or {}) do
    if type(items) ~= "table" then
      error(("routes[%q] must be a list of item names"):format(tostring(service)), 0)
    end
    for _, item in ipairs(items) do
      if by_item[item] == service then
        error(("item %s appears twice in the routes for %s"):format(item, service), 0)
      elseif by_item[item] then
        error(("item %s is routed to both %s and %s -- each item may have exactly one service")
          :format(item, by_item[item], service), 0)
      end
      by_item[item] = service
    end
  end
  return by_item
end

--- Wrap a peripheral or die with a message that lists what IS attached,
--- so a typo in config.lua is a ten-second fix instead of a mystery.
function util.require_peripheral(name, why)
  if type(name) ~= "string" then
    error(("config is missing a device name for %s"):format(why or "a peripheral"), 0)
  end
  local dev = peripheral.wrap(name)
  if not dev then
    error(("peripheral %q (%s) not found; attached: %s")
      :format(name, why or "device", table.concat(peripheral.getNames(), ", ")), 0)
  end
  return dev
end

return util
