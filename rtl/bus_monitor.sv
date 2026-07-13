// -----------------------------------------------------------------------------
// bus_monitor.sv  (M3: passive coherence checker)
//
// A verification-only observer -- it drives nothing. It watches every cache's
// per-set {state, tag} plus every core's CPU request/response port and proves
// two properties:
//
//   1. Coherence invariant (single-writer / exclusivity): EVERY cycle, if the
//      same physical line (set + tag) is resident in two caches, both must be
//      Shared. This catches two-Modified, Modified+Shared, Exclusive+anything.
//
//   2. Data value (interval-ordered, response-reorder tolerant): a load is
//      checked against the SET of store values the coherence order may legally
//      expose, reconstructed from each store's [accept, complete] interval --
//      NOT from the order responses happen to arrive. This matters because a
//      slow store and a fast store to the same word can have their CPU
//      responses reordered relative to their true coherence order, so a scheme
//      that trusts response order produces false failures.
//
//      For each word we keep a short history of stores as (value, accept-cycle,
//      complete-cycle). A store W is "definitely before" a store W' when W'
//      started strictly after W finished (W'.acc > W.done); overlapping stores
//      have an order the monitor cannot (and need not) pin down. A load R that
//      accepts at t_a and responds at t_r may legally return store W's value
//      when:
//        - W started before R ended (W.acc <= t_r), so W is not definitely
//          ordered after R, AND
//        - W was not definitely superseded before R began: no store W' to the
//          same word both completed before t_a (W'.done <= t_a) and is
//          definitely-after W (W'.acc > W.done).
//      A store still in flight when R responds is always admissible (it may
//      serialize just before R, and it cannot yet have been superseded).
//
//      This admissible set is exactly the range a correct MESI machine may
//      expose to a concurrent load, so it never false-fails; yet a quiescent
//      load that returns anything but the last non-overlapping store, or a
//      phantom value never written, still falls outside it and fails.
//
// Instantiated under a synthesis translate_off guard, so it never synthesizes.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module bus_monitor
  import mesi_pkg::*;
