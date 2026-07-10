// -----------------------------------------------------------------------------
// l1_cache.sv  (M0: CPU side only -- no snoop bus yet)
//
// Direct-mapped, write-back / write-allocate L1 with MESI state storage.
// With a single core and no bus contention, a read-allocate installs the line
// in E (exclusive-clean) and a store transitions it to M (modified-dirty).
// A dirty victim is written back before the new line is filled.
//
// The snoop port and the S/E/UPGR bus interactions are layered on in M1.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module l1_cache
  import mesi_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- CPU side ----
  input  logic                    cpu_req_valid,
  output logic                    cpu_req_ready,
  input  logic                    cpu_req_we,
  input  logic [ADDR_WIDTH-1:0]   cpu_req_addr,
  input  logic [DATA_WIDTH-1:0]   cpu_req_wdata,
  output logic                    cpu_resp_valid,
  output logic [DATA_WIDTH-1:0]   cpu_resp_rdata,

  // ---- Memory side ----
  output logic                    mem_req_valid,
  input  logic                    mem_req_ready,
  output logic                    mem_req_we,
  output logic [ADDR_WIDTH-1:0]   mem_req_addr,
  output logic [DATA_WIDTH-1:0]   mem_req_wdata,
  input  logic                    mem_resp_valid,
  input  logic [DATA_WIDTH-1:0]   mem_resp_rdata
);

  // ---- Cache arrays ----
  logic [TAG_BITS-1:0]   tag_q   [0:NUM_SETS-1];
  mesi_e                 state_q [0:NUM_SETS-1];
  logic [DATA_WIDTH-1:0] data_q  [0:NUM_SETS-1];

  // ---- Latched CPU request ----
  logic                  req_we_q;
  logic [ADDR_WIDTH-1:0] req_addr_q;
  logic [DATA_WIDTH-1:0] req_wdata_q;

  wire [INDEX_BITS-1:0] idx          = addr_index(req_addr_q);
  wire [TAG_BITS-1:0]   tag          = addr_tag(req_addr_q);
  wire                  hit          = (state_q[idx] != I) && (tag_q[idx] == tag);
  wire                  victim_dirty = (state_q[idx] == M);

  // Reconstruct the physical address of the (dirty) victim line for writeback.
  wire [ADDR_WIDTH-1:0] victim_addr  = {tag_q[idx], idx, {BYTE_OFFSET{1'b0}}};

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_LOOKUP,
    ST_WB,        // write dirty victim back to memory
    ST_FILL,      // issue read request for the missing line
    ST_FILLWAIT,  // wait for memory read data
    ST_DONE       // one-cycle response window
  } cstate_e;
  cstate_e cs;

  assign cpu_req_ready = (cs == ST_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs             <= ST_IDLE;
      cpu_resp_valid <= 1'b0;
      cpu_resp_rdata <= '0;
      mem_req_valid  <= 1'b0;
      mem_req_we     <= 1'b0;
      mem_req_addr   <= '0;
      mem_req_wdata  <= '0;
      req_we_q       <= 1'b0;
      req_addr_q     <= '0;
      req_wdata_q    <= '0;
      for (int i = 0; i < NUM_SETS; i++) state_q[i] <= I;
    end else begin
      cpu_resp_valid <= 1'b0;                         // default: single-cycle pulse

      unique case (cs)
        // -------------------------------------------------------------------
        ST_IDLE: begin
          if (cpu_req_valid) begin
            req_we_q    <= cpu_req_we;
            req_addr_q  <= cpu_req_addr;
            req_wdata_q <= cpu_req_wdata;
            cs          <= ST_LOOKUP;
          end
        end

        // -------------------------------------------------------------------
        ST_LOOKUP: begin
          if (hit) begin
            if (req_we_q) begin
              data_q[idx]  <= req_wdata_q;
              state_q[idx] <= M;                       // store => Modified
              cpu_resp_rdata <= req_wdata_q;
            end else begin
              cpu_resp_rdata <= data_q[idx];
            end
            cpu_resp_valid <= 1'b1;
            cs             <= ST_DONE;
          end else begin
            cs <= victim_dirty ? ST_WB : ST_FILL;
          end
        end

        // -------------------------------------------------------------------
        ST_WB: begin
          mem_req_valid <= 1'b1;
          mem_req_we    <= 1'b1;
          mem_req_addr  <= victim_addr;
          mem_req_wdata <= data_q[idx];
          if (mem_req_valid && mem_req_ready) begin
            mem_req_valid <= 1'b0;
            state_q[idx]  <= I;                        // victim gone
            cs            <= ST_FILL;
          end
        end

        // -------------------------------------------------------------------
        ST_FILL: begin
          mem_req_valid <= 1'b1;
          mem_req_we    <= 1'b0;
          mem_req_addr  <= req_addr_q;
          if (mem_req_valid && mem_req_ready) begin
            mem_req_valid <= 1'b0;
            cs            <= ST_FILLWAIT;
          end
        end

        // -------------------------------------------------------------------
        ST_FILLWAIT: begin
          if (mem_resp_valid) begin
            tag_q[idx]     <= tag;
            data_q[idx]    <= req_we_q ? req_wdata_q : mem_resp_rdata;
            state_q[idx]   <= req_we_q ? M : E;        // write=>M, read=>E
            cpu_resp_rdata <= req_we_q ? req_wdata_q : mem_resp_rdata;
            cpu_resp_valid <= 1'b1;
            cs             <= ST_DONE;
          end
        end

        // -------------------------------------------------------------------
        ST_DONE: begin
          cs <= ST_IDLE;
        end

        default: cs <= ST_IDLE;
      endcase
    end
  end
endmodule
