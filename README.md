# mekanet

A wildly over-engineered logistics network for Mekanism, built on ComputerCraft
(CC:Tweaked). Instead of bolting a dedicated crusher onto every machine that
needs dust, machines **order** processing from shared factories. Two roles,
no coordinator: a **sender** files a request with a **service**, and the
service brokers its own claim ledger, matches goods, and delivers.

Every item moves chest-to-chest over one shared wired-modem network with
`pushItems` — a full stack per call — under the **ownership rule**: every
computer only ever pushes items OUT of chests it owns, into a destination.
Nothing on the network ever pulls from a chest it doesn't own.

Only the crushing service exists today, but the `service` role is generic —
an enrichment or infusing service is the same code with a different config.

## Topology

Everything — chests AND computers — sits on ONE wired-modem network. No
wireless modems anywhere: rednet rides the wired modems too.

```
 sender A                          crusher B (broker of its own claims)
 --------                          -------------------------------------
 input buffer                      claim ledger . FIFO matching . janitor
   | (sender: stage)
 outbox  ------- (sender: ship) --> input chest
                                      | (your local pipes)
 result chest                       crushing factory
   ^ (sender: drain)                  | (your local pipes)
 inbox  <----- (SERVICE: deliver) - output chest
```

Only the hops inside a service site (input chest -> machines -> output
chest) are physical plumbing. Every labeled move is a `pushItems` call by
the computer that owns the source chest. The sender's outbox and inbox are
its audit points: everything outgoing stages through the outbox, everything
incoming lands in the inbox.

## How a claim flows

1. **Order** — the sender sees 72 iron ingots in its input buffer, finds a
   route, and sends `service.request {id, item, amount, inbox_chest}`.
2. **Claim** — the crusher maps ingot -> dust via its recipe table and
   stores a claim *with the same id as the request* in its own persisted
   ledger, chest addresses baked in. Its reply tells the sender the
   `input_chest` to ship to.
3. **Stage & ship** — the sender writes its ledger, pushes the ingots into
   its own outbox (the commitment — `claim.shipped` reports this staged
   amount), then pushes outbox -> service input chest. Leftovers (input
   chest full) are retried by the sender's janitor using a persisted
   service -> input chest cache.
4. **Process** — your pipes run the ingots through the factory into the
   output chest.
5. **Match** — the service sees enough dust in its output chest for the
   oldest matching claim (FIFO with per-item reservations — cross-sender
   fairness lives in this queue) and marks it `arrived`.
6. **Deliver** — the service pushes from its own output chest into the
   sender's inbox chest. The `pushItems` return value is the confirmation;
   no job protocol exists because the broker and the mover are the same
   computer.
7. **Land** — the service marks the claim `completed` and nudges the sender
   with an advisory `delivery.landed`; the sender drains its inbox into the
   result chest, which your machines may freely drain.

## Claim lifecycle

```
created --> in_transit --> arrived --> delivering --> completed
   |             |            |            |
   |-> expired   |-> expired  `-> failed   `-> failed
   `-> failed    `-> failed
```

`created` may also jump straight to `arrived` (lost shipped-notice, or
stock on hand). Expiry is recycling, not loss: an expired claim's goods
still get transported and processed, and the matcher credits the resulting
stock to future claims.

## Protocol

All messages ride rednet protocol `mekanet` in versioned envelopes with a
request id, retries, and an idempotency cache (see [lib/net.lua](lib/net.lua)).

| method | from -> to | purpose |
|---|---|---|
| `service.request` | sender -> service | ask for processing; stores the claim, returns it + input chest |
| `claim.shipped` | sender -> service | goods staged in the outbox; scales the claim |
| `claim.abort` | sender/operator -> service | fail a claim (any non-terminal state; goods recycle) |
| `delivery.landed` | service -> sender | advisory: your goods are in your inbox chest |
| `claim.get` / `claim.list` | anyone -> service | inspection (used by tools) |
| `sys.ping` / `sys.status` | anyone -> anyone | health and dashboards |

### Robustness model

At-least-once messaging + idempotent handlers + reconciliation, with moves
made transactional by `pushItems` return counts:

- Requests keep their id across retries; receivers cache responses and
  replay them. The claim id **is** the original request id, so a retried
  order replays the stored claim instead of double-booking.
- Chest addresses snapshot on the claim at creation; the sender also
  persists each service's input chest so outbox leftovers stay shippable
  after their claims are forgotten.
- The sender's ledger is written *before* staging, so a reboot mid-staging
  reports the requested amount as an upper bound instead of stranding a
  half-committed claim silently.
- Delivery is a local push on the service, flagged `deliver_unresolved`
  in the persisted claim before each push: the only unknown-outcome window
  is a service reboot mid-push, surfaced loudly at boot before the
  remainder is re-pushed (a small, honest double-move risk).
- `delivery.landed` is advisory; the sender's janitor reconciles every
  active order against the owning service's `claim.get` (freeing slots on
  failure/expiry and re-sending lost shipped-notices).
