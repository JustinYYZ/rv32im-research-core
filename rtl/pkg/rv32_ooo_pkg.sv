// SPDX-License-Identifier: Apache-2.0
//
// Shared parameters and identity types for the out-of-order backend. ROB tags
// include a generation bit so a delayed result from an old use of a slot cannot
// be mistaken for a newly allocated instruction.

`timescale 1ns/1ps

package rv32_ooo_pkg;

  localparam int unsigned FETCH_QUEUE_ENTRIES = 8;
  localparam int unsigned FETCH_QUEUE_INDEX_WIDTH = $clog2(FETCH_QUEUE_ENTRIES);
  localparam int unsigned FETCH_QUEUE_COUNT_WIDTH = $clog2(FETCH_QUEUE_ENTRIES + 1);

  // Fetch validity travels through the Queue ready/valid interface rather than
  // being duplicated inside the payload.
  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic [31:0] predicted_next_pc;
    logic        access_fault;
  } fetch_entry_t;

  localparam int unsigned ROB_ENTRIES = 16;
  localparam int unsigned ROB_INDEX_WIDTH = $clog2(ROB_ENTRIES);
  localparam int unsigned ROB_COUNT_WIDTH = $clog2(ROB_ENTRIES + 1);

  typedef struct packed {
    logic                       generation;
    logic [ROB_INDEX_WIDTH-1:0] index;
  } rob_tag_t;

  // Rename, scheduling, writeback, and the PRF exchange the same physical
  // register identifiers through this shared type.
  localparam int unsigned PHYS_REGS = 64;
  localparam int unsigned PHYS_REG_INDEX_WIDTH = $clog2(PHYS_REGS);
  typedef logic [PHYS_REG_INDEX_WIDTH-1:0] phys_reg_idx_t;

  typedef struct packed {
    logic [31:0]                pc;
    logic [31:0]                instr;
    logic [31:0]                predicted_next_pc;
    rv32_pkg::control_flow_e    control_flow;
    logic                       trap;
    rv32_core_pkg::trap_cause_e trap_cause;
    logic [4:0]                 rd;
    logic                       reg_write;
    phys_reg_idx_t              new_phys_rd;
    phys_reg_idx_t              old_phys_rd;
  } rob_alloc_payload_t;

  typedef struct packed {
    logic               valid;
    logic               completed;
    logic               generation;
    rob_alloc_payload_t payload;
    logic [31:0]        result;
    logic [31:0]        actual_next_pc;
    logic               mem_valid;
    logic               mem_write;
    logic [31:0]        mem_addr;
    logic [3:0]         mem_rmask;
    logic [3:0]         mem_wmask;
    logic [31:0]        mem_rdata;
    logic [31:0]        mem_wdata;
  } rob_entry_t;

  // The CDB carries one instruction's result, runtime trap, and memory record
  // together with its ROB tag. Producers without memory effects leave those
  // fields zero.
  typedef struct packed {
    rob_tag_t                   rob_tag;
    phys_reg_idx_t              phys_rd;
    logic                       rd_write;
    logic [31:0]                result;
    logic [31:0]                actual_next_pc;
    logic                       trap;
    rv32_core_pkg::trap_cause_e trap_cause;
    logic                       mem_valid;
    logic                       mem_write;
    logic [31:0]                mem_addr;
    logic [3:0]                 mem_rmask;
    logic [3:0]                 mem_wmask;
    logic [31:0]                mem_rdata;
    logic [31:0]                mem_wdata;
  } completion_payload_t;

  localparam int unsigned ISSUE_ENTRIES = 8;
  localparam int unsigned ISSUE_INDEX_WIDTH = $clog2(ISSUE_ENTRIES);
  localparam int unsigned ISSUE_COUNT_WIDTH = $clog2(ISSUE_ENTRIES + 1);

  typedef enum logic [2:0] {
    FU_ALU,
    FU_BRANCH,
    FU_MUL,
    FU_DIV,
    FU_MEMORY
  } fu_kind_e;
  localparam int unsigned FU_COUNT = 5;

  // Renamed instruction identity shared by Dispatch, scheduling, and Issue.
  // Source readiness remains separate because CDB wakeup changes it in place.
  typedef struct packed {
    logic [31:0]                  pc;
    logic [31:0]                  instr;
    logic [31:0]                  imm;
    rob_tag_t                     rob_tag;
    phys_reg_idx_t                phys_rs1;
    phys_reg_idx_t                phys_rs2;
    phys_reg_idx_t                phys_rd;
    logic                         rs1_used;
    logic                         rs2_used;
    logic                         rd_write;
    rv32_pkg::alu_op_e            alu_op;
    // The decoded RV32M operation travels with the renamed instruction so the
    // selected MUL/DIV unit knows which architectural result to produce.
    rv32_pkg::muldiv_op_e         muldiv_op;
    rv32_pkg::mem_op_e            mem_op;
    rv32_pkg::mem_size_e          mem_size;
    logic                         load_unsigned;
    rv32_pkg::branch_op_e         branch_op;
    rv32_pkg::control_flow_e      control_flow;
    rv32_pkg::operand_a_sel_e     operand_a_sel;
    rv32_pkg::operand_b_sel_e     operand_b_sel;
    fu_kind_e                     fu_kind;
  } issue_uop_t;

endpackage
