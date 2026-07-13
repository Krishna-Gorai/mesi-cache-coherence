// -----------------------------------------------------------------------------
// coherence_unit.sv
//
// Synthesis wrapper for PPA: the coherence hardware ONLY -- N snooping L1 caches
// plus the snoop bus -- with the main-memory interface exposed as top-level
// ports. The behavioral main_memory model (a register array standing in for the
// next memory level) is deliberately left outside the unit so the reported area,
// timing and power reflect the coherence logic itself rather than a stand-in for
// off-unit RAM (which on a real device is BRAM or external DDR).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module coherence_unit
  import mesi_pkg::*;
#(
  parameter int N = 4
)(
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- Per-core CPU ports ----
  input  logic                    cpu_req_valid  [N],
  output logic                    cpu_req_ready  [N],
  input  logic                    cpu_req_we     [N],
  input  logic [ADDR_WIDTH-1:0]   cpu_req_addr   [N],
  input  logic [DATA_WIDTH-1:0]   cpu_req_wdata  [N],
  output logic                    cpu_resp_valid [N],
  output logic [DATA_WIDTH-1:0]   cpu_resp_rdata [N],

  // ---- Main-memory port (to the next memory level) ----
  output logic                    mem_req_valid,
  input  logic                    mem_req_ready,
  output logic                    mem_req_we,
  output logic [ADDR_WIDTH-1:0]   mem_req_addr,
  output logic [DATA_WIDTH-1:0]   mem_req_wdata,
  input  logic                    mem_resp_valid,
  input  logic [DATA_WIDTH-1:0]   mem_resp_rdata
);

  // ---- Master interconnect (cache -> bus) ----
  logic                  m_req   [N];
  bus_cmd_e              m_cmd   [N];
  logic [ADDR_WIDTH-1:0] m_addr  [N];
  logic [DATA_WIDTH-1:0] m_wdata [N];
  logic                  m_done  [N];
  logic [DATA_WIDTH-1:0] m_rdata [N];
  logic                  m_shared[N];

  // ---- Snoop interconnect (bus <-> caches) ----
  logic                  s_valid;
  bus_cmd_e              s_cmd;
  logic [ADDR_WIDTH-1:0] s_addr;
  logic [IDW(N)-1:0]     s_from;
  logic                  s_commit;
  logic                  s_hit   [N];
  logic                  s_dirty [N];
  logic [DATA_WIDTH-1:0] s_data  [N];

  // Debug observation ports of the caches are unused here.
  mesi_e               dbg_state [N][NUM_SETS];
  logic [TAG_BITS-1:0] dbg_tag   [N][NUM_SETS];

  genvar i;
  generate
    for (i = 0; i < N; i++) begin : g_core
      l1_cache #(.CORE_ID(i), .N(N)) u_cache (
        .clk, .rst_n,
        .cpu_req_valid (cpu_req_valid[i]),
        .cpu_req_ready (cpu_req_ready[i]),
        .cpu_req_we    (cpu_req_we[i]),
        .cpu_req_addr  (cpu_req_addr[i]),
        .cpu_req_wdata (cpu_req_wdata[i]),
        .cpu_resp_valid(cpu_resp_valid[i]),
        .cpu_resp_rdata(cpu_resp_rdata[i]),
        .m_req   (m_req[i]),
        .m_cmd   (m_cmd[i]),
        .m_addr  (m_addr[i]),
        .m_wdata (m_wdata[i]),
        .m_done  (m_done[i]),
        .m_rdata (m_rdata[i]),
        .m_shared(m_shared[i]),
        .s_valid, .s_cmd, .s_addr, .s_from, .s_commit,
        .s_hit   (s_hit[i]),
        .s_dirty (s_dirty[i]),
        .s_data  (s_data[i]),
        .dbg_state(dbg_state[i]),
        .dbg_tag  (dbg_tag[i])
      );
    end
  endgenerate

  snoop_bus #(.N(N)) u_bus (
    .clk, .rst_n,
    .m_req, .m_cmd, .m_addr, .m_wdata, .m_done, .m_rdata, .m_shared,
    .s_valid, .s_cmd, .s_addr, .s_from, .s_commit, .s_hit, .s_dirty, .s_data,
    .mem_req_valid, .mem_req_ready, .mem_req_we, .mem_req_addr, .mem_req_wdata,
    .mem_resp_valid, .mem_resp_rdata
  );

endmodule
