// -----------------------------------------------------------------------------
// coherent_system.sv  (M1)
//
// Top level of the coherent multiprocessor: N snooping L1 caches sharing one
// atomic snoop bus and one main memory. Each core exposes its own CPU port.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module coherent_system
  import mesi_pkg::*;
#(
  parameter int N            = 2,
  parameter int MEM_WORDS    = 1024,
  parameter int READ_LATENCY = 2
)(
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    cpu_req_valid  [N],
  output logic                    cpu_req_ready  [N],
  input  logic                    cpu_req_we     [N],
  input  logic [ADDR_WIDTH-1:0]   cpu_req_addr   [N],
  input  logic [DATA_WIDTH-1:0]   cpu_req_wdata  [N],
  output logic                    cpu_resp_valid [N],
  output logic [DATA_WIDTH-1:0]   cpu_resp_rdata [N]
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

  // ---- Memory port (bus <-> memory) ----
  logic                  mem_req_valid, mem_req_ready, mem_req_we;
  logic [ADDR_WIDTH-1:0] mem_req_addr;
  logic [DATA_WIDTH-1:0] mem_req_wdata;
  logic                  mem_resp_valid;
  logic [DATA_WIDTH-1:0] mem_resp_rdata;

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
        .s_data  (s_data[i])
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

  main_memory #(.MEM_WORDS(MEM_WORDS), .READ_LATENCY(READ_LATENCY)) u_mem (
    .clk, .rst_n,
    .req_valid (mem_req_valid), .req_ready(mem_req_ready), .req_we(mem_req_we),
    .req_addr  (mem_req_addr),  .req_wdata(mem_req_wdata),
    .resp_valid(mem_resp_valid),.resp_rdata(mem_resp_rdata)
  );

endmodule
