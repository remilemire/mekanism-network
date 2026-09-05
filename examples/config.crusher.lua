--[[ Crushing service. The `service` role is generic -- this config is what
makes it a crusher. An enrichment or infusing service later is this same
file with a new name, its own chests, and its recipes. Since v4 each
service is also the broker for its own claims (there is no router).
Copy to config.lua next to main.lua on the service computer. ]]

return {
  role = "service",
  name = "crusher-1", -- rednet hostname; senders route to this name
  protocol = "mekanet",
  -- modem = "back",

  devices = {
    -- Both chests must be on the shared wired network. Your local plumbing
    -- carries items input_chest -> machines -> output_chest.
    input_chest = "minecraft:barrel_4",  -- senders ship raw goods here
    output_chest = "minecraft:barrel_5", -- the factory ejects results here;
                                         -- claims are matched against it
    -- machine = "crusher_0",            -- optional: energy/status readouts only
  },

  recipes = {
    -- input item -> what the factory turns it into (and at what ratio)
    ["minecraft:iron_ingot"] = { output = "mekanism:dust_iron", ratio = 1 },
    ["minecraft:gold_ingot"] = { output = "mekanism:dust_gold", ratio = 1 },
    -- ["minecraft:cobblestone"] = { output = "minecraft:gravel", ratio = 1 },
  },

  -- Optional in-world dashboard on an attached monitor (advanced = color):
  -- open claims with live status, queued input, output stock, delivered.
  -- monitor = {
  --   device = "monitor_1",
  --   title = "Crusher",
  --   description = "shared crushing line",
  --   scale = 0.5,
  --   refresh_s = 1,
  -- },

  claim_ttl_s = 900,   -- expire claims whose goods never show up
  stuck_after_s = 300, -- nag about deliveries that can't finish
  retention_s = 3600,  -- archive finished claims after this long
  poll_s = 2,          -- output chest matching interval (start-to-start);
                       -- matched goods are delivered in the same tick
  data_dir = "/data/claims",
  -- archive_retention_s = 86400, -- delete archived claims after this long
  --                                 (the disk quota is ~1MB; never keep forever)
  -- log = { level = "debug" },
}
