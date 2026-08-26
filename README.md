# mekanet

A wildly over-engineered logistics network for Mekanism, built on ComputerCraft
(CC:Tweaked). Instead of bolting a dedicated crusher onto every machine that
needs dust, machines **order** processing from shared factories: a sender
computer files a request, a service computer registers a **claim** with the
router, items teleport through quantum entangloporters to the shared factory,
and the router delivers the finished goods back on a negotiated frequency.

Only the crushing service exists today, but the `service` role is generic —
an enrichment or infusing service is the same code with a different config.

## Topology

```
sender A                      crusher B                        router C
--------                      ---------                       --------
input buffer (A-in)
   | pushItems (computer A)
outbox chest (A-2)
   | (your pipes)
outbox porter (A-out) ══ mekanet.crush.in ══> input porter (B-in)
                                                 | (your pipes)
                                              crushing factory
                                                 | (your pipes)
                                              output porter (B-out) ══ mekanet.intake ══> intake porter (C-in)
                                                                                             | (your pipes)
                                                                                          intake buffer
                                                                                             | pushItems (computer C)
result chest
   ^ pushItems (computer A, after the claim closes)
inbox buffer                                                                              port chest 1..8
   ^ (your pipes)                                                                            | (your pipes)
inbox porter (A-in) <═══════════════ mekanet.out.N (negotiated per delivery) ═══════════  port porter 1..8
```

`══` is entangloporter teleportation on a named frequency. `(your pipes)` is
plain Mekanism plumbing (logistical transporters / ejectors) that you build;
the computers never touch it. Everything a computer moves goes through
`pushItems`, so **each computer must share a wired-modem network with the
inventories it touches** (chests, barrels, and the entangloporters it retunes).

## How a claim flows

1. **Order** — the sender sees 72 iron ingots in its input buffer, finds a
   route for them, and sends `service.request {id, item, amount}` to `crusher-1`.
2. **Claim** — the crusher maps ingot → dust via its recipe table and asks the
   router to `claim.create` a claim *with the same id as the request*. The
   router persists it as JSON and replies; the crusher replies to the sender
   with the claim plus its `input_frequency`.
3. **Ship** — the sender tunes its outbox porter to that frequency, pushes the
   ingots into its outbox chest (counting what actually moved), and tells the
   router `claim.shipped {claim_id, amount}` so the claim scales to reality.
4. **Process** — physics happens: ingots teleport to the crusher, get crushed,
   and the dust teleports to the router's intake buffer.
5. **Match** — the router's intake watcher sees enough dust for the oldest
   matching claim (FIFO, with per-item reservations) and marks it `arrived`.
6. **Negotiate** — the router picks a free delivery port and offers it:
   `delivery.offer {claim_id, frequency: "mekanet.out.3"}`. The sender tunes
   its inbox porter to that frequency and confirms (or answers `busy`, and the
   router retries shortly).
7. **Deliver** — the router locks the port, pushes the dust into that port's
   chest, and sends `delivery.dispatched`. The dust teleports to the sender's
   inbox buffer.
8. **Confirm** — the sender watches its inbox buffer (a chest nothing else
   drains), and once the goods are in hand sends `delivery.received`. The
   router completes the claim and frees the port; the sender parks its inbox
   porter on a private idle frequency and only then moves the goods to the
   result chest, so pipes pulling from it can't race the delivery count.

## Claim lifecycle

```
created ──> in_transit ──> arrived ──> delivering ──> completed
   │             │            │            │
   ├─> expired   ├─> expired  └─> failed   └─> failed
   └─> failed    └─> failed
```

`created` may also jump straight to `arrived`: if the shipped-notice was lost
(or the intake simply has stock on hand), the router still fulfills the claim
from whatever is physically there.

## Protocol

All messages ride rednet protocol `mekanet` in versioned envelopes with a
request id, retries, and an idempotency cache (see [lib/net.lua](lib/net.lua)).

| method | from → to | purpose |
|---|---|---|
| `service.request` | sender → service | ask for processing; returns claim + input frequency |
| `claim.create` | service → router | register a claim (idempotent by claim id) |
| `claim.shipped` | sender → router | goods left the sender; scales the claim |
| `claim.abort` | sender → router | cancel a claim that never shipped |
| `delivery.offer` | router → sender | propose a port frequency; sender tunes in or says `busy` |
| `delivery.dispatched` | router → sender | goods pushed into the port chest |
| `delivery.received` | sender → router | goods confirmed in hand; frees the port |
| `claim.get` / `claim.list` | anyone → router | inspection (used by tools) |
| `sys.ping` / `sys.status` | anyone → anyone | health and dashboards |

