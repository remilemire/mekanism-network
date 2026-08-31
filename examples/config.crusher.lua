--[[ Crushing service ("computer B"). The `service` role is generic -- this
config is what makes it a crusher. An enrichment or infusing service later
is this same file with a new name, its own chests, and its recipes.
Copy to config.lua next to main.lua on the service computer. ]]

return {
  role = "service",
  name = "crusher-1", -- rednet hostname; senders route to this name
  protocol = "mekanet",
  router_host = "router",
  -- modem = "back",

  devices = {
    -- Both chests must be on the shared wired network. Your local plumbing
    -- carries items input_chest -> machines -> output_chest.
    input_chest = "minecraft:barrel_4",  -- senders ship raw goods here
    output_chest = "minecraft:barrel_5", -- the factory ejects results here;
                                         -- the router matches claims against it
    -- machine = "crusher_0",            -- optional: energy/status readouts only
  },

  recipes = {
    -- input item -> what the factory turns it into (and at what ratio)
    ["minecraft:iron_ingot"] = { output = "mekanism:dust_iron", ratio = 1 },
    ["minecraft:gold_ingot"] = { output = "mekanism:dust_gold", ratio = 1 },
    -- ["minecraft:cobblestone"] = { output = "minecraft:gravel", ratio = 1 },
  },

  -- log = { level = "debug" },
}
