# mekanet

A wildly over-engineered logistics network for Mekanism, built on ComputerCraft
(CC:Tweaked). Instead of bolting a dedicated crusher onto every machine that
needs dust, machines **order** processing from shared factories: a sender
computer files a request, a service computer registers a **claim** with the
router, and the items themselves are moved chest-to-chest over a shared
wired-modem network with `pushItems` — a full stack per call, dispatched to a
horizontally scalable pool of **worker** computers.

v2 note: earlier versions moved items physically through quantum
entangloporters and logistical transporters. That layer throttled throughput
badly, so it's gone — transport is now entirely ComputerCraft.

Only the crushing service exists today, but the `service` role is generic —
an enrichment or infusing service is the same code with a different config.

## Topology

Everything below sits on ONE wired-modem network (networking cable, with an
activated wired modem on every chest and every computer):

```
 sender A                     crusher B                     router C + workers
 --------                     ---------                     ------------------
 input buffer ---------------> input chest                  router: claim ledger,
   (sender pushItems,            | (your local pipes)               matching, dispatch
    the "ship" hop)            crushing factory             workers: execute delivery
                                 | (your local pipes)                moves on demand
 result chest                  output chest -----------------+
   ^ (sender pushItems)                (worker pushItems,    |
 inbox chest  <----------------------- the "deliver" hop) ---+
```

Only the short hops inside a service site (input chest -> machines -> output
chest) are physical plumbing you build. Every hop between sites is a
`pushItems` call by a computer.

## How a claim flows

1. **Order** — the sender sees 72 iron ingots in its input buffer, finds a
   route, and sends `service.request {id, item, amount, inbox_chest}`.
2. **Claim** — the crusher maps ingot -> dust via its recipe table and asks
   the router to `claim.create` a claim *with the same id as the request*,
   baking in the physical addresses: its own input/output chests and the
   sender's inbox chest. The router persists it and replies; the crusher
   replies to the sender with the claim plus its `input_chest`.
3. **Ship** — the sender pushes the ingots straight into the service's input
   chest over the wired network and reports `claim.shipped {amount=moved}`
   so the claim scales to what actually shipped.
4. **Process** — physics happens locally: your pipes run the ingots through
   the factory into the output chest.
5. **Match** — the router's matcher sees enough dust in that service's
   output chest for the oldest matching claim (FIFO, with per-chest,
   per-item reservations) and marks it `arrived`.
6. **Deliver** — a dispatcher hands a move job to a worker (or executes it
   itself if none are online): push the dust from the service output chest
   into the sender's inbox chest. The `pushItems` return value is the
   confirmation — no counting, no negotiation.
7. **Land** — the router marks the claim `completed` and sends the sender an
   advisory `delivery.landed`; the sender trickles the inbox chest onward
   into its result chest, which your machines may freely drain.

## Claim lifecycle

```
created --> in_transit --> arrived --> delivering --> completed
   |             |            |            |
   |-> expired   |-> expired  `-> failed   `-> failed
   `-> failed    `-> failed
```

`created` may also jump straight to `arrived`: if the shipped-notice was
lost (or the output chest simply has stock on hand), the router still
fulfills the claim from whatever is physically there.

## Protocol

All messages ride rednet protocol `mekanet` in versioned envelopes with a
request id, retries, and an idempotency cache (see [lib/net.lua](lib/net.lua)).

| method | from -> to | purpose |
|---|---|---|
| `service.request` | sender -> service | ask for processing; returns claim + input chest |
| `claim.create` | service -> router | register a claim with chest addresses (idempotent by claim id) |
| `claim.shipped` | sender -> router | goods left the sender; scales the claim |
| `claim.abort` | sender -> router | cancel a claim that never shipped |
| `worker.register` | worker -> router | heartbeat; joins/keeps the worker in the pool |
| `move.exec` | router -> worker | execute one delivery move; result persisted by job id |
| `job.result` | router -> worker | "did you already run this job?" after a timeout/reboot |
| `delivery.landed` | router -> sender | advisory: your goods are in your inbox chest |
| `claim.get` / `claim.list` | anyone -> router | inspection (used by tools) |
| `sys.ping` / `sys.status` | anyone -> anyone | health and dashboards |

### Robustness model

At-least-once messaging + idempotent handlers + reconciliation, with moves
made transactional by `pushItems` return counts:

- Requests keep their id across retries; receivers cache responses and
  replay them. The claim id **is** the original request id.
