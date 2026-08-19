--[[ lib/class.lua -- minimal single-inheritance class helper.

  local MyClass = class()
  function MyClass:init(a, b) ... end
  local obj = MyClass.new(1, 2)
]]

local function class(parent)
  local cls = {}
  cls.__index = cls
  if parent then setmetatable(cls, { __index = parent }) end

  cls.new = function(...)
    local self = setmetatable({}, cls)
    if self.init then self:init(...) end
    return self
  end

  return cls
end

return class
