// -----------------------------------------------------------------------------
// tb_race.sv  (M2: concurrent-request races)
//
// Fires two cores' requests in the SAME cycle to provoke the coherence races
// M2 must resolve, and checks correctness two ways:
//   * a continuous invariant checker peeks both caches every cycle -- if the
//     same physical line (set+tag) is cached in two cores, both must be Shared;
//   * per-scenario state + data checks confirm the deterministic outcome.
//
// Scenario 1 -- concurrent conflicting upgrade (the headline race):
//   both cores hold X Shared, then both write X in the same cycle. The arbiter
//   grants core0's BusUpgr first (-> M), which invalidates core1 mid-upgrade;
//   core1 must convert its BusUpgr into a BusRdX, re-acquire the line and end
//   as the sole owner. Final: core0 I, core1 M(core1's value).
//
// Scenario 2 -- silent E->M racing a remote write:
//   core0 holds Z Exclusive and writes it (silent E->M) while core1 writes Z
//   the same cycle (miss -> BusRdX). core1's BusRdX invalidates core0 and
//   flushes core0's dirty data. Final: core0 I, core1 M(core1's value).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_race
  import mesi_pkg::*;
;

  localparam int N         = 2;
  localparam int MEM_WORDS = 1024;

  logic clk = 0;
  logic rst_n;
  always #5 clk = ~clk;

  logic                  cpu_req_valid  [N];
  logic                  cpu_req_ready  [N];
  logic                  cpu_req_we     [N];
  logic [ADDR_WIDTH-1:0] cpu_req_addr   [N];
  logic [DATA_WIDTH-1:0] cpu_req_wdata  [N];
  logic                  cpu_resp_valid [N];
  logic [DATA_WIDTH-1:0] cpu_resp_rdata [N];

  coherent_system #(.N(N), .MEM_WORDS(MEM_WORDS), .READ_LATENCY(2)) dut (
    .clk, .rst_n,
    .cpu_req_valid, .cpu_req_ready, .cpu_req_we, .cpu_req_addr, .cpu_req_wdata,
    .cpu_resp_valid, .cpu_resp_rdata
  );

  int errors = 0;

  // ---- Single request on one core ----
  task automatic core_op(input int id, input logic we,
                         input logic [ADDR_WIDTH-1:0] addr,
                         input logic [DATA_WIDTH-1:0] wdata,
                         output logic [DATA_WIDTH-1:0] rdata);
    @(posedge clk);
    cpu_req_valid[id] <= 1'b1; cpu_req_we[id] <= we;
    cpu_req_addr[id]  <= addr; cpu_req_wdata[id] <= wdata;
    do @(posedge clk); while (!cpu_resp_valid[id]);
    rdata             = cpu_resp_rdata[id];
    cpu_req_valid[id] <= 1'b0;
    @(posedge clk);
  endtask

  // ---- Two requests launched in the SAME cycle ----
  task automatic dual_op(input logic we0, input logic [ADDR_WIDTH-1:0] a0, input logic [DATA_WIDTH-1:0] d0,
                         input logic we1, input logic [ADDR_WIDTH-1:0] a1, input logic [DATA_WIDTH-1:0] d1,
                         output logic [DATA_WIDTH-1:0] r0, output logic [DATA_WIDTH-1:0] r1);
    @(posedge clk);
    cpu_req_valid[0] <= 1'b1; cpu_req_we[0] <= we0; cpu_req_addr[0] <= a0; cpu_req_wdata[0] <= d0;
    cpu_req_valid[1] <= 1'b1; cpu_req_we[1] <= we1; cpu_req_addr[1] <= a1; cpu_req_wdata[1] <= d1;
    fork
      begin do @(posedge clk); while (!cpu_resp_valid[0]); r0 = cpu_resp_rdata[0]; cpu_req_valid[0] <= 1'b0; end
      begin do @(posedge clk); while (!cpu_resp_valid[1]); r1 = cpu_resp_rdata[1]; cpu_req_valid[1] <= 1'b0; end
    join
    @(posedge clk);
  endtask

  task automatic rd_chk(input int id, input logic [ADDR_WIDTH-1:0] a, input logic [DATA_WIDTH-1:0] exp);
    logic [DATA_WIDTH-1:0] d;
    core_op(id, 1'b0, a, '0, d);
    if (d !== exp) begin errors++; $error("C%0d rd @%08h got=%08h exp=%08h", id, a, d, exp); end
    else $display("[%0t] C%0d rd @%08h => %08h  OK", $time, id, a, d);
  endtask

  function automatic mesi_e core_state(input int id, input logic [ADDR_WIDTH-1:0] a);
    case (id)
      0: return dut.g_core[0].u_cache.state_q[addr_index(a)];
      1: return dut.g_core[1].u_cache.state_q[addr_index(a)];
      default: return I;
    endcase
  endfunction

  task automatic chk_state(input int id, input logic [ADDR_WIDTH-1:0] a, input mesi_e exp);
    mesi_e g;
    g = core_state(id, a);
    if (g !== exp) begin errors++; $error("state C%0d set%0d = %s exp %s", id, addr_index(a), g.name(), exp.name()); end
    else $display("        state C%0d set%0d = %s  OK", id, addr_index(a), g.name());
  endtask

  // ---- Continuous coherence invariant over every set ----
  // If the same line (set+tag) is resident in both caches, both must be Shared.
  always @(posedge clk) if (rst_n) begin
    for (int s = 0; s < NUM_SETS; s++) begin
      mesi_e             a, b;
      logic [TAG_BITS-1:0] ta, tb;
      a  = dut.g_core[0].u_cache.state_q[s];
      b  = dut.g_core[1].u_cache.state_q[s];
      ta = dut.g_core[0].u_cache.tag_q[s];
      tb = dut.g_core[1].u_cache.tag_q[s];
      if (a != I && b != I && ta == tb && !(a == S && b == S)) begin
        errors++;
        $error("COHERENCE INVARIANT VIOLATED: set%0d resident in both cores as %s/%s", s, a.name(), b.name());
      end
    end
  end

  localparam logic [ADDR_WIDTH-1:0] X = 32'h0000_0040;   // set 0
  localparam logic [ADDR_WIDTH-1:0] Z = 32'h0000_0044;   // set 1

  logic [DATA_WIDTH-1:0] r0, r1;

  initial begin
    for (int i = 0; i < N; i++) begin
      cpu_req_valid[i] = 0; cpu_req_we[i] = 0; cpu_req_addr[i] = 0; cpu_req_wdata[i] = 0;
    end
    for (int i = 0; i < MEM_WORDS; i++) dut.u_mem.mem[i] = 32'hDEAD_0000 + i;

    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ============ Scenario 1: concurrent conflicting upgrade ============
    $display("--- Scenario 1: concurrent conflicting upgrade on X ---");
    rd_chk(0, X, 32'hDEAD_0010);          // C0: E
    rd_chk(1, X, 32'hDEAD_0010);          // both: S
    chk_state(0, X, S); chk_state(1, X, S);

    dual_op(1'b1, X, 32'hA5A5_A5A5,       // both write X in the same cycle
            1'b1, X, 32'h5A5A_5A5A, r0, r1);
    // C0 wins the upgrade first; C1 loses, converts to BusRdX and ends sole owner.
    chk_state(0, X, I);
    chk_state(1, X, M);
    rd_chk(0, X, 32'h5A5A_5A5A);          // both cores agree on C1's value
    chk_state(0, X, S); chk_state(1, X, S);

    // ============ Scenario 2: silent E->M racing a remote write ============
    $display("--- Scenario 2: silent E->M racing a remote BusRdX on Z ---");
    rd_chk(0, Z, 32'hDEAD_0011);          // C0: E (sole copy)
    chk_state(0, Z, E);

    dual_op(1'b1, Z, 32'hF00D_F00D,       // C0 writes (E->M) while C1 writes (miss->BusRdX)
            1'b1, Z, 32'hBEEF_BEEF, r0, r1);
    chk_state(0, Z, I);
    chk_state(1, Z, M);
    rd_chk(0, Z, 32'hBEEF_BEEF);          // both agree on C1's value
    chk_state(0, Z, S); chk_state(1, Z, S);

    repeat (4) @(posedge clk);
    if (errors == 0) $display("\n==== M2 RACE TEST PASSED ====\n");
    else             $display("\n==== M2 RACE TEST FAILED (%0d errors) ====\n", errors);
    $finish;
  end

  initial begin
    #300000;
    $error("TIMEOUT");
    $finish;
  end

  initial begin
    $dumpfile("tb_race.vcd");
    $dumpvars(0, tb_race);
  end

endmodule