- Chest addresses are snapshotted on the claim at creation, so a lost
  shipped-notice can never strand a deliverable claim.
- Every deliver dispatch gets job id `<claim>-d<seq>` with the sequence
  persisted **before** anything is sent. RPC retries reuse the id and hit
  the worker's *persisted* result store (it survives reboots); a deliberate
  re-dispatch of a remainder bumps the sequence. After a timeout the router
  asks the same worker `job.result` before ever re-dispatching — items move
  twice only if a worker vanishes mid-job with its result unreachable, and
  that path warns loudly.
- One deliver move in flight per output chest (no slot-level races between
  workers); parallelism comes from many services and many claims.
- `delivery.landed` is advisory; the sender's janitor reconciles every
  active order against `claim.get` (freeing slots on failure/expiry and
  re-sending lost shipped-notices).
- The router persists every claim mutation (tmp-file + move writes), prunes
  its archive, and warns before the disk quota fills.
- Chest reads/moves are pcall-guarded: a renamed or detached wired modem
  puts the affected claims on hold with a throttled warning instead of
  crashing anything; expiry is the backstop.

## Repo layout

```
main.lua                     entrypoint: reads config.lua, supervises the role
lib/
  class.lua  util.lua  log.lua  store.lua   shared kit (OOP, ids, logging, JSON persistence)
  net.lua                    rednet RPC node (retries, dedup, replay, stable job ids)
  claims.lua                 claim model + state machine + persistent ledger
  render.lua                 colored terminal output for the tools
  clients/
    inventory.lua            generic inventory client (drawer-aware push_item)
    multi_inventory.lua      several inventories presented as one buffer
    machine.lua              optional Mekanism machine readouts
roles/
  sender.lua                 computer A
  service.lua                computer B (generic; crusher = config)
  router.lua                 computer C (broker + dispatch)
  worker.lua                 move executors (run as many as you like)
examples/
  config.sender.lua  config.crusher.lua  config.router.lua  config.worker.lua
tools/
  devices.lua                list attached peripheral names for config.lua
  status.lua                 compact color dashboard (-v for raw payloads)
  claims.lua                 list the ledger; `show <id>` for one claim in full
```

## Install

On each computer (each needs a modem for rednet — wireless or the shared
wired network itself — and the boundary chests must carry **activated**
wired modems on one cable network):

1. Copy this repo onto the computer — at `/` or at `/mekanet`.
2. Run `tools/devices.lua` and note the peripheral names.
3. Copy the matching example config to **`config.lua` next to `main.lua`**
   and fill in the names.
4. Hook up your own `startup.lua` (e.g. `shell.run("/mekanet/main.lua")`)
   and reboot.

Boot order doesn't matter. Workers are optional — the router moves items
itself when none are registered; add worker computers to parallelize.

### Migrating from v1 (porters)

- Let in-flight claims finish, then delete `/data/claims` on the router and
  `/data/sender` on senders — old claims reference ports/frequencies and
  cannot be delivered by v2.
- Retire the entangloporters and port chests; cable every boundary chest
  onto one wired network instead (right-click each wired modem so it shows
  the red band and announces its name).
- Chest addresses snapshot at claim creation: replacing a wired modem
  renumbers peripherals, so finish or abort claims before rewiring.

## Adding a service (later)

1. Build the new factory with its own input/output chests on the shared
   network and a computer.
2. Copy `examples/config.crusher.lua`, change `name` (e.g. `enricher-1`),
   point it at its chests, and write its recipe table.
3. Add it to the routes of whichever senders should use it:
   `["enricher-1"] = { "mekanism:dust_iron" }`. Routes are keyed by service,
   and every item may be routed to exactly one service per sender.

No router changes needed — claims are service-agnostic.

## Operating notes

- `tools/status.lua` — compact color-coded view of every node (workers,
  buffers, claim counts). Pass `-v` for the full raw payloads.
- `tools/claims.lua [status]` — list the ledger; `tools/claims.lua show <id>`
  — one claim in full (chests, job seq/worker, history; id prefixes work).
- Logs go to the terminal and `/data/logs/<name>.log` (rotating).
- Recipe `output` ids must match what your pack's machines really produce
  (modpacks often unify dusts, e.g. `ftbmaterials:iron_dust`) — a wrong id
  leaves claims silently stuck `in_transit`; read the true id from the
  service's `output` counts in `tools/status.lua`.
- Claims that never see their goods expire after `claim_ttl_s` — tune it to
  your factory's speed.
