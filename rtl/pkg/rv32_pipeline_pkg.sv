// SPDX-License-Identifier: Apache-2.0
//
// Payload types carried by the four registers between the five pipeline stages.
// Each payload keeps the architectural identity of an instruction together
// with the control and data required by the next stage.

`timescale 1ns/1ps

package rv32_pipeline_pkg;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;

    logic trap;
    rv32_core_pkg::trap_cause_e trap_cause;

  } if_id_payload_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;

    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [4:0]  rd_addr;
    logic        rs1_used;
    logic        rs2_used;

    logic [31:0] rs1_data;
    logic [31:0] rs2_data;
    logic [31:0] imm;

    rv32_pkg::alu_op_e alu_op;
    rv32_pkg::muldiv_op_e muldiv_op;
    rv32_pkg::operand_a_sel_e operand_a_sel;
    rv32_pkg::operand_b_sel_e operand_b_sel;
    rv32_pkg::branch_op_e branch_op;
    rv32_pkg::control_flow_e control_flow;
    rv32_pkg::writeback_sel_e writeback_sel;
    rv32_pkg::mem_op_e mem_op;
    rv32_pkg::mem_size_e mem_size;
    logic load_unsigned;

    logic reg_write;

    logic trap;
    rv32_core_pkg::trap_cause_e trap_cause;

    // Source-register metadata supports RAW detection and EX forwarding. The
    // remaining fields are the decoded controls and operands consumed by EX.
  } id_ex_payload_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;

    rv32_pkg::mem_op_e mem_op;
    rv32_pkg::mem_size_e mem_size;
    logic load_unsigned;
    logic [31:0] effective_addr;
    logic [31:0] store_value;

    logic        rd_write;
    logic [4:0]  rd_addr;
    logic [31:0] rd_wdata;

    logic trap;
    rv32_core_pkg::trap_cause_e trap_cause;

    // Memory metadata carries the effective address and original store value;
    // non-memory instructions use the registered writeback result directly.
  } ex_mem_payload_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;

    rv32_pkg::mem_op_e mem_op;
    logic [31:0] mem_addr;
    logic [3:0]  mem_rmask;
    logic [3:0]  mem_wmask;
    logic [31:0] mem_rdata;
    logic [31:0] mem_wdata;

    logic        rd_write;
    logic [4:0]  rd_addr;
    logic [31:0] rd_wdata;

    logic trap;
    rv32_core_pkg::trap_cause_e trap_cause;

    // WB and the commit interface are driven only from this registered payload.
  } mem_wb_payload_t;

endpackage
