// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for the initial rv32_decoder milestone.
//
// Useful instruction encodings:
//   0x002081b3  ADD   x3, x1, x2
//   0x402081b3  SUB   x3, x1, x2
//   0xfff08193  ADDI  x3, x1, -1
//   0x123451b7  LUI   x3, 0x12345
//   0x12345197  AUIPC x3, 0x12345
//   0x00100073  EBREAK
//
// Check register addresses, source-used flags, ALU operation, operand
// selections, immediate kind, register-write enable, ebreak, and illegal.
// Also test an all-zero word and reserved ADD/SUB funct fields as illegal,
// with reg_write_o deasserted.

`timescale 1ns/1ps

module rv32_decoder_tb;

  import rv32_pkg::*;

  logic [31:0]      instr;
  logic [4:0]       rs1_addr;
  logic [4:0]       rs2_addr;
  logic [4:0]       rd_addr;
  logic             rs1_used;
  logic             rs2_used;
  alu_op_e          alu_op;
  operand_a_sel_e   operand_a_sel;
  operand_b_sel_e   operand_b_sel;
  imm_kind_e        imm_kind;
  logic             reg_write;
  logic             ebreak;
  logic             illegal;
  int unsigned errors;

  rv32_decoder dut (
    .instr_i        (instr),
    .rs1_addr_o     (rs1_addr),
    .rs2_addr_o     (rs2_addr),
    .rd_addr_o      (rd_addr),
    .rs1_used_o     (rs1_used),
    .rs2_used_o     (rs2_used),
    .alu_op_o       (alu_op),
    .operand_a_sel_o(operand_a_sel),
    .operand_b_sel_o(operand_b_sel),
    .imm_kind_o     (imm_kind),
    .reg_write_o    (reg_write),
    .ebreak_o       (ebreak),
    .illegal_o      (illegal)
  );

  task automatic check_decoder(
    input string             test_name,
    input logic [31:0]       instr_i,
    input logic [4:0]        expected_rs1,
    input logic [4:0]        expected_rs2,
    input logic [4:0]        expected_rd,
    input logic              expected_rs1_used,
    input logic              expected_rs2_used,
    input alu_op_e           expected_alu_op,
    input operand_a_sel_e     expected_a_sel,
    input operand_b_sel_e     expected_b_sel,
    input imm_kind_e          expected_imm_kind
  );
    begin
      instr = instr_i;
      #1;

      if (rs1_used !== expected_rs1_used ||
          rs2_used !== expected_rs2_used ||
          alu_op !== expected_alu_op ||
          operand_a_sel !== expected_a_sel ||
          operand_b_sel !== expected_b_sel ||
          imm_kind !== expected_imm_kind ||
          reg_write !== 1'b1 ||
          ebreak !== 1'b0 ||
          illegal !== 1'b0) begin

        $error("Test %s control outputs failed for instr=%h",
               test_name, instr_i);
        errors++;
      end

      if (expected_rs1_used && rs1_addr !== expected_rs1) begin
        $error("Test %s rs1 failed: expected=%0d got=%0d",
               test_name, expected_rs1, rs1_addr);
        errors++;
      end

      if (expected_rs2_used && rs2_addr !== expected_rs2) begin
        $error("Test %s rs2 failed: expected=%0d got=%0d",
               test_name, expected_rs2, rs2_addr);
        errors++;
      end

      if (rd_addr !== expected_rd) begin
        $error("Test %s rd failed: expected=%0d got=%0d",
               test_name, expected_rd, rd_addr);
        errors++;
      end
    end
  endtask
  
  task automatic check_ebreak;
    begin
      instr = 32'h00100073;
      #1;
      if (ebreak !== 1'b1 || illegal !== 1'b0 || reg_write !== 1'b0 || rs1_used !== 1'b0 || rs2_used !== 1'b0) begin
        $error("EBREAK test failed: ebreak=%b illegal=%b reg_write=%b rs1_used=%b rs2_used=%b",
               ebreak, illegal, reg_write, rs1_used, rs2_used);
        errors++;
      end
    end
  endtask

  task automatic check_illegal(
    input string       test_name,
    input logic [31:0] instr_i
  );
    begin
      instr = instr_i;
      #1;

      if (illegal !== 1'b1 ||
          reg_write !== 1'b0 ||
          ebreak !== 1'b0) begin
        $error("Test %s failed: unsafe illegal decode", test_name);
        errors++;
      end
    end
  endtask

  task automatic test_milestone_1;
    begin
      check_decoder("ADD", 32'h002081b3, 5'd1, 5'd2, 5'd3, 1'b1, 1'b1,
                   ALU_ADD, OP_A_RS1, OP_B_RS2, IMM_NONE);
      check_decoder("SUB", 32'h402081b3, 5'd1, 5'd2, 5'd3, 1'b1, 1'b1,
                   ALU_SUB, OP_A_RS1, OP_B_RS2, IMM_NONE);
      check_decoder("ADDI", 32'hfff08193, 5'd1, 5'd0, 5'd3, 1'b1, 1'b0,
                   ALU_ADD, OP_A_RS1, OP_B_IMM, IMM_I);
      check_decoder("LUI", 32'h123451b7, 5'd0, 5'd0, 5'd3, 1'b0, 1'b0,
                   ALU_ADD, OP_A_ZERO, OP_B_IMM, IMM_U);
      check_decoder("AUIPC", 32'h12345197, 5'd0, 5'd0, 5'd3, 1'b0, 1'b0,
                   ALU_ADD, OP_A_PC, OP_B_IMM, IMM_U);
      check_ebreak();
      check_illegal("all-zero instruction", 32'h00000000);
      check_illegal("reserved RV32IM OP encoding", 32'h042081b3);
    end
  endtask


  initial begin
    instr = 32'd0;
    errors = 0;

    test_milestone_1();
    if (errors == 0) begin
      $display("rv32_decoder_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_decoder_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
