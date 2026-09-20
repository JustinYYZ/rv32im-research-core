// SPDX-License-Identifier: Apache-2.0
//
// Integer and control-flow Issue Stage. A selected Issue Queue entry reads the
// PRF, selects ALU operands, resolves the actual next PC, and sends result and
// instruction identity to the completion buffer.

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
  output logic [31:0]                  completion_result_o,
  output logic [31:0]                  completion_actual_next_pc_o
);

  // Operand selectors cover register, immediate, PC, and zero sources used by
  // integer ALU and control-flow operations.
  logic [31:0] operand_a;
  logic [31:0] operand_b;
  logic [31:0] alu_result;
  logic        branch_taken;
  logic [31:0] execution_result;
  logic [31:0] actual_next_pc;

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

  rv32_branch_unit branch_unit (
    .op_i(issue_uop_i.branch_op),
    .lhs_i(prf_rdata1_i),
    .rhs_i(prf_rdata2_i),
    .taken_o(branch_taken)
  );

  always_comb begin
    case (issue_uop_i.control_flow)
      rv32_pkg::CF_BRANCH: begin
        execution_result = alu_result;
        actual_next_pc = branch_taken ? alu_result : issue_uop_i.pc + 32'd4;
      end
      rv32_pkg::CF_JAL: begin
        execution_result = issue_uop_i.pc + 32'd4;
        actual_next_pc = alu_result;
      end
      rv32_pkg::CF_JALR: begin
        execution_result = issue_uop_i.pc + 32'd4;
        actual_next_pc = alu_result & ~32'd1;
      end
      default: begin
        execution_result = alu_result;
        actual_next_pc = issue_uop_i.pc + 32'd4;
      end

    endcase
  end

  // Completion-buffer backpressure prevents Issue Queue removal. Result and
  // resolved next-PC metadata remain attached to the same ROB identity.
  assign issue_ready_o = !rst_i && !flush_i && completion_ready_i;
  assign prf_raddr1_o = issue_uop_i.phys_rs1;
  assign prf_raddr2_o = issue_uop_i.phys_rs2;
  assign completion_valid_o = !rst_i && !flush_i && issue_valid_i;
  assign completion_rob_tag_o = issue_uop_i.rob_tag;
  assign completion_phys_rd_o = issue_uop_i.phys_rd;
  assign completion_rd_write_o = issue_uop_i.rd_write;
  assign completion_result_o = execution_result;
  assign completion_actual_next_pc_o = actual_next_pc;

endmodule
