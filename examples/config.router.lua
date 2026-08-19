--[[ Router ("computer C"): claim broker and delivery hub. Copy to
config.lua next to main.lua on the router computer. ]]

return {
  role = "router",
  name = "router", -- rednet hostname; senders and services expect "router"
  protocol = "mekanet",
  -- modem = "back",

  devices = {
    intake_porter = "quantumEntangloporter_0", -- entangloporter C-in
    intake_inventory = "minecraft:barrel_0",   -- big buffer fed by C-in
  },
  intake_frequency = "mekanet.intake", -- every service's output_frequency points here

  ports = {
    -- Delivery lanes: each chest drains into its porter on a fixed
    -- frequency. List as many as you built (the design brief says 8).
    { inventory = "minecraft:barrel_1", porter = "quantumEntangloporter_1", frequency = "mekanet.out.1" },
    { inventory = "minecraft:barrel_2", porter = "quantumEntangloporter_2", frequency = "mekanet.out.2" },
    { inventory = "minecraft:barrel_3", porter = "quantumEntangloporter_3", frequency = "mekanet.out.3" },
    { inventory = "minecraft:barrel_4", porter = "quantumEntangloporter_4", frequency = "mekanet.out.4" },
    { inventory = "minecraft:barrel_5", porter = "quantumEntangloporter_5", frequency = "mekanet.out.5" },
    { inventory = "minecraft:barrel_6", porter = "quantumEntangloporter_6", frequency = "mekanet.out.6" },
    { inventory = "minecraft:barrel_7", porter = "quantumEntangloporter_7", frequency = "mekanet.out.7" },
    { inventory = "minecraft:barrel_8", porter = "quantumEntangloporter_8", frequency = "mekanet.out.8" },
  },

  claim_ttl_s = 900,   -- expire claims whose goods never show up
  stuck_after_s = 300, -- nag about unconfirmed deliveries after this long
  retention_s = 3600,  -- archive finished claims after this long
  poll_s = 2,
  data_dir = "/data/claims",
  -- log = { level = "debug" },
}
