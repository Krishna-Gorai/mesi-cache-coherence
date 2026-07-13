// -----------------------------------------------------------------------------
// tb_trace.sv  (M4: annotated protocol trace + VCD)
//
// A short, deterministic two-core scenario that walks a line through the entire
// MESI lifecycle -- E, silent E->M, M->S flush, S->M via BusUpgr, a second
// M->S flush, and finally a dirty eviction (BusWB) -- exercising every bus
// command exactly as the protocol reference (docs/protocol.md) describes.
//
// After each CPU operation it prints one Markdown table row showing both
// caches' {state, data} for the contended set and the two backing memory words,
// so the log doubles as a readable waveform. It also writes trace.vcd for
// viewing in a waveform tool.
//
//   sim\run_m4_trace.bat   ->   docs/waveforms.md (captured output)
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_trace
  import mesi_pkg::*;
;
  localparam int N = 2;

  // Two addresses that map to the SAME set (index 0) but differ in tag, so the
  // second one evicts the first -- forcing a writeback when the victim is dirty.
  localparam logic [ADDR_WIDTH-1:0] A = 32'h0000_0040;
  localparam logic [ADDR_WIDTH-1:0] B = 32'h0000_0080;

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

  coherent_system #(.N(N), .MEM_WORDS(1024), .READ_LATENCY(2)) dut (
    .clk, .rst_n,
    .cpu_req_valid, .cpu_req_ready, .cpu_req_we, .cpu_req_addr, .cpu_req_wdata,
    .cpu_resp_valid, .cpu_resp_rdata
  );

  int step = 0;
  task automatic op(input int core, input logic we,
                    input logic [ADDR_WIDTH-1:0] addr,
                    input logic [DATA_WIDTH-1:0] wdata, input string label);
    logic [DATA_WIDTH-1:0] got;
    @(posedge clk);
    cpu_req_valid[core] <= 1'b1; cpu_req_we[core] <= we;
    cpu_req_addr[core]  <= addr; cpu_req_wdata[core] <= wdata;
    do @(posedge clk); while (!cpu_resp_valid[core]);
    got = cpu_resp_rdata[core];
    cpu_req_valid[core] <= 1'b0;
    @(posedge clk);
    step++;
    $display("| %0d | %-14s | %08h | %s / %08h | %s / %08h | %08h | %08h |",
             step, label, got,
             dut.g_core[0].u_cache.state_q[0].name(), dut.g_core[0].u_cache.data_q[0],
             dut.g_core[1].u_cache.state_q[0].name(), dut.g_core[1].u_cache.data_q[0],
             dut.u_mem.mem[A>>BYTE_OFFSET], dut.u_mem.mem[B>>BYTE_OFFSET]);
  endtask

  initial begin
    $dumpfile("trace.vcd");
    $dumpvars(0, tb_trace);

    for (int i = 0; i < N; i++) begin
      cpu_req_valid[i] = 0; cpu_req_we[i] = 0; cpu_req_addr[i] = 0; cpu_req_wdata[i] = 0;
    end
    rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

    $display("");
    $display("| # | operation | rdata | core0 (set0) | core1 (set0) | mem[A] | mem[B] |");
    $display("|--:|-----------|-------|--------------|--------------|--------|--------|");

    op(0, 0, A, 32'h0,        "c0 Rd A");     // I -> E (BusRd, not shared)
    op(0, 1, A, 32'hAAAA_00A5,"c0 Wr A=A5");  // E -> M (silent)
    op(1, 0, A, 32'h0,        "c1 Rd A");     // c0 M->S (flush), c1 -> S
    op(1, 1, A, 32'hBBBB_00B6,"c1 Wr A=B6");  // c1 S->M (BusUpgr), c0 S->I
    op(0, 0, A, 32'h0,        "c0 Rd A");     // c1 M->S (flush), c0 -> S
    op(0, 1, A, 32'hDDDD_00D8,"c0 Wr A=D8");  // c0 S->M (BusUpgr), c1 S->I
    op(0, 0, B, 32'h0,        "c0 Rd B");     // evict dirty A (BusWB), c0 -> E on B

    $display("");
    $display("A = %08h (set 0), B = %08h (set 0, evicts A)", A, B);
    $finish;
  end

  initial begin
    #100_000; $error("TIMEOUT"); $finish;
  end
endmodule
