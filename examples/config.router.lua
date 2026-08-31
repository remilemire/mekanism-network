--[[ Router ("computer C"): claim broker and delivery dispatcher. Owns no
chests of its own -- it matches claims in service output chests and hands
delivery moves to workers (or executes them itself when no workers are
online). Copy to config.lua next to main.lua on the router computer. ]]

return {
  role = "router",
  name = "router", -- rednet hostname; senders and services expect "router"
  protocol = "mekanet",
  -- modem = "back",

  dispatchers = 4,     -- max concurrent delivery moves in flight
  claim_ttl_s = 900,   -- expire claims whose goods never show up
  stuck_after_s = 300, -- nag about deliveries that can't finish
  retention_s = 3600,  -- archive finished claims after this long
  poll_s = 2,          -- output chest matching interval
  data_dir = "/data/claims",
  -- archive_retention_s = 86400, -- delete archived claims after this long
  --                                 (the disk quota is ~1MB; never keep forever)
  -- log = { level = "debug" },
}
