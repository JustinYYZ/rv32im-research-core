// SPDX-License-Identifier: Apache-2.0
//
// Shared parameters and identity types for the out-of-order backend. ROB tags
// include a generation bit so a delayed result from an old use of a slot cannot
// be mistaken for a newly allocated instruction.

`timescale 1ns/1ps

package rv32_ooo_pkg;

  localparam int unsigned ROB_ENTRIES = 16;
  localparam int unsigned ROB_INDEX_WIDTH = $clog2(ROB_ENTRIES);
  localparam int unsigned ROB_COUNT_WIDTH = $clog2(ROB_ENTRIES + 1);

  typedef struct packed {
    logic                       generation;
    logic [ROB_INDEX_WIDTH-1:0] index;
  } rob_tag_t;

  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic [4:0]  rd;
    logic        reg_write;
  } rob_alloc_payload_t;

  typedef struct packed {
    logic               valid;
    logic               completed;
    logic               generation;
    rob_alloc_payload_t payload;
    logic [31:0]        result;
  } rob_entry_t;

  // Rename, scheduling, writeback, and the PRF exchange the same physical
  // register identifiers through this shared type.
  localparam int unsigned PHYS_REGS = 64;
  localparam int unsigned PHYS_REG_INDEX_WIDTH = $clog2(PHYS_REGS);
  typedef logic [PHYS_REG_INDEX_WIDTH-1:0] phys_reg_idx_t;

endpackage