### Robustness model

True atomicity is impossible when half the transaction is items in chests, so
mekanet aims for *at-least-once messaging + idempotent handlers + reconciliation*:

- Requests keep their id across retries; receivers cache responses and replay
  them, so a lost response never causes double work. The claim id **is** the
  original request id, making the whole create chain idempotent end to end.
- The router persists every claim mutation to disk (`/data/claims/*.json`,
  written via tmp-file + move) and resumes mid-delivery claims after reboot,
  including re-locking their ports.
- The sender keeps its own ledger, confirms interrupted deliveries after a
  reboot, retries unacknowledged receipts, and reconciles its order slots
  against the router so an expired claim can't wedge an item type forever.
- Ports stay locked while a delivery is unconfirmed — a stuck lane is a loud
  janitor warning, never silent item mixing.
- The sender never retunes its outbox porter while a previous shipment is
  still draining, so back-to-back orders to different services can't
  teleport leftovers to the wrong factory.
- Frequencies are re-asserted continuously (`ensure_frequency` is idempotent),
  so a stray click in a porter GUI heals itself within a minute.

## Repo layout

```
main.lua                     entrypoint: reads config.lua, supervises the role
lib/
  class.lua  util.lua  log.lua  store.lua   shared kit (OOP, ids, logging, JSON persistence)
  net.lua                    rednet RPC node (retries, dedup, replay, worker loop)
  claims.lua                 claim model + state machine + persistent ledger
  clients/
    inventory.lua            generic inventory client (list/count/push_item)
    multi_inventory.lua      several inventories presented as one buffer
    entangloporter.lua       quantum entangloporter client (ensure_frequency)
    machine.lua              optional Mekanism machine readouts
roles/
  sender.lua                 computer A
  service.lua                computer B (generic; crusher = config)
  router.lua                 computer C
examples/
  config.sender.lua  config.crusher.lua  config.router.lua
tools/
  devices.lua                list attached peripheral names for config.lua
  status.lua                 ping every node, print dashboards
  claims.lua                 list the router's claims
```

## Install

On each of the three computers (each needs a **wireless modem** for rednet
plus a **wired modem network** reaching its chests and porters):

1. Copy this repo onto the computer — at `/` or at `/mekanet` (via floppy
   disk, `wget` from a raw URL, or pastebin).
2. Run `tools/devices.lua` and note the peripheral names.
3. Copy the matching example (`examples/config.sender.lua`,
   `config.crusher.lua`, or `config.router.lua`) to **`config.lua` next to
   `main.lua`**, and fill in the device names.
4. Hook up your own `startup.lua` at the computer root to run `main.lua`
   (e.g. `shell.run("/mekanet/main.lua")`), then reboot.

Boot order doesn't matter — every node retries and re-resolves hostnames —
but starting the router first makes the first minute quieter.

## Adding a service (later)

1. Build the new factory with its own in/out entangloporters and computer.
2. Copy `examples/config.crusher.lua`, change `name` (e.g. `enricher-1`),
   give it a fresh `input_frequency` (e.g. `mekanet.enrich.in`), keep
   `output_frequency = "mekanet.intake"`, and write its recipe table.
3. Add it to the routes of whichever senders should use it:
   `["enricher-1"] = { "mekanism:dust_iron" }`. Routes are keyed by service,
   and every item may be routed to exactly one service per sender.

No router changes needed — claims are service-agnostic.

## Operating notes

- The router's `intake_inventory` may be a single peripheral name or a list
  of names treated as one combined buffer (counts sum across all of them,
  and deliveries drain them in the listed order).
- `tools/status.lua` — compact color-coded view of every node: buffers,
  ports, claim counts. Pass `-v` for the full raw payloads.
- `tools/claims.lua [status]` — list the ledger; `tools/claims.lua show <id>`
  — one claim in full (abort reason, history timeline; id prefixes work).
- Logs go to the terminal and `/data/logs/<name>.log` (rotating).
- Finished claims are archived under `/data/claims/archive/` after an hour.
- The one deliberate quirk: a claim whose goods never arrive expires after
  `claim_ttl_s` with a warning, because the router cannot distinguish "lost in
  the pipes" from "still crushing" — tune the TTL to your factory's speed.
