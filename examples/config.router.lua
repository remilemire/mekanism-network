--[[ Router ("computer C"): claim broker and delivery dispatcher. Owns no
chests and moves no items -- it matches claims in service output chests
(read-only) and commands the owning service to deliver. Copy to config.lua
next to main.lua on the router computer. ]]

return {
  role = "router",
  name = "router", -- rednet hostname; senders and services expect "router"
  protocol = "mekanet",
  -- modem = "back",

  dispatchers = 4,     -- max concurrent deliver commands (across services;
                       -- each service executes one move at a time anyway)
  claim_ttl_s = 900,   -- expire claims whose goods never show up
  stuck_after_s = 300, -- nag about deliveries that can't finish
  retention_s = 3600,  -- archive finished claims after this long
  poll_s = 2,          -- output chest matching interval
  data_dir = "/data/claims",
  -- archive_retention_s = 86400, -- delete archived claims after this long
  --                                 (the disk quota is ~1MB; never keep forever)
  -- log = { level = "debug" },
}
