// -----------------------------------------------------------------------------
// l1_cache.sv  (M1: snooping MESI over an atomic shared bus)
//
// Direct-mapped, write-back / write-allocate L1 with full MESI transitions.
// Two request sources touch the tag/state/data arrays:
//   * the local CPU  (processor-side transitions)
//   * the snoop port (bus-side transitions from other caches' transactions)
//
// The cache no longer talks to memory directly -- all fills, writebacks and
// coherence traffic go through the snoop bus, which owns the memory port.
//
// Processor-side (this cache's own request):
//   PrRd  miss        -> BusRd  -> install S if another cache has it, else E
//   PrWr  miss        -> BusRdX -> install M (all other copies invalidated)
//   PrWr  hit  in S    -> BusUpgr -> M (invalidate the sharers, no data move)
//   PrWr  hit  in E    -> silent E->M
//   PrWr  hit  in M    -> stay M
//
// Snoop-side (another cache's transaction hits a line WE hold):
//   see BusRd  : M/E/S -> S   (M also flushes its dirty data to memory)
//   see BusRdX : M/E/S -> I   (M also flushes)
//   see BusUpgr:     S -> I
//
// M2 adds race handling for concurrent requests (the bus is still atomic, but
// caches may now request simultaneously):
//   * Upgrade race -- a cache in S heading for M (ST_UPGR) that is invalidated
//     by another core before it wins the bus must abandon the BusUpgr and
//     re-acquire the line with a full BusRdX (its cached data is now stale).
//   * Snoop-vs-lookup race -- while another core's bus transaction is in flight
//     on the line the CPU FSM is examining (ST_LOOKUP), the decision is held
//     until that transaction commits and then remade against the updated state.
//     Covering the whole in-flight window (not just the commit cycle) stops a
//     local write-hit from silently mutating a line mid-flush, which would let
//     this cache's copy diverge in value from the copy it handed to the bus.
//
// Still simplified (lifted later): atomic bus (one transaction end-to-end at a
// time) and data migration through memory rather than direct cache-to-cache.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module l1_cache
  import mesi_pkg::*;
