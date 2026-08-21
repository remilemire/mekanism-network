--[[ Crushing service ("computer B"). The `service` role is generic -- this
config is what makes it a crusher. An enrichment or infusing service later
is this same file with a new name, its own frequencies, and its recipes.
Copy to config.lua next to main.lua on the service computer. ]]

return {
  role = "service",
  name = "crusher-1", -- rednet hostname; senders route to this name
  protocol = "mekanet",
  router_host = "router",
  -- modem = "back",

  devices = {
    input_porter = "quantumEntangloporter_0",  -- entangloporter B-in: feeds the crushing factory
    output_porter = "quantumEntangloporter_1", -- entangloporter B-out: factory output, ships to router
    -- machine = "crusher_0",                  -- optional: for energy/status readouts only
  },

  input_frequency = "mekanet.crush.in", -- senders are told to ship here
  output_frequency = "mekanet.intake",  -- must equal the router's intake_frequency

  recipes = {
    -- input item -> what the factory turns it into (and at what ratio).
    -- IMPORTANT: use the REAL output id from your pack -- modpacks often
    -- unify dusts under another mod's id (e.g. "ftbmaterials:iron_dust").
    -- Crush one item and read the id from the router's intake in
    -- tools/status.lua; a wrong id leaves claims stuck in_transit forever.
    ["minecraft:iron_ingot"] = { output = "mekanism:dust_iron", ratio = 1 },
    ["minecraft:gold_ingot"] = { output = "mekanism:dust_gold", ratio = 1 },
    -- ["minecraft:cobblestone"] = { output = "minecraft:gravel", ratio = 1 },
  },

  -- log = { level = "debug" },
}
