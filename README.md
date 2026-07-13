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
| **M4** | FPGA synthesis (ZCU104) PPA + protocol state diagram & annotated waveforms | done |

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

### M4: synthesis PPA, protocol diagram, waveforms

**Protocol and waveforms.** [`docs/protocol.md`](docs/protocol.md) is the full
MESI specification — state/command tables and Mermaid state diagrams for the
processor side, the snoop side, and the atomic bus sequencer, each matching the
RTL. [`docs/waveforms.md`](docs/waveforms.md) is an annotated trace
(`tb/tb_trace.sv`, run via `sim\run_m4_trace.bat`) that walks one line through
the entire lifecycle — E, silent E→M, M→S flush, `BusUpgr`, a second flush, and
a dirty eviction `BusWB` — exercising every bus command; the run also writes
`trace.vcd`.

**FPGA PPA.** The coherence unit — the four L1 caches plus the snoop bus, with
the next memory level left at the boundary (`rtl/coherence_unit.sv`) — was
synthesized out-of-context for the ZCU104 (Zynq UltraScale+ **xczu7ev**) via
`sim\synth_ooc.tcl`. Reports are in [`reports_synth/`](reports_synth).

| Metric (4 cores) | Value |
|------------------|-------|
| LUTs             | 3,430 (≈ 750–785 per cache, 365 for the bus) |
| Flip-flops       | 4,392 |
| BRAM / DSP       | 0 / 0 |
| Timing           | meets a 200 MHz (5.0 ns) constraint, WNS **+2.78 ns**, 0 failing endpoints |
| On-chip power    | 0.642 W (0.05 dynamic + 0.59 static) |

The tag/state/data arrays (16 sets × 4 cores) map to registers rather than
block RAM, so the unit is FF-heavy but BRAM-free and compact. Timing is the
out-of-context estimate (the OOC clock network is not modelled); a full
in-context implementation would refine it. Run all functional tests with
`sim\run_m2.bat` and `sim\run_m3.bat`.

## Repository layout

```
rtl/            synthesizable SystemVerilog (package, memory model, L1 cache,
                snoop bus, coherent system, coherence-unit synth wrapper) +
                bus_monitor (verification-only, synthesis-excluded)
tb/             testbenches (directed, race, 4-core stress, lifecycle trace)
sim/            run scripts, OOC synthesis, Vivado project generator
docs/           protocol reference + annotated waveforms
reports_synth/  ZCU104 utilization / timing / power reports
```

## Running the tests (Vivado xsim)

With the Vivado `bin` directory on `PATH`, from the project root:

```
sim\run_m1.bat        directed stable-transition regression
sim\run_m2.bat        + concurrent-request races
sim\run_m3.bat        4-core randomized stress under the bus monitor
sim\run_m4_trace.bat  annotated MESI lifecycle trace (+ trace.vcd)
```

Expected tail of, e.g., the M3 log:

```
==== M3 STRESS TEST PASSED ====
```

## Exploring in the Vivado GUI

To browse the design as a schematic and watch the waveforms interactively,
generate a Vivado project (targets the ZCU104, `xczu7ev`):

```
sim\create_vivado_project.bat
```

Then open `vivado_prj\mesi_coherence.xpr` and:

* **See the design** — *Flow Navigator → RTL Analysis → Open Elaborated Design*
  shows the schematic of `coherent_system` (four caches, the snoop bus and
  memory). Cross-probe modules from the *Sources* pane.
* **See the waveforms** — *Flow Navigator → Simulation → Run Simulation → Run
  Behavioral Simulation* elaborates and opens the waveform viewer. It defaults
  to `tb_trace` (the short lifecycle walk); to run a different testbench,
  right-click one under *Sources → Simulation Sources* and *Set as Top*. Add any
  internal signal to the wave window (e.g. `dut/g_core[0]/u_cache/state_q`).

The generated `vivado_prj/` directory is disposable and git-ignored — re-run the
script anytime to rebuild it.
