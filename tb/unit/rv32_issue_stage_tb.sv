// SPDX-License-Identifier: Apache-2.0
//
// Directed unit test for PRF addressing, operand selection, integer execution,
// and completion metadata produced by rv32_issue_stage.

`timescale 1ns/1ps

module rv32_issue_stage_tb;
  import rv32_ooo_pkg::*;

  logic                         rst;
  logic                         flush;
  logic                         issue_valid;
  logic                         issue_ready;
  issue_uop_t                   issue_uop;
  phys_reg_idx_t                prf_raddr1;
  logic [31:0]                  prf_rdata1;
  phys_reg_idx_t                prf_raddr2;
  logic [31:0]                  prf_rdata2;
  logic                         completion_ready;
  logic                         completion_valid;
  rob_tag_t                     completion_rob_tag;
  phys_reg_idx_t                completion_phys_rd;
  logic                         completion_rd_write;
  logic [31:0]                  completion_result;
  int unsigned                  errors;

  rv32_issue_stage dut (
    .rst_i(rst),
    .flush_i(flush),
    .issue_valid_i(issue_valid),
    .issue_ready_o(issue_ready),
    .issue_uop_i(issue_uop),
    .prf_raddr1_o(prf_raddr1),
    .prf_rdata1_i(prf_rdata1),
    .prf_raddr2_o(prf_raddr2),
    .prf_rdata2_i(prf_rdata2),
    .completion_ready_i(completion_ready),
    .completion_valid_o(completion_valid),
    .completion_rob_tag_o(completion_rob_tag),
    .completion_phys_rd_o(completion_phys_rd),
    .completion_rd_write_o(completion_rd_write),
    .completion_result_o(completion_result)
  );

  // Common input setup and physical-register read-address checks.
  task automatic drive_idle;
    begin
      rst = 1'b0;
      flush = 1'b0;
      issue_valid = 1'b0;
      issue_uop = '0;
      prf_rdata1 = '0;
      prf_rdata2 = '0;
      completion_ready = 1'b0;
    end
  endtask

  task automatic test_prf_addresses;
    begin
      drive_idle();

      issue_valid = 1'b1;
      completion_ready = 1'b1;
      issue_uop.phys_rs1 = phys_reg_idx_t'(11);
      issue_uop.phys_rs2 = phys_reg_idx_t'(22);

      #1;

      if (prf_raddr1 !== phys_reg_idx_t'(11) || prf_raddr2 !== phys_reg_idx_t'(22)) begin
        $error("PRF addresses do not match expected values: prf_raddr1=%0d, prf_raddr2=%0d", prf_raddr1, prf_raddr2);
        errors++;
      end
    end
  endtask
  // Register and immediate operations distinguish the two operand-B sources.
  task automatic test_integer_execution(
    input string test_name,
    input rv32_pkg::alu_op_e test_alu_op,
    input rv32_pkg::operand_b_sel_e test_operand_b_sel,
    input logic [31:0] test_rs1_value,
    input logic [31:0] test_rs2_value,
    input logic [31:0] test_imm,
    input logic [31:0] expected_result
  );
    begin
      drive_idle();

      issue_valid = 1'b1;
      completion_ready = 1'b1;
      issue_uop.alu_op = test_alu_op;
      issue_uop.operand_a_sel = rv32_pkg::OP_A_RS1;
      issue_uop.operand_b_sel = test_operand_b_sel;
      issue_uop.imm = test_imm;
      prf_rdata1 = test_rs1_value;
      prf_rdata2 = test_rs2_value;

      #1;

      if (issue_ready !== 1'b1 || completion_valid !== 1'b1) begin
        $error("%s: Issue stage did not assert ready when expected.", test_name);
        errors++;
      end

      if (completion_result !== expected_result) begin
        $error("%s: expected result %h, got %h", test_name, expected_result, completion_result);
        errors++;
      end
    end
  endtask
  // AUIPC and LUI distinguish the PC and zero operand-A sources.
  task automatic test_operand_a_selection(
    input string test_name,
    input rv32_pkg::operand_a_sel_e test_operand_a_sel,
    input logic [31:0] test_pc,
    input logic [31:0] test_rs1_value,
    input logic [31:0] test_imm,
    input logic [31:0] expected_result
  );
    begin
      drive_idle();

      issue_valid = 1'b1;
      completion_ready = 1'b1;
      issue_uop.pc = test_pc;
      issue_uop.imm = test_imm;
      issue_uop.alu_op = rv32_pkg::ALU_ADD;
      issue_uop.operand_a_sel = test_operand_a_sel;
      issue_uop.operand_b_sel = rv32_pkg::OP_B_IMM;
      prf_rdata1 = test_rs1_value;

      #1;

      if (issue_ready !== 1'b1 || completion_valid !== 1'b1) begin
        $error("%s: Issue stage did not assert ready when expected.", test_name);
        errors++;
      end

      if (completion_result !== expected_result) begin
        $error("%s: expected result %h, got %h", test_name, expected_result, completion_result);
        errors++;
      end
    end
  endtask
  // Completion identity remains valid whether or not the uop writes the PRF.
  task automatic test_completion_metadata(
    input string test_name,
    input logic test_generation,
    input logic [ROB_INDEX_WIDTH-1:0] test_rob_index,
    input phys_reg_idx_t test_phys_rd,
    input logic test_rd_write
  );
    rob_tag_t expected_tag;
    begin
      drive_idle();

      expected_tag.generation = test_generation;
      expected_tag.index = test_rob_index;

      issue_valid = 1'b1;
      completion_ready = 1'b1;
      issue_uop.rob_tag = expected_tag;
      issue_uop.phys_rd = test_phys_rd;
      issue_uop.rd_write = test_rd_write;
      issue_uop.alu_op = rv32_pkg::ALU_ADD;
      issue_uop.operand_a_sel = rv32_pkg::OP_A_RS1;
      issue_uop.operand_b_sel = rv32_pkg::OP_B_RS2;
      prf_rdata1 = 32'd10;
      prf_rdata2 = 32'd20;

      #1;

      if (completion_valid !== 1'b1 || completion_rob_tag !== expected_tag || completion_phys_rd !== test_phys_rd || completion_rd_write !== test_rd_write) begin
        $error("%s: Completion metadata does not match expected values: completion_valid = %0b, rob_tag=%0d, phys_rd=%0d, rd_write=%0b", test_name, completion_valid, completion_rob_tag, completion_phys_rd, completion_rd_write);
        errors++;
      end
    end
  endtask
  // Backpressure preserves the result while reset and Flush suppress transfer.
  task automatic test_backpressure_and_suppression;
    begin
      drive_idle();

      issue_valid = 1'b1;
      issue_uop.alu_op = rv32_pkg::ALU_ADD;
      issue_uop.operand_a_sel = rv32_pkg::OP_A_RS1;
      issue_uop.operand_b_sel = rv32_pkg::OP_B_RS2;
      prf_rdata1 = 32'd4;
      prf_rdata2 = 32'd6;

      completion_ready = 1'b0;
      #1;
      if (issue_ready !== 1'b0 || completion_valid !== 1'b1 || completion_result !== 32'd10) begin
        $error("backpressure: ready/valid/result mismatch");
        errors++;
      end

      completion_ready = 1'b1;
      #1;
      if (issue_ready !== 1'b1 || completion_valid !== 1'b1 || completion_result !== 32'd10) begin
        $error("backpressure release: ready/valid/result mismatch");
        errors++;
      end

      rst = 1'b1;
      #1;
      if (issue_ready !== 1'b0 || completion_valid !== 1'b0) begin
        $error("reset did not suppress Issue Stage");
        errors++;
      end

      rst = 1'b0;
      flush = 1'b1;
      #1;
      if (issue_ready !== 1'b0 || completion_valid !== 1'b0) begin
        $error("Flush did not suppress Issue Stage");
        errors++;
      end

      flush = 1'b0;
    end
  endtask

  initial begin
    errors = 0;
    drive_idle();

    test_prf_addresses();

    test_integer_execution("ADD", rv32_pkg::ALU_ADD, rv32_pkg::OP_B_RS2, 32'd7, 32'd9, 32'd100, 32'd16);
    test_integer_execution("XORI", rv32_pkg::ALU_XOR, rv32_pkg::OP_B_IMM, 32'h0000_f0f0, 32'h0000_aaaa, 32'h0000_00ff, 32'h0000_f00f);

    test_operand_a_selection("AUIPC", rv32_pkg::OP_A_PC, 32'h8000_1000, 32'h1111_1111, 32'h0000_2000, 32'h8000_3000);
    test_operand_a_selection("LUI", rv32_pkg::OP_A_ZERO, 32'haaaa_bbbb, 32'h2222_2222, 32'h0000_3000, 32'h0000_3000);

    test_completion_metadata("register-writing completion", 1'b1, ROB_INDEX_WIDTH'(3), phys_reg_idx_t'(40), 1'b1);
    test_completion_metadata("non-register-writing completion", 1'b0, ROB_INDEX_WIDTH'(5), phys_reg_idx_t'(0), 1'b0);

    test_backpressure_and_suppression();

    if (errors !== 0) begin
      $fatal(1, "rv32_issue_stage_tb: %0d errors detected", errors);
    end
    $display("rv32_issue_stage_tb: all tests passed");
    $finish;
  end

endmodule
