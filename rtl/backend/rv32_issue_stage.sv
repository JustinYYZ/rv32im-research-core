// SPDX-License-Identifier: Apache-2.0
//
// Integer Issue Stage for the first out-of-order execution path. A selected
// Issue Queue entry addresses the PRF, selects its two ALU operands, and sends
// the result and destination identities to the completion buffer.

`timescale 1ns/1ps

module rv32_issue_stage
  import rv32_ooo_pkg::*;
(
  input  logic                         rst_i,
  input  logic                         flush_i,

  input  logic                         issue_valid_i,
  output logic                         issue_ready_o,
  input  issue_uop_t                   issue_uop_i,

  output phys_reg_idx_t                prf_raddr1_o,
  input  logic [31:0]                  prf_rdata1_i,
  output phys_reg_idx_t                prf_raddr2_o,
  input  logic [31:0]                  prf_rdata2_i,

  input  logic                         completion_ready_i,
  output logic                         completion_valid_o,
  output rob_tag_t                     completion_rob_tag_o,
  output phys_reg_idx_t                completion_phys_rd_o,
  output logic                         completion_rd_write_o,
  output logic [31:0]                  completion_result_o
);

  // Operand selectors cover register, immediate, PC, and zero sources used by
  // the first integer OoO execution path.
  logic [31:0] operand_a;
  logic [31:0] operand_b;
  logic [31:0] alu_result;

  always_comb begin
    case (issue_uop_i.operand_a_sel)
      rv32_pkg::OP_A_RS1:  operand_a = prf_rdata1_i;
      rv32_pkg::OP_A_PC:   operand_a = issue_uop_i.pc;
      rv32_pkg::OP_A_ZERO: operand_a = 32'd0;
      default:                  operand_a = 32'd0;
    endcase
    case (issue_uop_i.operand_b_sel)
      rv32_pkg::OP_B_RS2:  operand_b = prf_rdata2_i;
      rv32_pkg::OP_B_IMM:  operand_b = issue_uop_i.imm;
      default:                  operand_b = 32'd0;
    endcase
  end

  rv32_alu alu (
    .op_i(issue_uop_i.alu_op),
    .lhs_i(operand_a),
    .rhs_i(operand_b),
    .result_o(alu_result)
  );

  // Completion-buffer backpressure prevents Issue Queue removal. Result identity
  // remains attached to the ALU value so writeback can update the PRF and ROB.
  assign issue_ready_o = !rst_i && !flush_i && completion_ready_i;
  assign prf_raddr1_o = issue_uop_i.phys_rs1;
  assign prf_raddr2_o = issue_uop_i.phys_rs2;
  assign completion_valid_o = !rst_i && !flush_i && issue_valid_i;
  assign completion_rob_tag_o = issue_uop_i.rob_tag;
  assign completion_phys_rd_o = issue_uop_i.phys_rd;
  assign completion_rd_write_o = issue_uop_i.rd_write;
  assign completion_result_o = alu_result;

endmodule
