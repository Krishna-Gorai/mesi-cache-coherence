// -----------------------------------------------------------------------------
// tb_stress.sv  (M3: randomized 4-core coherence stress)
//
// Four cores each run an independent random stream of loads/stores over a small
// shared address pool (deliberately including several addresses that alias to
// the same set, to force conflicts, evictions and coherence traffic). The
// streams run concurrently, so the bus sees heavy contention and the races from
// M2 fire constantly.
//
// Every store writes a system-globally-unique value, so the built-in
// bus_monitor's golden scoreboard can check that every load returns exactly the
// last completed store to that address, while its invariant checker proves the
// single-writer / exclusivity property every cycle. This testbench itself only
// drives stimulus and reads the monitor's counters at the end.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_stress
  import mesi_pkg::*;
;

  localparam int N         = 4;
  localparam int MEM_WORDS = 1024;
  localparam int NOPS      = 400;      // per core
  localparam int WRITE_PCT = 45;

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

  // Shared address pool: 0x40/0x80/0xC0 alias to set 0 (conflict + coherence),
  // the rest spread across sets 1..3.
  localparam int POOL_N = 8;
  logic [ADDR_WIDTH-1:0] pool [POOL_N] = '{
    32'h0000_0040, 32'h0000_0080, 32'h0000_00C0,   // set 0 (alias)
    32'h0000_0044, 32'h0000_0084,                  // set 1 (alias)
    32'h0000_0048,                                  // set 2
    32'h0000_004C,                                  // set 3
    32'h0000_0050                                   // set 4
  };

  task automatic core_op(input int id, input logic we,
                         input logic [ADDR_WIDTH-1:0] addr,
                         input logic [DATA_WIDTH-1:0] wdata);
    @(posedge clk);
    cpu_req_valid[id] <= 1'b1; cpu_req_we[id] <= we;
    cpu_req_addr[id]  <= addr; cpu_req_wdata[id] <= wdata;
    do @(posedge clk); while (!cpu_resp_valid[id]);
    cpu_req_valid[id] <= 1'b0;
    @(posedge clk);
  endtask

  // One core's random stream. Each store value is unique: {core, seq}.
  task automatic core_stream(input int id);
    logic                  we;
    logic [ADDR_WIDTH-1:0] a;
    logic [DATA_WIDTH-1:0] v;
    for (int i = 0; i < NOPS; i++) begin
      a  = pool[$urandom_range(POOL_N-1)];
      we = ($urandom_range(99) < WRITE_PCT);
      v  = {id[7:0], 24'(i)};
      core_op(id, we, a, we ? v : '0);
    end
  endtask

  initial begin
    for (int i = 0; i < N; i++) begin
      cpu_req_valid[i] = 0; cpu_req_we[i] = 0; cpu_req_addr[i] = 0; cpu_req_wdata[i] = 0;
    end

    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    $display("Running %0d cores x %0d ops over %0d shared addresses...", N, NOPS, POOL_N);

    fork
      core_stream(0);
      core_stream(1);
      core_stream(2);
      core_stream(3);
    join

    repeat (8) @(posedge clk);

    $display("\n---- monitor summary ----");
    $display("  writes tracked      : %0d", dut.u_mon.write_count);
    $display("  reads value-checked : %0d", dut.u_mon.read_checked);
    $display("  reads skipped (race): %0d", dut.u_mon.read_skipped);
    $display("  violations          : %0d", dut.u_mon.error_count);
    if (dut.u_mon.error_count == 0)
      $display("\n==== M3 STRESS TEST PASSED ====\n");
    else
      $display("\n==== M3 STRESS TEST FAILED (%0d) ====\n", dut.u_mon.error_count);
    $finish;
  end

  initial begin
    #50_000_000;
    $error("TIMEOUT");
    $finish;
  end

endmodule
