--[[ Sender ("computer A"): watches an input buffer and orders work from
services, shipping items itself over the shared wired network. Copy to
config.lua next to main.lua on the sender computer and edit the device
names -- run tools/devices.lua to list what's attached. ]]

return {
  role = "sender",
  name = "fission-sender-1", -- unique rednet hostname for this computer
  protocol = "mekanet",      -- must match every other computer
  -- modem = "back",         -- optional: force a specific modem for rednet

  devices = {
    -- All four must be on the shared wired network (activated wired modems).
    input_buffer = "minecraft:barrel_0",     -- items needing processing
    outbox_inventory = "minecraft:barrel_1", -- outgoing staging: everything
                                             -- committed to an order passes
                                             -- through here (your audit point)
    inbox_inventory = "minecraft:barrel_3",  -- deliveries land here; do NOT
                                             -- pipe out of it -- the computer
                                             -- moves items on itself
    result_inventory = "minecraft:barrel_2", -- finished goods end up here;
                                             -- pipe your machine from it
  },

  routes = {
    -- service (rednet hostname) -> items from input_buffer it processes.
    -- Each item may appear under exactly one service.
    ["crusher-1"] = { "minecraft:iron_ingot" },
    -- later: ["enricher-1"] = { "mekanism:dust_iron" },
  },

  batch = {
    min = 8,          -- don't order until at least this many are buffered
    max = 72,         -- cap per claim
    max_inflight = 4, -- concurrent outstanding claims allowed per item type
  },
  poll_s = 2,         -- input buffer scan interval

  -- Optional in-world dashboard on an attached monitor (advanced = color).
  -- The sender keeps logging to its own terminal; the monitor is extra.
  -- monitor = {
  --   device = "monitor_0",               -- peripheral name (side or network)
  --   title = "Fission Reactor",          -- display name; drawn in block
  --                                       -- letters when it fits (4 cols/char)
  --   description = "iron dust for fuel", -- brief, optional
  --   scale = 0.5,                        -- text scale for the WHOLE monitor
  --                                       -- (0.5-5; bigger = fewer rows/cols)
  --   big_title = true,                   -- block-letter title when it fits;
  --                                       -- false = plain title (raise scale instead)
  --   refresh_s = 1,                      -- redraw interval, optional
  -- },

  -- data_dir = "/data/sender",
  -- log = { level = "debug" },
  -- restart_delay_s = 5,
}
