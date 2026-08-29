// SPDX-License-Identifier: Apache-2.0
//
// Shared parameters and identity types for the out-of-order backend.
// The first milestone uses a circular 16-entry ROB. A tag contains both the
// physical slot index and a generation bit so that a delayed result from an
// old use of a slot cannot be mistaken for a newly allocated instruction.

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

  // An allocated entry records architectural identity immediately. Result and
  // completed are initialized on allocation and updated by tagged completion.

endpackage
