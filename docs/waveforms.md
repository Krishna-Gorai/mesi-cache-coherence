# Annotated protocol trace

A deterministic two-core scenario (`tb/tb_trace.sv`) walks a single line through
the **entire MESI lifecycle**, exercising every bus command. Regenerate it with
`sim\run_m4_trace.bat`; the same run also writes `trace.vcd` for a waveform
viewer.

Two addresses are used: **A = `0x40`** and **B = `0x80`**. Both map to set 0 but
carry different tags, so accessing B evicts A — and when A is dirty that eviction
forces a `BusWB`.

The table shows, after each CPU operation, the returned read data and both
caches' `{state, data}` for set 0, plus the two backing memory words. (`x` data
in an Invalid line is don't-care.)

| # | operation      | rdata    | core0 (set0)   | core1 (set0)   | mem[A]   | mem[B]   |
|--:|----------------|----------|----------------|----------------|----------|----------|
| 1 | c0 Rd A        | dead0010 | E / dead0010   | I / --------   | dead0010 | dead0020 |
| 2 | c0 Wr A=A5     | aaaa00a5 | M / aaaa00a5   | I / --------   | dead0010 | dead0020 |
| 3 | c1 Rd A        | aaaa00a5 | S / aaaa00a5   | S / aaaa00a5   | aaaa00a5 | dead0020 |
| 4 | c1 Wr A=B6     | bbbb00b6 | I / --------   | M / bbbb00b6   | aaaa00a5 | dead0020 |
| 5 | c0 Rd A        | bbbb00b6 | S / bbbb00b6   | S / bbbb00b6   | bbbb00b6 | dead0020 |
| 6 | c0 Wr A=D8     | dddd00d8 | M / dddd00d8   | I / --------   | bbbb00b6 | dead0020 |
| 7 | c0 Rd B        | dead0020 | E / dead0020   | I / --------   | dddd00d8 | dead0020 |

### Step-by-step

1. **c0 Rd A** — read miss from Invalid. `BusRd`; no other cache holds A
   (`shared`=0), so core0 installs **E** with memory's value.
2. **c0 Wr A** — write hit in E. **Silent E→M**: no bus traffic, memory stays
   stale (`dead0010`) because the policy is write-back.
3. **c1 Rd A** — read miss. `BusRd` snoops core0's **M**, which flushes its dirty
   data to memory and downgrades **M→S**; core1 installs **S**. Both caches now
   share `aaaa00a5` and memory is up to date.
4. **c1 Wr A** — write hit in S. `BusUpgr` invalidates the other sharer
   (**core0 S→I**) with no data movement; **core1 S→M** holds `bbbb00b6`.
5. **c0 Rd A** — read miss again. `BusRd` snoops core1's **M**, flushing
   `bbbb00b6` to memory (**core1 M→S**); core0 re-installs **S**.
6. **c0 Wr A** — write hit in S. `BusUpgr` again: **core1 S→I**, **core0 S→M**
   with `dddd00d8`.
7. **c0 Rd B** — B maps to the same set, so it evicts A. A is **M** (dirty), so
   the cache first issues **`BusWB`** (memory[A] becomes `dddd00d8` — writeback
   persistence), then `BusRd` for B and installs **E**.

Every stable state (M, E, S, I) and every bus command (`BusRd`, `BusRdX` on the
write-miss path, `BusUpgr`, `BusWB`) appears here. The randomized 4-core stress
(`tb/tb_stress.sv`) then drives thousands of these transitions concurrently
under the continuous coherence and data-value checks in `bus_monitor.sv`.