- Backpressure: while the sender's inbox can't fully drain (result
  inventory full), it stops placing new orders -- in-flight deliveries
  still land in the inbox, but no new work enters the pipeline until the
  clog clears. Status shows the pause; orders resume within a tick of
  space freeing up.
- Expiry waits for the pipeline: a shipped claim's TTL clock stays parked
  while its raw input is still queued in the service input chest, so slow
  or busy factories never orphan goods by timing out. Expiry means the
  pipeline drained and the goods never appeared (wrong recipe id, dead
  machine).
- Orphan adoption: claims take exactly their amount, so stock nobody
  expects (leftovers of expired/aborted claims, migration wipes) would
  circulate forever. A new order measures such stock conservatively --
  chest count minus every open claim's outstanding amount -- and folds it
  into the new claim, so the chest self-cleans on the next quiet order.
- Every service persists claim mutations (tmp-file + move writes), prunes
  its archive, and warns before the disk quota fills. Chest access is
  pcall-guarded: a renamed or detached wired modem puts claims on hold
  with a throttled warning; `claims abort <id>` is the operator escape
  hatch for anything wedged.

## Repo layout

```
main.lua                     entrypoint: reads config.lua, supervises the role
lib/
  class.lua  util.lua  log.lua  store.lua   shared kit (OOP, ids, logging, JSON persistence)
  net.lua                    rednet RPC node (retries, dedup, replay)
  claims.lua                 claim model + state machine + persistent ledger
  render.lua                 colored terminal output for the tools
  monitor.lua                MonitorView: optional in-world dashboards
  clients/
    inventory.lua            generic inventory client (drawer-aware push_item)
    multi_inventory.lua      several inventories presented as one buffer
    machine.lua              optional Mekanism machine readouts
roles/
  sender.lua                 orders, stages, ships, drains
  service.lua                generic factory front-end; broker of its claims
examples/
  config.sender.lua  config.crusher.lua
tools/
  devices.lua                list attached peripheral names for config.lua
  status.lua                 compact color dashboard (-v for raw payloads)
  claims.lua                 list / show <id> / abort <id>, across all services
```

## Install

One cable network. Every boundary chest gets a wired modem (right-click it
so it shows the red band and announces its name); every computer attaches
to the same network with its own wired modem. No wireless modems needed.

1. Copy this repo onto each computer — at `/` or at `/mekanet`.
2. Run `tools/devices.lua` and note the peripheral names.
3. Copy the matching example config to **`config.lua` next to `main.lua`**
   and fill in the names.
4. Hook up your own `startup.lua` (e.g. `shell.run("/mekanet/main.lua")`)
   and reboot.

Boot order doesn't matter — every node retries and re-resolves hostnames.

### Migrating from v3 (router)

- Let in-flight claims finish, then delete `/data/claims` on the old
  router and `/data/sender` + `/data/sender/chests` on senders (ledger
  shapes changed; claims now live at each service).
- The router computer retires — or becomes the next service. Each service
  gains the janitor knobs that used to live in the router config
  (`claim_ttl_s`, `stuck_after_s`, `retention_s`, `archive_retention_s`).
- Senders drop `router_host` from their configs.

## Adding a service (later)

1. Build the new factory with its own input/output chests on the shared
   network and a computer.
2. Copy `examples/config.crusher.lua`, change `name` (e.g. `enricher-1`),
   point it at its chests, and write its recipe table.
3. Add it to the routes of whichever senders should use it:
   `["enricher-1"] = { "mekanism:dust_iron" }`. Routes are keyed by service,
   and every item may be routed to exactly one service per sender.

That's it — there is nothing else to configure; services are self-contained.

## Operating notes

- `tools/status.lua` — compact color-coded view of every node (claims,
  buffers, output stock). Pass `-v` for the full raw payloads.
- Senders can drive an optional monitor (`monitor = {...}` in the sender
  config): display name, description, orders in progress with their live
  status, a spinner while work is in flight, and PAUSED / inbox warnings.
  It draws on the monitor peripheral directly, so the sender's own
  terminal keeps logging as usual; a missing monitor just warns.
- `tools/claims.lua [status]` — merged ledger across all services;
  `show <id>` — one claim in full (chests, history; id prefixes work);
  `abort <id>` — fail a wedged claim (its goods recycle into stock);
  `archive [status]` — finished claims already swept out of the live
  ledger (this is where expired claims go after an hour). Append a service
  hostname to target just one.
- Logs go to the terminal and `/data/logs/<name>.log` (rotating).
- Recipe `output` ids must match what your pack's machines really produce
  (modpacks often unify dusts, e.g. `ftbmaterials:iron_dust`) — a wrong id
  leaves claims silently stuck `in_transit`; read the true id from the
  service's `output` counts in `tools/status.lua`.
- Claims that never see their goods expire after `claim_ttl_s` — tune it to
  your factory's speed.
