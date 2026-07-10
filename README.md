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
| **M1** | Snoop bus + arbiter, 2 caches, stable MESI transitions | planned |
| **M2** | Transient states + races (concurrent upgrades, snoop-hit on in-flight line) | planned |
| **M3** | Scale to 4 cores + bus-monitor invariant checker + randomized stress | planned |
| **M4** | FPGA synthesis (ZCU104) PPA + protocol state diagram & waveforms | planned |

## Repository layout

```
rtl/    synthesizable SystemVerilog (package, memory model, L1 cache)
tb/     testbenches
sim/    simulation run scripts
docs/   protocol diagrams and notes
```

## Running the M0 test (Vivado xsim)

With the Vivado `bin` directory on `PATH`:

```
sim\run_m0.bat
```

Expected tail of the log:

```
==== M0 TEST PASSED ====
```