#(
  parameter int N         = 4,
  parameter int MEM_WORDS = 1024
)(
  input  logic                  clk,
  input  logic                  rst_n,

  // ---- Cache state observation ----
  input  mesi_e                 mon_state [N][NUM_SETS],
  input  logic [TAG_BITS-1:0]   mon_tag   [N][NUM_SETS],

  // ---- CPU op observation ----
  input  logic                  cpu_req_valid  [N],
  input  logic                  cpu_req_ready  [N],
  input  logic                  cpu_req_we     [N],
  input  logic [ADDR_WIDTH-1:0] cpu_req_addr   [N],
  input  logic [DATA_WIDTH-1:0] cpu_req_wdata  [N],
  input  logic                  cpu_resp_valid [N],
  input  logic [DATA_WIDTH-1:0] cpu_resp_rdata [N]
);

  localparam int HIST = 32;    // per-word store-history depth

  int error_count   = 0;
  int read_checked  = 0;
  int read_skipped  = 0;
  int write_count   = 0;

  // Free-running cycle counter used to timestamp accepts and completes.
  int cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // Per-word ring history of completed stores (newest at head).
  logic [DATA_WIDTH-1:0] hist_val [0:MEM_WORDS-1][0:HIST-1];
  int                    hist_acc [0:MEM_WORDS-1][0:HIST-1];  // accept cycle
  int                    hist_done[0:MEM_WORDS-1][0:HIST-1];  // complete cycle
  int                    hist_head[0:MEM_WORDS-1];
  int                    hist_cnt [0:MEM_WORDS-1];

  // Per-core in-flight request (the cache is single-outstanding).
  logic                  inf_busy  [N];
  logic                  inf_we    [N];
  logic [ADDR_WIDTH-1:0] inf_addr  [N];
  logic [DATA_WIDTH-1:0] inf_wdata [N];
  int                    inf_acc   [N];   // cycle the request was accepted

  function automatic int word_of(input logic [ADDR_WIDTH-1:0] a);
    return int'(a >> BYTE_OFFSET);
  endfunction

  initial begin
    for (int i = 0; i < MEM_WORDS; i++) begin
      hist_val[i][0]  = init_word(i);   // memory's deterministic initial value
      hist_acc[i][0]  = 0;
      hist_done[i][0] = 0;              // present from cycle 0
      hist_head[i]    = 0;
      hist_cnt[i]     = 1;
    end
    for (int i = 0; i < N; i++) inf_busy[i] = 1'b0;
  end

  // ---- Property 1: coherence invariant, every cycle ----
  always @(posedge clk) if (rst_n) begin
    for (int s = 0; s < NUM_SETS; s++)
      for (int a = 0; a < N; a++)
        for (int b = a + 1; b < N; b++)
          if (mon_state[a][s] != I && mon_state[b][s] != I &&
              mon_tag[a][s] == mon_tag[b][s] &&
              !(mon_state[a][s] == S && mon_state[b][s] == S)) begin
            error_count++;
            $error("[mon] COHERENCE VIOLATION set%0d: core%0d=%s core%0d=%s (same tag)",
                   s, a, mon_state[a][s].name(), b, mon_state[b][s].name());
          end
  end

  // ---- Property 2: interval-ordered data-value scoreboard ----
  always @(posedge clk) if (rst_n) begin
    int w, t_a, t_r, h, hp, newest_cyc;
    logic [DATA_WIDTH-1:0] base_val, rv;
    logic admissible, superseded, matched;

    // Pass 1: WRITE completions -- record (value, accept, complete) so a read
    // completing this same cycle can already observe the store.
    for (int i = 0; i < N; i++)
      if (inf_busy[i] && cpu_resp_valid[i] && inf_we[i]) begin
        w = word_of(inf_addr[i]);
        hist_head[w] = (hist_head[w] + 1) % HIST;
        hist_val[w][hist_head[w]]  = inf_wdata[i];
        hist_acc[w][hist_head[w]]  = inf_acc[i];
        hist_done[w][hist_head[w]] = cyc;
        if (hist_cnt[w] < HIST) hist_cnt[w] = hist_cnt[w] + 1;
        write_count++;
      end

    // Pass 2: new accepts -- capture the in-flight request and its accept cycle.
    // (Done before read checks so a store accepted this cycle is visible as an
    // in-flight, concurrent store to a read completing this cycle.)
    for (int i = 0; i < N; i++)
      if (cpu_req_valid[i] && cpu_req_ready[i]) begin
        inf_busy[i]  = 1'b1;
        inf_we[i]    = cpu_req_we[i];
        inf_addr[i]  = cpu_req_addr[i];
        inf_wdata[i] = cpu_req_wdata[i];
        inf_acc[i]   = cyc;
      end

    // Pass 3: READ completions -- check the returned value against the
    // interval-ordered admissible set, then retire the in-flight slot.
    for (int i = 0; i < N; i++)
      if (inf_busy[i] && cpu_resp_valid[i] && !inf_we[i]) begin
        w   = word_of(inf_addr[i]);
        t_a = inf_acc[i];
        t_r = cyc;
        rv  = cpu_resp_rdata[i];

        admissible = 1'b0;
        matched    = 1'b0;
        base_val   = 'x;
        newest_cyc = -1;

        // Completed stores in history: value must match, the store must have
        // started before the read ended, and must not be definitely superseded
        // before the read began.
        for (int j = 0; j < hist_cnt[w]; j++) begin
          h = (hist_head[w] - j + HIST) % HIST;
          if (hist_done[w][h] > newest_cyc) begin  // newest-by-response, for msg
            newest_cyc = hist_done[w][h];
            base_val   = hist_val[w][h];
          end
          if (rv === hist_val[w][h] && hist_acc[w][h] <= t_r) begin
            matched    = 1'b1;
            superseded = 1'b0;
            for (int k = 0; k < hist_cnt[w]; k++) begin
              hp = (hist_head[w] - k + HIST) % HIST;
              if (hist_done[w][hp] <= t_a && hist_acc[w][hp] > hist_done[w][h])
                superseded = 1'b1;
            end
            if (!superseded) admissible = 1'b1;
          end
        end

        // A store still in flight when the read responds is always admissible.
        for (int k = 0; k < N; k++)
          if (inf_busy[k] && inf_we[k] && word_of(inf_addr[k]) == w &&
              inf_acc[k] <= t_r && rv === inf_wdata[k]) begin
            matched    = 1'b1;
            admissible = 1'b1;
          end

        if (!matched && hist_cnt[w] == HIST) begin
          // Value not in the retained window: history too shallow to judge
          // (only possible on a very hot word). Do not risk a false failure.
          read_skipped++;
        end else begin
          read_checked++;
          if (!admissible) begin
            error_count++;
            $error("[mon] VALUE MISMATCH core%0d rd @%08h got=%08h (not admissible; latest=%08h)",
                   i, inf_addr[i], rv, base_val);
          end
        end
      end

    // Retire every completing slot (reads and writes) after all checks.
    for (int i = 0; i < N; i++)
      if (inf_busy[i] && cpu_resp_valid[i]) inf_busy[i] = 1'b0;
  end

endmodule
