// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for rv32_decoder.
//
// Tests are grouped into cumulative milestones so later decoder changes keep
// exercising all earlier instructions. Milestone 1 covers the initial ADD,
// SUB, ADDI, LUI, AUIPC, and EBREAK subset. Milestone 2 adds the remaining
// register-register ALU instructions, milestone 3 adds immediate ALU
// instructions, milestone 5 adds control flow, and milestone 6 adds load/store.
//
// Each legal instruction checks its register fields and control outputs.
// Reserved encodings must remain illegal with architectural writes disabled.

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
  branch_op_e       branch_op;
  control_flow_e    control_flow;
  writeback_sel_e   writeback_sel;
  mem_op_e          mem_op;
  mem_size_e        mem_size;
  logic             load_unsigned;
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
    .branch_op_o    (branch_op),
    .control_flow_o (control_flow),
    .writeback_sel_o(writeback_sel),
    .mem_op_o       (mem_op),
    .mem_size_o     (mem_size),
    .load_unsigned_o(load_unsigned),
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
          branch_op !== BR_EQ ||
          control_flow !== CF_NONE ||
          writeback_sel !== WB_ALU ||
          mem_op !== MEM_NONE ||
          mem_size !== MEM_BYTE ||
          load_unsigned !== 1'b0 ||
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
      if (ebreak !== 1'b1 ||
          illegal !== 1'b0 ||
          reg_write !== 1'b0 ||
          rs1_used !== 1'b0 ||
          rs2_used !== 1'b0 ||
          branch_op !== BR_EQ ||
          control_flow !== CF_NONE ||
          writeback_sel !== WB_ALU ||
          mem_op !== MEM_NONE ||
          mem_size !== MEM_BYTE ||
          load_unsigned !== 1'b0) begin
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
          ebreak !== 1'b0 ||
          branch_op !== BR_EQ ||
          control_flow !== CF_NONE ||
          writeback_sel !== WB_ALU ||
          mem_op !== MEM_NONE ||
          mem_size !== MEM_BYTE ||
          load_unsigned !== 1'b0) begin
        $error("Test %s failed: unsafe illegal decode", test_name);
        errors++;
      end
    end
  endtask

  task automatic check_branch_decode(
    input string       test_name,
    input logic [31:0] instr_i,
    input branch_op_e  expected_branch_op
  );
    begin
      instr = instr_i;
      #1;

      if (rs1_addr !== 5'd1 ||
          rs2_addr !== 5'd2 ||
          rs1_used !== 1'b1 ||
          rs2_used !== 1'b1 ||
          alu_op !== ALU_ADD ||
          operand_a_sel !== OP_A_PC ||
          operand_b_sel !== OP_B_IMM ||
          imm_kind !== IMM_B ||
          branch_op !== expected_branch_op ||
          control_flow !== CF_BRANCH ||
          writeback_sel !== WB_ALU ||
          mem_op !== MEM_NONE ||
          mem_size !== MEM_BYTE ||
          load_unsigned !== 1'b0 ||
          reg_write !== 1'b0 ||
          ebreak !== 1'b0 ||
          illegal !== 1'b0) begin
        $error("Test %s failed: branch decode mismatch", test_name);
        errors++;
      end
    end
  endtask

  task automatic check_jump_decode(
    input string       test_name,
    input logic [31:0] instr_i,
    input control_flow_e expected_control_flow,
    input operand_a_sel_e expected_a_sel,
    input imm_kind_e expected_imm_kind,
    input logic expected_rs1_used
  );
    begin
      instr = instr_i;
      #1;

      if (rd_addr !== 5'd3 ||
          rs1_used !== expected_rs1_used ||
          rs2_used !== 1'b0 ||
          alu_op !== ALU_ADD ||
          operand_a_sel !== expected_a_sel ||
          operand_b_sel !== OP_B_IMM ||
          imm_kind !== expected_imm_kind ||
          branch_op !== BR_EQ ||
          control_flow !== expected_control_flow ||
          writeback_sel !== WB_PC_PLUS_4 ||
          mem_op !== MEM_NONE ||
          mem_size !== MEM_BYTE ||
          load_unsigned !== 1'b0 ||
          reg_write !== 1'b1 ||
          ebreak !== 1'b0 ||
          illegal !== 1'b0) begin
        $error("Test %s failed: jump decode mismatch", test_name);
        errors++;
      end

      if (expected_rs1_used && rs1_addr !== 5'd1) begin
        $error("Test %s rs1 failed: expected=1 got=%0d", test_name, rs1_addr);
        errors++;
      end
    end
  endtask

  task automatic check_load_decode(
    input string       test_name,
    input logic [31:0] instr_i,
    input mem_size_e   expected_mem_size,
    input logic        expected_load_unsigned
  );
    begin
      instr = instr_i;
      #1;

      if (rs1_addr !== 5'd1 ||
          rd_addr !== 5'd3 ||
          rs1_used !== 1'b1 ||
          rs2_used !== 1'b0 ||
          alu_op !== ALU_ADD ||
          operand_a_sel !== OP_A_RS1 ||
          operand_b_sel !== OP_B_IMM ||
          imm_kind !== IMM_I ||
          branch_op !== BR_EQ ||
          control_flow !== CF_NONE ||
          writeback_sel !== WB_MEM ||
          mem_op !== MEM_LOAD ||
          mem_size !== expected_mem_size ||
          load_unsigned !== expected_load_unsigned ||
          reg_write !== 1'b1 ||
          ebreak !== 1'b0 ||
          illegal !== 1'b0) begin
        $error("Test %s failed: load decode mismatch", test_name);
        errors++;
      end
    end
  endtask

  task automatic check_store_decode(
    input string       test_name,
    input logic [31:0] instr_i,
    input mem_size_e   expected_mem_size
  );
    begin
      instr = instr_i;
      #1;

      if (rs1_addr !== 5'd1 ||
          rs2_addr !== 5'd2 ||
          rs1_used !== 1'b1 ||
          rs2_used !== 1'b1 ||
          alu_op !== ALU_ADD ||
          operand_a_sel !== OP_A_RS1 ||
          operand_b_sel !== OP_B_IMM ||
          imm_kind !== IMM_S ||
          branch_op !== BR_EQ ||
          control_flow !== CF_NONE ||
          writeback_sel !== WB_ALU ||
          mem_op !== MEM_STORE ||
          mem_size !== expected_mem_size ||
          load_unsigned !== 1'b0 ||
          reg_write !== 1'b0 ||
          ebreak !== 1'b0 ||
          illegal !== 1'b0) begin
        $error("Test %s failed: store decode mismatch", test_name);
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

  task automatic test_milestone_2;
    begin
      check_decoder("SLL", 32'h002091b3, 5'd1, 5'd2, 5'd3, 1'b1, 1'b1,
                   ALU_SLL, OP_A_RS1, OP_B_RS2, IMM_NONE);
      check_decoder("SLT", 32'h0020a1b3, 5'd1, 5'd2, 5'd3, 1'b1, 1'b1,
                   ALU_SLT, OP_A_RS1, OP_B_RS2, IMM_NONE);
      check_decoder("SLTU", 32'h0020b1b3, 5'd1, 5'd2, 5'd3, 1'b1, 1'b1,
                   ALU_SLTU, OP_A_RS1, OP_B_RS2, IMM_NONE);
      check_decoder("XOR", 32'h0020c1b3, 5'd1, 5'd2, 5'd3, 1'b1, 1'b1,
                   ALU_XOR, OP_A_RS1, OP_B_RS2, IMM_NONE);
      check_decoder("SRL", 32'h0020d1b3, 5'd1, 5'd2, 5'd3, 1'b1, 1'b1,
                   ALU_SRL, OP_A_RS1, OP_B_RS2, IMM_NONE);
      check_decoder("SRA", 32'h4020d1b3, 5'd1, 5'd2, 5'd3, 1'b1, 1'b1,
                   ALU_SRA, OP_A_RS1, OP_B_RS2, IMM_NONE);
      check_decoder("OR", 32'h0020e1b3, 5'd1, 5'd2, 5'd3, 1'b1, 1'b1,
                   ALU_OR, OP_A_RS1, OP_B_RS2, IMM_NONE);
      check_decoder("AND", 32'h0020f1b3, 5'd1, 5'd2, 5'd3, 1'b1, 1'b1,
                   ALU_AND, OP_A_RS1, OP_B_RS2, IMM_NONE);
      check_illegal("SLL with reserved funct7", 32'h402091b3);
    end
  endtask

  task automatic test_milestone_3;
    begin
      check_decoder("SLTI", 32'hfff0a193, 5'd1, 5'd0, 5'd3, 1'b1, 1'b0,
                   ALU_SLT, OP_A_RS1, OP_B_IMM, IMM_I);
      check_decoder("SLTIU", 32'hfff0b193, 5'd1, 5'd0, 5'd3, 1'b1, 1'b0,
                   ALU_SLTU, OP_A_RS1, OP_B_IMM, IMM_I);
      check_decoder("XORI", 32'h0550c193, 5'd1, 5'd0, 5'd3, 1'b1, 1'b0,
                   ALU_XOR, OP_A_RS1, OP_B_IMM, IMM_I);
      check_decoder("ORI", 32'h0550e193, 5'd1, 5'd0, 5'd3, 1'b1, 1'b0,
                   ALU_OR, OP_A_RS1, OP_B_IMM, IMM_I);
      check_decoder("ANDI", 32'h0550f193, 5'd1, 5'd0, 5'd3, 1'b1, 1'b0,
                   ALU_AND, OP_A_RS1, OP_B_IMM, IMM_I);
      check_decoder("SLLI", 32'h00409193, 5'd1, 5'd0, 5'd3, 1'b1, 1'b0,
                   ALU_SLL, OP_A_RS1, OP_B_IMM, IMM_I);
      check_decoder("SRLI", 32'h0040d193, 5'd1, 5'd0, 5'd3, 1'b1, 1'b0,
                   ALU_SRL, OP_A_RS1, OP_B_IMM, IMM_I);
      check_decoder("SRAI", 32'h4040d193, 5'd1, 5'd0, 5'd3, 1'b1, 1'b0,
                   ALU_SRA, OP_A_RS1, OP_B_IMM, IMM_I);
      check_illegal("SLLI with reserved funct7", 32'h40409193);
    end
  endtask

  task automatic test_milestone_5;
    begin
      check_branch_decode("BEQ",  32'h00208463, BR_EQ);
      check_branch_decode("BNE",  32'h00209463, BR_NE);
      check_branch_decode("BLT",  32'h0020c463, BR_LT);
      check_branch_decode("BGE",  32'h0020d463, BR_GE);
      check_branch_decode("BLTU", 32'h0020e463, BR_LTU);
      check_branch_decode("BGEU", 32'h0020f463, BR_GEU);

      check_jump_decode("JAL", 32'h008001ef, CF_JAL, OP_A_PC, IMM_J, 1'b0);
      check_jump_decode("JALR", 32'h008081e7, CF_JALR, OP_A_RS1, IMM_I, 1'b1);

      check_illegal("reserved branch funct3", 32'h0020a463);
      check_illegal("reserved JALR funct3", 32'h008091e7);
    end
  endtask

  // Milestone 6 covers every supported load/store width and representative
  // reserved funct3 encodings that must remain free of side effects.
  task automatic test_milestone_6;
    begin
      check_load_decode("LB",  32'h00808183, MEM_BYTE, 1'b0);
      check_load_decode("LH",  32'h00809183, MEM_HALF, 1'b0);
      check_load_decode("LW",  32'h0080a183, MEM_WORD, 1'b0);
      check_load_decode("LBU", 32'h0080c183, MEM_BYTE, 1'b1);
      check_load_decode("LHU", 32'h0080d183, MEM_HALF, 1'b1);

      check_store_decode("SB", 32'h00208423, MEM_BYTE);
      check_store_decode("SH", 32'h00209423, MEM_HALF);
      check_store_decode("SW", 32'h0020a423, MEM_WORD);

      check_illegal("reserved load funct3",  32'h0080b183);
      check_illegal("reserved store funct3", 32'h0020b423);
    end
  endtask

  initial begin
    instr = 32'd0;
    errors = 0;

    test_milestone_1();
    test_milestone_2();
    test_milestone_3();
    test_milestone_5();
    test_milestone_6();

    if (errors == 0) begin
      $display("rv32_decoder_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_decoder_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
