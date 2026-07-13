# MESI Cache-Coherence Unit

A snooping **MESI** cache-coherence unit for a 4-core shared-memory system,
written in SystemVerilog. The focus of this project is **provable correctness**:
alongside the coherence hardware there is a passive bus monitor that continuously
checks the coherence invariants against randomized multi-core traffic.

## System overview

```
   Core0     Core1     Core2     Core3
    |          |          |          |
  [ L1$0 ]  [ L1$1 ]  [ L1$2 ]  [ L1$3 ]     each: MESI FSM + tag/state/data arrays
    |          |          |          |
    +-----+----+-----+----+-----+----+
          |  Snoop bus (arbiter + broadcast)  |
          +-----------------+-----------------+
                            |
                      [ Main memory ]
```

* **Protocol:** MESI (Modified / Exclusive / Shared / Invalid)
* **Mechanism:** bus snooping with a central arbiter
* **Write policy:** write-back, write-allocate
* **Organization:** direct-mapped L1, one 32-bit word per coherence block
* **Cores:** 4 (parameterized)

## MESI states

| State | Meaning                          | Clean/Dirty | Other copies |
|-------|----------------------------------|-------------|--------------|
| M     | Modified                         | dirty       | none         |
| E     | Exclusive                        | clean       | none         |
| S     | Shared                           | clean       | maybe        |
| I     | Invalid                          | -           | -            |

The interesting engineering lives in the **transient states** — the intermediate
states a line passes through while a bus transaction is outstanding — which is
where most real coherence bugs hide.

## Roadmap

| Milestone | Content | Status |
|-----------|---------|--------|
| **M0** | Repo scaffold + single L1 (CPU side), write-back/write-allocate, self-checking sanity test | done |
| **M1** | Snoop bus + round-robin arbiter, 2 caches, stable MESI transitions, self-checking state+data test | done |
| **M2** | Concurrent-request race resolution + continuous coherence-invariant checker | done |
| **M3** | Scale to 4 cores + standalone bus monitor (invariant + data-value scoreboard) + randomized stress | done |
| **M4** | FPGA synthesis (ZCU104) PPA + protocol state diagram & waveforms | planned |

### M1 design notes

The bus is **atomic** (one coherence transaction at a time) and acts as the
coherence point: it arbitrates (round-robin), broadcasts the request to the
other caches, gathers their snoop response, flushes a dirty owner to memory when
needed, performs the fill/writeback, then commits. A wired-OR **shared** signal
picks E vs S on a read miss. Data currently migrates through memory (a dirty
snooper flushes, the requester then reads); direct cache-to-cache forwarding and
overlapping transactions with transient states arrive in M2.

### M2 design notes

The bus stays atomic, but caches may now issue requests **simultaneously**,
which exposes the real coherence races:

* **Concurrent conflicting upgrade** — two cores in S both want M. The arbiter
  grants one `BusUpgr`, which invalidates the other *while it is mid-upgrade*.
  The loser detects that its shared copy is gone and converts its `BusUpgr`
  into a full `BusRdX` to re-acquire the line with ownership, rather than
  silently (and incorrectly) promoting a stale copy to M.
* **Snoop-vs-lookup** — if a snoop commits a change to the exact line the CPU
  side is examining that cycle, the lookup decision is deferred one cycle and
  remade against the updated state.

Correctness is checked two ways: deterministic per-scenario state/data asserts,
and a **continuous invariant checker** that peeks both caches every cycle and
flags any line resident in two cores in a state other than Shared/Shared
(catches any single-writer or exclusivity violation). Run `sim\run_m2.bat`.

### M3 design notes

M3 scales the system to 4 cores and drives it with **randomized concurrent
stress**: each core runs an independent stream of loads/stores over a small
shared address pool (deliberately including addresses that alias to the same
set, to force evictions and coherence traffic). Every store writes a globally
unique value so data can be tracked exactly.

The proof is a standalone, passive **`bus_monitor`** (instantiated under a
`synthesis translate_off` guard, so it never synthesizes) that checks two
properties against the live traffic:

1. **Coherence / exclusivity invariant** — every cycle, over every set, no two
   caches may hold the same line unless *both* are Shared. This catches any
   two-Modified, Modified+Shared, or Exclusive-with-a-copy state.
2. **Data value (interval-ordered)** — a golden model of each word derived from
   the CPU request/response ports. Because a slow bus read and a fast silent
   store can have their responses reordered relative to their true coherence
   order, the scoreboard orders stores by their `[accept, complete]` intervals
   rather than by response arrival, and admits a load if its value was legal at
   any point during the load's own lifetime. This is exact enough to flag real
   staleness and phantom values, without false failures from benign reordering.

**A real bug the value scoreboard caught.** The invariant checker (state only)
stayed green, but the value scoreboard flagged loads returning stale data:
snapshots showed three caches all in **Shared** yet holding **two different
values** — a value-incoherence that a state-only check is structurally blind to.
Root cause: a local write-hit could complete *silently* (M→M / E→M) on a line
while another core's `BusRd` for that same line was already in flight on the
atomic bus, so the cache flushed the pre-write value to the new sharers but kept
the newer value locally. The fix holds a CPU lookup in place for the **whole**
in-flight snoop window on that line (not just the commit cycle), so the write is
remade against the post-transaction state and correctly takes the `BusUpgr` /
`BusRdX` path. Run `sim\run_m3.bat`.

## Repository layout

```
rtl/    synthesizable SystemVerilog (package, memory model, L1 cache)
tb/     testbenches
sim/    simulation run scripts
docs/   protocol diagrams and notes
```

## Running the tests (Vivado xsim)

With the Vivado `bin` directory on `PATH`, from the project root:

```
sim\run_m1.bat
```

Expected tail of the log:

```
==== M1 TEST PASSED ====
```
