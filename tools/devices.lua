--[[ tools/devices.lua -- list attached peripherals and their types.
Use these exact names in config.lua. ]]

local names = peripheral.getNames()
if #names == 0 then
  print("No peripherals attached.")
  return
end
for _, name in ipairs(names) do
  print(("%-38s %s"):format(name, table.concat({ peripheral.getType(name) }, ", ")))
end
