--[[ tools/devices.lua -- list attached peripherals and their types, colored
by kind. Use these exact names in config.lua. ]]

local here = fs.getDir(shell.getRunningProgram())
local root = fs.getDir(here)
local prefix = root == "" and "" or ("/" .. root)
package.path = prefix .. "/?.lua;" .. package.path

local render = require("lib.render")

local names = peripheral.getNames()
if #names == 0 then
  print("No peripherals attached.")
  return
end
table.sort(names)

local function kind_color(name, types)
  local haystack = (name .. " " .. types):lower()
  if haystack:find("entangloporter") then return colors.orange end
  if types:find("modem") then return colors.lightBlue end
  if types:find("inventory") then return colors.lime end
  if haystack:find("computer") or haystack:find("turtle") then return colors.yellow end
  return colors.white
end

render.line(colors.white, "attached peripherals ", colors.gray, "(" .. #names .. ")")
for _, name in ipairs(names) do
  local types = table.concat({ peripheral.getType(name) }, ", ")
  render.line(kind_color(name, types), name, colors.gray, "  " .. types)
end
