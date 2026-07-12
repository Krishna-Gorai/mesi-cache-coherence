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
| **M2** | Transient states + races (concurrent upgrades, snoop-hit on in-flight line) | planned |
| **M3** | Scale to 4 cores + bus-monitor invariant checker + randomized stress | planned |
| **M4** | FPGA synthesis (ZCU104) PPA + protocol state diagram & waveforms | planned |

### M1 design notes

The bus is **atomic** (one coherence transaction at a time) and acts as the
coherence point: it arbitrates (round-robin), broadcasts the request to the
other caches, gathers their snoop response, flushes a dirty owner to memory when
needed, performs the fill/writeback, then commits. A wired-OR **shared** signal
picks E vs S on a read miss. Data currently migrates through memory (a dirty
snooper flushes, the requester then reads); direct cache-to-cache forwarding and
overlapping transactions with transient states arrive in M2.

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
