--[[ lib/store.lua -- JsonStore: one JSON file per record in a directory.

Writes go through a .tmp file and an fs.move so a reboot mid-write leaves
either the old record or the new one, never a half-written file.
]]

local class = require("lib.class")

local JsonStore = class()

function JsonStore:init(dir)
  self.dir = dir
  if not fs.exists(dir) then fs.makeDir(dir) end
end

function JsonStore:path(id)
  return fs.combine(self.dir, id .. ".json")
end

function JsonStore:put(id, value)
  local target = self:path(id)
  local tmp = target .. ".tmp"
  local f = fs.open(tmp, "w")
  f.write(textutils.serializeJSON(value))
  f.close()
  if fs.exists(target) then fs.delete(target) end
  fs.move(tmp, target)
end

function JsonStore:get(id)
  local target = self:path(id)
  if not fs.exists(target) then return nil end
  local f = fs.open(target, "r")
  local raw = f.readAll()
  f.close()
  return textutils.unserializeJSON(raw)
end

function JsonStore:delete(id)
  local target = self:path(id)
  if fs.exists(target) then fs.delete(target) end
end

function JsonStore:ids()
  local out = {}
  for _, name in ipairs(fs.list(self.dir)) do
    local full = fs.combine(self.dir, name)
    if not fs.isDir(full) and name:sub(-5) == ".json" then
      out[#out + 1] = name:sub(1, -6)
    end
  end
  return out
end

--- Load every record: map of id -> value. Corrupt files are skipped (and
--- reported via the optional log) rather than taking the whole node down.
function JsonStore:all(log)
  local out = {}
  for _, id in ipairs(self:ids()) do
    local ok, value = pcall(function() return self:get(id) end)
    if ok and value ~= nil then
      out[id] = value
    elseif log then
      log:warn("store %s: skipping unreadable record %s", self.dir, id)
    end
  end
  return out
end

return JsonStore
