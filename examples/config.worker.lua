--[[ Worker: a move executor. Needs nothing but a wired modem onto the
shared network (to reach the chests) and a modem for rednet. Add as many
worker computers as you like -- each adds a parallel delivery lane.
Copy to config.lua next to main.lua on each worker computer. ]]

return {
  role = "worker",
  name = "mover-1", -- unique rednet hostname per worker
  protocol = "mekanet",
  router_host = "router",
  -- modem = "back",

  -- heartbeat_s = 30,        -- how often to re-register with the router
  -- result_retention_s = 3600, -- how long to remember finished job results
  -- data_dir = "/data/worker",
  -- log = { level = "debug" },
}
