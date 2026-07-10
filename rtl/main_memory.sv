// -----------------------------------------------------------------------------
// main_memory.sv
// Simple backing store for the cache. Word-addressable, single outstanding
// request, parameterizable read latency. Writes complete in one cycle.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module main_memory
  import mesi_pkg::*;
#(
  parameter int MEM_WORDS    = 1024,
  parameter int READ_LATENCY = 2
)(
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    req_valid,
  output logic                    req_ready,
  input  logic                    req_we,
  input  logic [ADDR_WIDTH-1:0]   req_addr,
  input  logic [DATA_WIDTH-1:0]   req_wdata,

  output logic                    resp_valid,
  output logic [DATA_WIDTH-1:0]   resp_rdata
);

  localparam int AW = $clog2(MEM_WORDS);

  logic [DATA_WIDTH-1:0] mem [0:MEM_WORDS-1];

  function automatic logic [AW-1:0] word_addr(input logic [ADDR_WIDTH-1:0] a);
    return a[BYTE_OFFSET +: AW];
  endfunction

  logic [$clog2(READ_LATENCY+1)-1:0] lat_cnt;
  logic                              busy;
  logic [ADDR_WIDTH-1:0]             rd_addr_q;

  // Accept a new request only when no read is in flight.
  assign req_ready = !busy;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy       <= 1'b0;
      lat_cnt    <= '0;
      rd_addr_q  <= '0;
      resp_valid <= 1'b0;
      resp_rdata <= '0;
    end else begin
      resp_valid <= 1'b0;                             // default: single-cycle pulse
      if (!busy) begin
        if (req_valid) begin
          if (req_we) begin
            mem[word_addr(req_addr)] <= req_wdata;    // write: completes this cycle
          end else begin
            busy      <= 1'b1;
            lat_cnt   <= READ_LATENCY[$bits(lat_cnt)-1:0];
            rd_addr_q <= req_addr;
          end
        end
      end else begin
        if (lat_cnt <= 1) begin
          busy       <= 1'b0;
          resp_valid <= 1'b1;
          resp_rdata <= mem[word_addr(rd_addr_q)];
        end else begin
          lat_cnt <= lat_cnt - 1'b1;
        end
      end
    end
  end
endmodule
