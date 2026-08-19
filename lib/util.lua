--[[ lib/util.lua — small shared helpers. ]]

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
