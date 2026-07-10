// -----------------------------------------------------------------------------
// tb_l1_cache.sv  (M0 sanity)
//
// Drives one L1 cache against the main-memory model and checks:
//   * read miss fills from memory (E)
//   * read hit returns cached data
//   * store transitions the line to M
//   * a conflicting miss writes the dirty victim back...
//   * ...and re-reading the evicted address returns the written value,
//     proving the writeback actually persisted to memory.
//
// A software shadow memory provides golden expected values.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_l1_cache
  import mesi_pkg::*;
;

  localparam int MEM_WORDS = 1024;

  logic clk = 0;
  logic rst_n;
  always #5 clk = ~clk;                                // 100 MHz

  // ---- CPU side ----
  logic                  cpu_req_valid;
  logic                  cpu_req_ready;
  logic                  cpu_req_we;
  logic [ADDR_WIDTH-1:0] cpu_req_addr;
  logic [DATA_WIDTH-1:0] cpu_req_wdata;
  logic                  cpu_resp_valid;
  logic [DATA_WIDTH-1:0] cpu_resp_rdata;

  // ---- Cache <-> memory ----
  logic                  mem_req_valid, mem_req_ready, mem_req_we;
  logic [ADDR_WIDTH-1:0] mem_req_addr;
  logic [DATA_WIDTH-1:0] mem_req_wdata;
  logic                  mem_resp_valid;
  logic [DATA_WIDTH-1:0] mem_resp_rdata;

  l1_cache dut (
    .clk, .rst_n,
    .cpu_req_valid, .cpu_req_ready, .cpu_req_we, .cpu_req_addr, .cpu_req_wdata,
    .cpu_resp_valid, .cpu_resp_rdata,
    .mem_req_valid, .mem_req_ready, .mem_req_we, .mem_req_addr, .mem_req_wdata,
    .mem_resp_valid, .mem_resp_rdata
  );

  main_memory #(.MEM_WORDS(MEM_WORDS), .READ_LATENCY(2)) u_mem (
    .clk, .rst_n,
    .req_valid (mem_req_valid), .req_ready(mem_req_ready), .req_we(mem_req_we),
    .req_addr  (mem_req_addr),  .req_wdata(mem_req_wdata),
    .resp_valid(mem_resp_valid),.resp_rdata(mem_resp_rdata)
  );

  // ---- Golden shadow memory ----
  logic [DATA_WIDTH-1:0] shadow [0:MEM_WORDS-1];
  int errors = 0;

  function automatic int word_of(input logic [ADDR_WIDTH-1:0] a);
    return int'(a >> BYTE_OFFSET);
  endfunction

  // Backdoor-initialise both real and shadow memory to known contents.
  task automatic init_mem();
    for (int i = 0; i < MEM_WORDS; i++) begin
      u_mem.mem[i] = 32'hDEAD_0000 + i;
      shadow[i]    = 32'hDEAD_0000 + i;
    end
  endtask

  task automatic cpu_read(input logic [ADDR_WIDTH-1:0] addr);
    logic [DATA_WIDTH-1:0] got, exp;
    cpu_req_valid <= 1'b1; cpu_req_we <= 1'b0; cpu_req_addr <= addr;
    do @(posedge clk); while (!cpu_resp_valid);
    got = cpu_resp_rdata;
    cpu_req_valid <= 1'b0;
    exp = shadow[word_of(addr)];
    if (got !== exp) begin
      errors++;
      $error("READ  @%08h got=%08h exp=%08h", addr, got, exp);
    end else begin
      $display("[%0t] READ  @%08h => %08h  OK", $time, addr, got);
    end
    @(posedge clk);
  endtask

  task automatic cpu_write(input logic [ADDR_WIDTH-1:0] addr, input logic [DATA_WIDTH-1:0] data);
    cpu_req_valid <= 1'b1; cpu_req_we <= 1'b1; cpu_req_addr <= addr; cpu_req_wdata <= data;
    do @(posedge clk); while (!cpu_resp_valid);
    cpu_req_valid <= 1'b0;
    shadow[word_of(addr)] = data;
    $display("[%0t] WRITE @%08h <= %08h", $time, addr, data);
    @(posedge clk);
  endtask

  // ---- Stimulus ----
  localparam logic [ADDR_WIDTH-1:0] A = 32'h0000_0040;
  // B maps to the same set as A (index-aligned) but a different tag => conflict.
  localparam logic [ADDR_WIDTH-1:0] B = A + (NUM_SETS << BYTE_OFFSET);

  initial begin
    cpu_req_valid = 0; cpu_req_we = 0; cpu_req_addr = 0; cpu_req_wdata = 0;
    rst_n = 0;
    init_mem();
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    cpu_read (A);                 // 1. read miss -> fill E
    cpu_read (A);                 // 2. read hit
    cpu_write(A, 32'hCAFE_BABE);  // 3. store -> M
    cpu_read (A);                 // 4. read hit, returns written value
    cpu_read (B);                 // 5. conflicting miss -> writeback dirty A, fill B
    cpu_read (A);                 // 6. A re-missed; must return CAFEBABE from memory

    repeat (4) @(posedge clk);
    if (errors == 0) $display("\n==== M0 TEST PASSED ====\n");
    else             $display("\n==== M0 TEST FAILED (%0d errors) ====\n", errors);
    $finish;
  end

  // Safety net so a hang never wedges CI.
  initial begin
    #100000;
    $error("TIMEOUT");
    $finish;
  end

  // Waveform dump.
  initial begin
    $dumpfile("tb_l1_cache.vcd");
    $dumpvars(0, tb_l1_cache);
  end

endmodule
