// -----------------------------------------------------------------------------
// tb_coherent_system.sv  (M1 sanity)
//
// Two cores over the snoop bus, walked through every stable MESI transition.
// After each step the testbench checks both the resulting per-core line state
// (peeked hierarchically) and, on reads, the returned data against a golden
// shadow -- so the migration of dirty data between caches is proven correct.
//
// Scenario (X and Y map to the same set; different tags -> a conflict):
//   1. C0 rd X            -> C0:E                (no other copy)
//   2. C1 rd X            -> C0:S  C1:S          (BusRd downgrades E->S)
//   3. C0 wr X=AAAA       -> C0:M  C1:I          (BusUpgr invalidates the sharer)
//   4. C1 rd X            -> C0:S  C1:S, data=AAAA (M flushes, both Shared)
//   5. C1 wr X=BBBB       -> C0:I  C1:M
//   6. C0 rd X            -> C0:S  C1:S, data=BBBB
//   7. C0 wr X=CCCC       -> C0:M  C1:I
//   8. C0 rd Y            -> evict dirty X (writeback), C0:E on Y
//   9. C1 rd X            -> C1:E, data=CCCC       (proves the writeback persisted)
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_coherent_system
  import mesi_pkg::*;
;

  localparam int N         = 2;
  localparam int MEM_WORDS = 1024;

  logic clk = 0;
  logic rst_n;
  always #5 clk = ~clk;                                // 100 MHz

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

  // ---- CPU driver ----
  task automatic core_op(input int id, input logic we,
                         input logic [ADDR_WIDTH-1:0] addr,
                         input logic [DATA_WIDTH-1:0] wdata,
                         output logic [DATA_WIDTH-1:0] rdata);
    @(posedge clk);
    cpu_req_valid[id] <= 1'b1;
    cpu_req_we[id]    <= we;
    cpu_req_addr[id]  <= addr;
    cpu_req_wdata[id] <= wdata;
    do @(posedge clk); while (!cpu_resp_valid[id]);
    rdata             = cpu_resp_rdata[id];
    cpu_req_valid[id] <= 1'b0;
    @(posedge clk);
  endtask

  task automatic rd_chk(input int id, input logic [ADDR_WIDTH-1:0] a, input logic [DATA_WIDTH-1:0] exp);
    logic [DATA_WIDTH-1:0] d;
    core_op(id, 1'b0, a, '0, d);
    if (d !== exp) begin
      errors++;
      $error("C%0d rd @%08h got=%08h exp=%08h", id, a, d, exp);
    end else
      $display("[%0t] C%0d rd @%08h => %08h  OK", $time, id, a, d);
  endtask

  task automatic wr(input int id, input logic [ADDR_WIDTH-1:0] a, input logic [DATA_WIDTH-1:0] data);
    logic [DATA_WIDTH-1:0] d;
    core_op(id, 1'b1, a, data, d);
    $display("[%0t] C%0d wr @%08h <= %08h", $time, id, a, data);
  endtask

  // ---- Peek a core's line state and check it ----
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
    if (g !== exp) begin
      errors++;
      $error("state C%0d set%0d = %s  exp %s", id, addr_index(a), g.name(), exp.name());
    end else
      $display("        state C%0d set%0d = %s  OK", id, addr_index(a), g.name());
  endtask

  // ---- Continuous single-writer invariant on the set of interest ----
  always @(posedge clk) if (rst_n) begin
    if (core_state(0, 32'h40) == M && core_state(1, 32'h40) == M) begin
      errors++;
      $error("SWMR VIOLATION: both cores Modified on set 0");
    end
  end

  localparam logic [ADDR_WIDTH-1:0] X = 32'h0000_0040;               // set 0, tag A
  localparam logic [ADDR_WIDTH-1:0] Y = X + (NUM_SETS << BYTE_OFFSET); // set 0, tag B

  initial begin
    for (int i = 0; i < N; i++) begin
      cpu_req_valid[i] = 0; cpu_req_we[i] = 0;
      cpu_req_addr[i]  = 0; cpu_req_wdata[i] = 0;
    end
    // Known backing-store contents.
    for (int i = 0; i < MEM_WORDS; i++) dut.u_mem.mem[i] = 32'hDEAD_0000 + i;

    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // 1. C0 read X: no other copy -> Exclusive
    rd_chk   (0, X, 32'hDEAD_0010);
    chk_state(0, X, E);

    // 2. C1 read X: C0 has it -> both Shared
    rd_chk   (1, X, 32'hDEAD_0010);
    chk_state(0, X, S);
    chk_state(1, X, S);

    // 3. C0 write X: S -> M via BusUpgr, C1 invalidated
    wr       (0, X, 32'hAAAA_AAAA);
    chk_state(0, X, M);
    chk_state(1, X, I);

    // 4. C1 read X: C0 flushes M, both Shared, C1 sees the new value
    rd_chk   (1, X, 32'hAAAA_AAAA);
    chk_state(0, X, S);
    chk_state(1, X, S);

    // 5. C1 write X: S -> M, C0 invalidated
    wr       (1, X, 32'hBBBB_BBBB);
    chk_state(0, X, I);
    chk_state(1, X, M);

    // 6. C0 read X: C1 flushes M, both Shared
    rd_chk   (0, X, 32'hBBBB_BBBB);
    chk_state(0, X, S);
    chk_state(1, X, S);

    // 7. C0 write X: S -> M, C1 invalidated
    wr       (0, X, 32'hCCCC_CCCC);
    chk_state(0, X, M);
    chk_state(1, X, I);

    // 8. C0 read Y (same set, other tag): evict dirty X (writeback), fill Y as E
    rd_chk   (0, Y, 32'hDEAD_0020);
    chk_state(0, Y, E);

    // 9. C1 read X: X is gone from C0 -> C1 gets E and the written-back CCCC
    rd_chk   (1, X, 32'hCCCC_CCCC);
    chk_state(1, X, E);

    repeat (4) @(posedge clk);
    if (errors == 0) $display("\n==== M1 TEST PASSED ====\n");
    else             $display("\n==== M1 TEST FAILED (%0d errors) ====\n", errors);
    $finish;
  end

  initial begin
    #200000;
    $error("TIMEOUT");
    $finish;
  end

  initial begin
    $dumpfile("tb_coherent_system.vcd");
    $dumpvars(0, tb_coherent_system);
  end

endmodule
