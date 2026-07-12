// -----------------------------------------------------------------------------
// snoop_bus.sv  (M1: atomic snooping coherence bus)
//
// Central coherence point for the L1 caches. One transaction is serviced at a
// time (atomic bus). For each transaction the bus:
//   1. arbitrates among requesting masters (round-robin),
//   2. broadcasts {cmd,addr} to the other caches and gathers their snoop
//      response (shared? dirty-owner?),
//   3. if a snooper holds the line dirty (M), flushes that data to memory,
//   4. performs the memory access the transaction needs
//        BusRd / BusRdX -> read the (now up-to-date) line from memory
//        BusWB          -> write the requester's dirty victim to memory
//        BusUpgr        -> no memory access,
//   5. commits: pulses s_commit so snoopers apply their state change, and
//      returns {done,rdata,shared} to the requesting master.
//
// The bus owns the single main-memory port and multiplexes it between snoop
// flushes and requester fills.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module snoop_bus
  import mesi_pkg::*;
#(
  parameter int N = 2
)(
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- Master ports (per core) ----
  input  logic                    m_req   [N],
  input  bus_cmd_e                m_cmd   [N],
  input  logic [ADDR_WIDTH-1:0]   m_addr  [N],
  input  logic [DATA_WIDTH-1:0]   m_wdata [N],
  output logic                    m_done  [N],
  output logic [DATA_WIDTH-1:0]   m_rdata [N],
  output logic                    m_shared[N],

  // ---- Snoop broadcast (shared) + per-core response ----
  output logic                    s_valid,
  output bus_cmd_e                s_cmd,
  output logic [ADDR_WIDTH-1:0]   s_addr,
  output logic [IDW(N)-1:0]       s_from,
  output logic                    s_commit,
  input  logic                    s_hit   [N],
  input  logic                    s_dirty [N],
  input  logic [DATA_WIDTH-1:0]   s_data  [N],

  // ---- Main-memory port ----
  output logic                    mem_req_valid,
  input  logic                    mem_req_ready,
  output logic                    mem_req_we,
  output logic [ADDR_WIDTH-1:0]   mem_req_addr,
  output logic [DATA_WIDTH-1:0]   mem_req_wdata,
  input  logic                    mem_resp_valid,
  input  logic [DATA_WIDTH-1:0]   mem_resp_rdata
);

  localparam int IW = IDW(N);

  typedef enum logic [2:0] {
    BUS_IDLE,
    BUS_EVAL,      // snoop responses valid: compute shared / dirty-owner
    BUS_FLUSH,     // write dirty owner's data back to memory
    BUS_MEMREAD,   // read the requested line from memory
    BUS_WBWRITE,   // write a requester's dirty victim to memory
    BUS_COMMIT     // pulse s_commit + return result to the master
  } bstate_e;
  bstate_e state;

  logic [IW-1:0]          gnt_id, owner_id, rr_ptr;
  bus_cmd_e               cur_cmd;
  logic [ADDR_WIDTH-1:0]  cur_addr;
  logic [DATA_WIDTH-1:0]  cur_wdata, cur_rdata;
  logic                   cur_shared;
  logic                   rd_issued;

  // ---- Round-robin arbiter ----
  logic          any_req;
  logic [IW-1:0] win;
  always_comb begin
    any_req = 1'b0;
    win     = '0;
    for (int k = 0; k < N; k++) begin
      int j;
      j = (rr_ptr + k) % N;
      if (!any_req && m_req[j]) begin
        any_req = 1'b1;
        win     = j[IW-1:0];
      end
    end
  end

  // ---- Snoop aggregation (valid during BUS_EVAL / BUS_FLUSH) ----
  logic          shared_now, dirty_now;
  logic [IW-1:0] owner_now;
  always_comb begin
    shared_now = 1'b0;
    dirty_now  = 1'b0;
    owner_now  = '0;
    for (int j = 0; j < N; j++) begin
      if (s_hit[j])   shared_now = 1'b1;
      if (s_dirty[j]) begin dirty_now = 1'b1; owner_now = j[IW-1:0]; end
    end
  end

  // ---- Snoop broadcast ----
  assign s_valid  = (state != BUS_IDLE);
  assign s_cmd    = cur_cmd;
  assign s_addr   = cur_addr;
  assign s_from   = gnt_id;
  assign s_commit = (state == BUS_COMMIT);

  // ---- Master response ----
  always_comb begin
    for (int j = 0; j < N; j++) begin
      m_done[j]   = (state == BUS_COMMIT) && (j == int'(gnt_id));
      m_rdata[j]  = cur_rdata;
      m_shared[j] = cur_shared;
    end
  end

  // ---- Memory port ----
  always_comb begin
    mem_req_valid = 1'b0;
    mem_req_we    = 1'b0;
    mem_req_addr  = cur_addr;
    mem_req_wdata = '0;
    unique case (state)
      BUS_FLUSH:   begin mem_req_valid = 1'b1;        mem_req_we = 1'b1; mem_req_wdata = s_data[owner_id]; end
      BUS_WBWRITE: begin mem_req_valid = 1'b1;        mem_req_we = 1'b1; mem_req_wdata = cur_wdata;        end
      BUS_MEMREAD: begin mem_req_valid = ~rd_issued;  mem_req_we = 1'b0;                                   end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= BUS_IDLE;
      gnt_id     <= '0;
      owner_id   <= '0;
      rr_ptr     <= '0;
      cur_cmd    <= BUS_NONE;
      cur_addr   <= '0;
      cur_wdata  <= '0;
      cur_rdata  <= '0;
      cur_shared <= 1'b0;
      rd_issued  <= 1'b0;
    end else begin
      unique case (state)
        BUS_IDLE: begin
          if (any_req) begin
            gnt_id    <= win;
            cur_cmd   <= m_cmd[win];
            cur_addr  <= m_addr[win];
            cur_wdata <= m_wdata[win];
            state     <= BUS_EVAL;
          end
        end

        BUS_EVAL: begin
          cur_shared <= shared_now;                   // capture E/S decision
          owner_id   <= owner_now;
          unique case (cur_cmd)
            BUS_WB:   state <= BUS_WBWRITE;
            BUS_UPGR: state <= BUS_COMMIT;            // no data move; sharers die at commit
            BUS_RD, BUS_RDX:
                      state <= dirty_now ? BUS_FLUSH : BUS_MEMREAD;
            default:  state <= BUS_COMMIT;
          endcase
        end

        BUS_FLUSH: begin                              // one-cycle memory write
          if (mem_req_ready) state <= BUS_MEMREAD;
        end

        BUS_MEMREAD: begin
          if (!rd_issued && mem_req_ready) rd_issued <= 1'b1;
          if (mem_resp_valid) begin
            cur_rdata <= mem_resp_rdata;
            rd_issued <= 1'b0;
            state     <= BUS_COMMIT;
          end
        end

        BUS_WBWRITE: begin                            // one-cycle memory write
          if (mem_req_ready) state <= BUS_COMMIT;
        end

        BUS_COMMIT: begin
          rr_ptr <= (int'(gnt_id) + 1) % N;
          state  <= BUS_IDLE;
        end

        default: state <= BUS_IDLE;
      endcase
    end
  end
endmodule