#(
  parameter int CORE_ID = 0,
  parameter int N       = 2
)(
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

  // ---- Bus master port (this cache initiates a transaction) ----
  output logic                    m_req,
  output bus_cmd_e                m_cmd,
  output logic [ADDR_WIDTH-1:0]   m_addr,
  output logic [DATA_WIDTH-1:0]   m_wdata,
  input  logic                    m_done,
  input  logic [DATA_WIDTH-1:0]   m_rdata,
  input  logic                    m_shared,

  // ---- Bus snoop port (observe another cache's transaction) ----
  input  logic                    s_valid,
  input  bus_cmd_e                s_cmd,
  input  logic [ADDR_WIDTH-1:0]   s_addr,
  input  logic [IDW(N)-1:0]       s_from,
  input  logic                    s_commit,
  output logic                    s_hit,
  output logic                    s_dirty,
  output logic [DATA_WIDTH-1:0]   s_data,

  // ---- Debug observation (for the coherence monitor; not a functional port) ----
  output mesi_e                   dbg_state [NUM_SETS],
  output logic [TAG_BITS-1:0]     dbg_tag   [NUM_SETS]
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
  wire                  victim_dirty = (state_q[idx] == M);          // occupant is dirty
  wire [ADDR_WIDTH-1:0] victim_addr  = {tag_q[idx], idx, {BYTE_OFFSET{1'b0}}};
  // Still hold the requested line in Shared? (false => the upgrade lost its copy)
  wire                  have_shared  = (state_q[idx] == S) && (tag_q[idx] == tag);

  // ---- Snoop lookup (combinational, always live) ----
  wire [INDEX_BITS-1:0] s_idx     = addr_index(s_addr);
  wire [TAG_BITS-1:0]   s_tag     = addr_tag(s_addr);
  wire                  is_me     = (s_from == CORE_ID[IDW(N)-1:0]);
  wire                  s_present = (state_q[s_idx] != I) && (tag_q[s_idx] == s_tag);
  wire                  snoop_act = s_valid && !is_me && s_present;

  assign s_hit   = snoop_act;
  assign s_dirty = snoop_act && (state_q[s_idx] == M);
  assign s_data  = data_q[s_idx];

  for (genvar gs = 0; gs < NUM_SETS; gs++) begin : g_dbg
    assign dbg_state[gs] = state_q[gs];
    assign dbg_tag[gs]   = tag_q[gs];
  end

  // Another core's bus transaction is IN FLIGHT on the very line this cache's
  // CPU FSM is examining (same set + tag). It stays asserted for the whole
  // transaction (s_valid spans BUS_EVAL..BUS_COMMIT), not just the commit
  // cycle, so a local write-hit cannot silently mutate the line while it is
  // being flushed/handed to another core -- doing so would let this cache's
  // post-transaction copy diverge from what it flushed (a value-incoherence
  // that leaves every cache in a legal MESI state yet holding different data).
  // Holding in ST_LOOKUP until the transaction commits forces the decision to
  // be remade against the post-snoop state (e.g. a write that thought it was a
  // silent M/E hit correctly falls back to BusUpgr/BusRdX from S/I).
  wire snoop_conflict = s_valid && !is_me && s_present && (s_idx == idx);

  // ---- Processor-side FSM ----
  typedef enum logic [2:0] {
    ST_IDLE,
    ST_LOOKUP,
    ST_WB,        // evict dirty victim (BusWB)
    ST_FILL,      // BusRd / BusRdX for the requested line
    ST_UPGR,      // BusUpgr: S -> M
    ST_DONE       // one-cycle CPU response window
  } cstate_e;
  cstate_e cs;

  assign cpu_req_ready = (cs == ST_IDLE);

  // ---- Bus master request (combinational, stable while in a bus state) ----
  always_comb begin
    m_req   = 1'b0;
    m_cmd   = BUS_NONE;
    m_addr  = req_addr_q;
    m_wdata = '0;
    unique case (cs)
      ST_WB:   begin m_req = 1'b1; m_cmd = BUS_WB;                       m_addr = victim_addr; m_wdata = data_q[idx]; end
      ST_FILL: begin m_req = 1'b1; m_cmd = req_we_q ? BUS_RDX : BUS_RD;  m_addr = req_addr_q;  end
      ST_UPGR: begin m_req = 1'b1; m_cmd = have_shared ? BUS_UPGR : BUS_RDX; m_addr = req_addr_q; end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs             <= ST_IDLE;
      cpu_resp_valid <= 1'b0;
      cpu_resp_rdata <= '0;
      req_we_q       <= 1'b0;
      req_addr_q     <= '0;
      req_wdata_q    <= '0;
      for (int i = 0; i < NUM_SETS; i++) state_q[i] <= I;
    end else begin
      cpu_resp_valid <= 1'b0;                         // default: single-cycle pulse

      // ---- Processor-side FSM ----
      unique case (cs)
        ST_IDLE: begin
          if (cpu_req_valid) begin
            req_we_q    <= cpu_req_we;
            req_addr_q  <= cpu_req_addr;
            req_wdata_q <= cpu_req_wdata;
            cs          <= ST_LOOKUP;
          end
        end

        ST_LOOKUP: begin
          if (snoop_conflict) begin
            // Another core owns this line on the bus right now; hold in
            // ST_LOOKUP until its transaction commits, then remake the decision
            // against the post-snoop state.
          end else if (hit) begin
            if (!req_we_q) begin                       // read hit
              cpu_resp_rdata <= data_q[idx];
              cpu_resp_valid <= 1'b1;
              cs             <= ST_DONE;
            end else begin                             // write hit
              unique case (state_q[idx])
                M: begin
                  data_q[idx]    <= req_wdata_q;       // stay M
                  cpu_resp_rdata <= req_wdata_q;
                  cpu_resp_valid <= 1'b1;
                  cs             <= ST_DONE;
                end
                E: begin
                  data_q[idx]    <= req_wdata_q;       // silent E -> M
                  state_q[idx]   <= M;
                  cpu_resp_rdata <= req_wdata_q;
                  cpu_resp_valid <= 1'b1;
                  cs             <= ST_DONE;
                end
                default: cs <= ST_UPGR;                // S: need BusUpgr
              endcase
            end
          end else begin                               // miss
            cs <= victim_dirty ? ST_WB : ST_FILL;
          end
        end

        ST_WB: begin
          if (m_done) begin
            state_q[idx] <= I;                         // dirty victim written back
            cs           <= ST_FILL;
          end
        end

        ST_FILL: begin
          if (m_done) begin
            tag_q[idx] <= tag;
            if (req_we_q) begin
              data_q[idx]    <= req_wdata_q;           // write miss: BusRdX -> M
              state_q[idx]   <= M;
              cpu_resp_rdata <= req_wdata_q;
            end else begin
              data_q[idx]    <= m_rdata;               // read miss: S if shared else E
              state_q[idx]   <= m_shared ? S : E;
              cpu_resp_rdata <= m_rdata;
            end
            cpu_resp_valid <= 1'b1;
            cs             <= ST_DONE;
          end
        end

        ST_UPGR: begin
          if (!have_shared) begin
            // Lost the shared copy to another core before winning the bus:
            // the BusUpgr shortcut is invalid, re-acquire the line via BusRdX.
            // synthesis translate_off
            $display("[%0t] core%0d: upgrade race -- lost the line, BusUpgr -> BusRdX @%08h",
                     $time, CORE_ID, req_addr_q);
            // synthesis translate_on
            cs <= ST_FILL;
          end else if (m_done) begin
            data_q[idx]    <= req_wdata_q;             // S -> M after invalidating sharers
            state_q[idx]   <= M;
            cpu_resp_rdata <= req_wdata_q;
            cpu_resp_valid <= 1'b1;
            cs             <= ST_DONE;
          end
        end

        ST_DONE: cs <= ST_IDLE;

        default: cs <= ST_IDLE;
      endcase

      // ---- Snoop-side state update (independent of the processor FSM) ----
      if (s_commit && s_valid && !is_me && s_present) begin
        unique case (s_cmd)
          BUS_RD:   state_q[s_idx] <= S;               // downgrade to Shared
          BUS_RDX:  state_q[s_idx] <= I;               // invalidate
          BUS_UPGR: state_q[s_idx] <= I;               // invalidate
          default: ;
        endcase
      end
    end
  end
endmodule
