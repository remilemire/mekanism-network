--[[ Smelting service. Nothing about the `service` role is crusher-specific:
a smelter is the same role with smelting recipes, its own chests, and its
own rednet name. Senders reach it by adding a route for it. Copy to
config.lua next to main.lua on the smelter computer. ]]

return {
  role = "service",
  name = "smelter-1", -- rednet hostname; senders route to this name
  protocol = "mekanet",
  -- modem = "back",

  devices = {
    -- Both chests must be on the shared wired network. Your local plumbing
    -- carries items input_chest -> smelter(s) -> output_chest.
    input_chest = "minecraft:barrel_6",  -- senders ship raw goods here
    output_chest = "minecraft:barrel_7", -- the smelter ejects results here
    -- machine = "energized_smelter_0",  -- optional: energy/status readouts only
  },

  recipes = {
    -- input item -> what the smelter turns it into (and at what ratio).
    -- Use the ids your pack really produces (check tools/status.lua output).
    ["minecraft:raw_iron"] = { output = "minecraft:iron_ingot", ratio = 1 },
    ["minecraft:raw_gold"] = { output = "minecraft:gold_ingot", ratio = 1 },
    ["mekanism:dust_iron"] = { output = "minecraft:iron_ingot", ratio = 1 },
    ["minecraft:cobblestone"] = { output = "minecraft:stone", ratio = 1 },
    ["minecraft:sand"] = { output = "minecraft:glass", ratio = 1 },
  },

  -- Optional in-world dashboard on an attached monitor (advanced = color).
  -- monitor = {
  --   device = "monitor_2",
  --   title = "Smelter",
  --   description = "shared smelting line",
  --   scale = 0.5,
  --   refresh_s = 1,
  -- },

  claim_ttl_s = 900,   -- expire claims whose goods never show up
  stuck_after_s = 300, -- nag about deliveries that can't finish
  retention_s = 3600,  -- archive finished claims after this long
  poll_s = 2,          -- output chest matching interval
  data_dir = "/data/claims",
  -- archive_retention_s = 86400,
  -- log = { level = "debug" },
}
