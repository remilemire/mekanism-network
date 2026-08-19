--[[ startup.lua — boot shim. Place at the computer root; it finds main.lua
whether the repo was copied to / or to /mekanet. ]]

local candidates = { "/mekanet/main.lua", "/main.lua" }
for _, path in ipairs(candidates) do
  if fs.exists(path) then
    return shell.run(path)
  end
end
printError("mekanet: main.lua not found (looked at " .. table.concat(candidates, ", ") .. ")")
