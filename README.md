# mekanet

A wildly over-engineered logistics network for Mekanism, built on ComputerCraft
(CC:Tweaked). Instead of bolting a dedicated crusher onto every machine that
needs dust, machines **order** processing from shared factories: a sender
computer files a request, a service computer registers a **claim** with the
router, and every item moves chest-to-chest over one shared wired-modem
network with `pushItems` — a full stack per call.

The transport rule is **ownership**: every computer only ever pushes items
OUT of chests it owns, into a destination. Nothing on the network ever pulls
from a chest it doesn't own. Senders ship their goods; services deliver
their products; the router brokers and commands but never touches an item.

Only the crushing service exists today, but the `service` role is generic —
an enrichment or infusing service is the same code with a different config.

## Topology

Everything — chests AND computers — sits on ONE wired-modem network. No
wireless modems anywhere: rednet rides the wired modems too.

```
 sender A                          crusher B                   router C
 --------                          ---------                   --------
 input buffer                                                  claim ledger,
   | (sender: stage)                                           matching, dispatch;
 outbox  ------- (sender: ship) --> input chest                owns nothing,
                                      | (your local pipes)     moves nothing
 result chest                       crushing factory
   ^ (sender: drain)                  | (your local pipes)
 inbox  <---- (SERVICE: deliver, --- output chest
               on router command)
```

Only the hops inside a service site (input chest -> machines -> output
chest) are physical plumbing. Every labeled move is a `pushItems` call by
the computer that owns the source chest. The sender's outbox and inbox are
its audit points: everything outgoing stages through the outbox, everything
incoming lands in the inbox.

## How a claim flows

1. **Order** — the sender sees 72 iron ingots in its input buffer, finds a
   route, and sends `service.request {id, item, amount, inbox_chest}`.
2. **Claim** — the crusher maps ingot -> dust via its recipe table and asks
   the router to `claim.create` a claim *with the same id as the request*,
   baking in the physical addresses (its input/output chests, the sender's
   inbox). The crusher's reply tells the sender its `input_chest`.
3. **Stage & ship** — the sender writes its ledger, pushes the ingots into
   its own outbox (the commitment — `claim.shipped` reports this staged
   amount), then pushes outbox -> service input chest. Leftovers (input
   chest full) are retried by the sender's janitor using a persisted
   service -> input chest cache.
4. **Process** — your pipes run the ingots through the factory into the
   output chest.
5. **Match** — the router sees enough dust in that service's output chest
   for the oldest matching claim (FIFO, per-chest per-item reservations)
   and marks it `arrived`.
6. **Deliver** — the router commands the SERVICE: `deliver.exec {to, item,
   amount}` with a stable job id. The service pushes from its own output
   chest into the sender's inbox and answers with the moved count — the
   `pushItems` return value is the confirmation.
7. **Land** — the router marks the claim `completed` and nudges the sender
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
| `service.request` | sender -> service | ask for processing; returns claim + input chest |
| `claim.create` | service -> router | register a claim with chest addresses (idempotent by claim id) |
| `claim.shipped` | sender -> router | goods staged in the outbox; scales the claim |
| `claim.abort` | sender/operator -> router | fail a claim (any non-terminal state; goods recycle) |
| `deliver.exec` | router -> service | push N of item from your output chest to this inbox |
| `job.result` | router -> service | "did you run this job?" (done / interrupted / not_found) |
| `delivery.landed` | router -> sender | advisory: your goods are in your inbox chest |
| `claim.get` / `claim.list` | anyone -> router | inspection (used by tools) |
| `sys.ping` / `sys.status` | anyone -> anyone | health and dashboards |

### Robustness model

At-least-once messaging + idempotent handlers + reconciliation, with moves
made transactional by `pushItems` return counts:

- Requests keep their id across retries; receivers cache responses and
  replay them. The claim id **is** the original request id.
- Chest addresses snapshot on the claim at creation; the sender also
  persists each service's input chest so outbox leftovers stay shippable
  after their claims are forgotten.
- The sender's ledger is written *before* staging, so a reboot mid-staging
  reports the requested amount as an upper bound instead of stranding a
  half-committed claim silently.
- Every deliver dispatch gets job id `<claim>-d<seq>`, sequence persisted
  **before** sending. RPC retries replay the service's *persisted* result;
  remainder re-dispatches bump the sequence. After a timeout the router
  asks `job.result` — services are static, so there is no reassignment.
  The one honest double-move window left: a service rebooting between its
  push and its result write, which surfaces as `interrupted` with a loud
  warning before re-dispatch.
- One deliver command in flight per service (its serial handler loop
  executes one move at a time anyway); parallelism comes from many
  services.
- `delivery.landed` is advisory; the sender's janitor reconciles every
  active order against `claim.get` (freeing slots on failure/expiry and
  re-sending lost shipped-notices).
- The router persists every claim mutation (tmp-file + move writes), prunes
  its archive, and warns before the disk quota fills. Chest reads are
  pcall-guarded: a renamed or detached wired modem puts the affected claims
  on hold with a throttled warning; `claims abort <id>` is the operator
  escape hatch for anything wedged.

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
  sender.lua                 computer A (orders, stages, ships, drains)
  service.lua                computer B (generic; crusher = config; delivers)
  router.lua                 computer C (broker + dispatch; owns nothing)
examples/
  config.sender.lua  config.crusher.lua  config.router.lua
tools/
  devices.lua                list attached peripheral names for config.lua
  status.lua                 compact color dashboard (-v for raw payloads)
  claims.lua                 list / show <id> / abort <id>
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

### Migrating from v2 (workers)

- Let in-flight claims finish, then delete `/data/claims` on the router and
  `/data/sender` on senders (v2 claims carry worker fields v3 ignores, and
  ledger shapes changed). Delete `/data/worker` on repurposed computers.
- Worker computers retire — or become spare senders/services. The sender
  needs its outbox chest back (`devices.outbox_inventory`).
- Wireless modems can come off; rednet runs over the wired network.

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

- `tools/status.lua` — compact color-coded view of every node (queues,
  buffers, claim counts). Pass `-v` for the full raw payloads.
- `tools/claims.lua [status]` — list the ledger; `show <id>` — one claim in
  full (chests, job seq, history; id prefixes work); `abort <id>` — fail a
  wedged claim (its goods recycle into service stock).
- Logs go to the terminal and `/data/logs/<name>.log` (rotating).
- Recipe `output` ids must match what your pack's machines really produce
  (modpacks often unify dusts, e.g. `ftbmaterials:iron_dust`) — a wrong id
  leaves claims silently stuck `in_transit`; read the true id from the
  service's `output` counts in `tools/status.lua`.
- Claims that never see their goods expire after `claim_ttl_s` — tune it to
  your factory's speed.
