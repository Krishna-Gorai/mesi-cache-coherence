// -----------------------------------------------------------------------------
// mesi_pkg.sv
// Shared parameters, address helpers, and protocol enums for the MESI
// snooping cache-coherence unit.
//
// Geometry (M0): 32-bit words, one word == one coherence block, direct-mapped.
// The snoop-bus command enum is defined here now but only exercised from M1.
// -----------------------------------------------------------------------------
package mesi_pkg;

  // ---- Geometry -------------------------------------------------------------
  localparam int ADDR_WIDTH  = 32;
  localparam int DATA_WIDTH  = 32;                    // one word == one block (M0)
  localparam int WORD_BYTES  = DATA_WIDTH / 8;
  localparam int BYTE_OFFSET = $clog2(WORD_BYTES);    // 2

  localparam int NUM_SETS    = 16;
  localparam int INDEX_BITS  = $clog2(NUM_SETS);      // 4
  localparam int TAG_BITS    = ADDR_WIDTH - INDEX_BITS - BYTE_OFFSET; // 26

  localparam int NUM_CORES   = 4;                     // used from M1 onward

  // Core-id width for an N-core system (>=1 bit even for a single core).
  function automatic int IDW(input int n);
    return (n <= 1) ? 1 : $clog2(n);
  endfunction

  // Deterministic initial memory contents, shared by the memory model and the
  // monitor's golden model so untouched locations agree.
  function automatic logic [DATA_WIDTH-1:0] init_word(input int i);
    return 32'hDEAD_0000 + i;
  endfunction

  // ---- MESI stable states ---------------------------------------------------
  typedef enum logic [1:0] {
    I = 2'b00,   // Invalid
    S = 2'b01,   // Shared     (clean, copies may exist elsewhere)
    E = 2'b10,   // Exclusive  (clean, only cached copy)
    M = 2'b11    // Modified   (dirty, only cached copy)
  } mesi_e;

  // ---- Snoop-bus commands (used from M1 onward) -----------------------------
  typedef enum logic [2:0] {
    BUS_NONE = 3'b000,
    BUS_RD   = 3'b001,   // read miss, wants data (resolves to S or E)
    BUS_RDX  = 3'b010,   // read-for-ownership, wants M
    BUS_UPGR = 3'b011,   // S -> M: already have data, just invalidate others
    BUS_WB   = 3'b100    // writeback of a dirty line to memory
  } bus_cmd_e;

  // ---- Address field helpers ------------------------------------------------
  function automatic logic [INDEX_BITS-1:0] addr_index(input logic [ADDR_WIDTH-1:0] a);
    return a[BYTE_OFFSET +: INDEX_BITS];
  endfunction

  function automatic logic [TAG_BITS-1:0] addr_tag(input logic [ADDR_WIDTH-1:0] a);
    return a[ADDR_WIDTH-1 -: TAG_BITS];
  endfunction

endpackage
