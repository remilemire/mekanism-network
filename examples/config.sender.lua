--[[ Sender ("computer A"): watches an input buffer and orders work from
services. Copy to config.lua next to main.lua on the sender computer and
edit the device names -- run tools/devices.lua to list what's attached. ]]

return {
  role = "sender",
  name = "fission-sender-1", -- unique rednet hostname for this computer
  protocol = "mekanet",      -- must match every other computer
  router_host = "router",
  -- modem = "back",         -- optional: force a specific modem peripheral

  devices = {
    input_buffer = "minecraft:barrel_0",       -- inventory A-in: items needing processing
    outbox_inventory = "minecraft:barrel_1",   -- inventory A-2: drains into outbox_porter
    outbox_porter = "quantumEntangloporter_0", -- entangloporter A-out
    inbox_porter = "quantumEntangloporter_1",  -- entangloporter A-in: receives deliveries
    result_inventory = "minecraft:barrel_2",   -- finished goods land here; pipe your machine from it
  },

  routes = {
    -- item appearing in input_buffer -> service (rednet hostname) that processes it
    ["minecraft:iron_ingot"] = { service = "crusher-1" },
    -- later: ["mekanism:dust_iron"] = { service = "enricher-1" },
  },

  batch = { min = 8, max = 72 }, -- order at least min, at most max per claim
  poll_s = 2,                    -- input buffer scan interval
  receive_timeout_s = 60,        -- accept a partial delivery after this long

  -- idle_frequency = "mekanet.idle.7", -- default: unique per computer id
  -- data_dir = "/data/sender",
  -- log = { level = "debug" },
  -- restart_delay_s = 5,
}
