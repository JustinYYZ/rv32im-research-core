// SPDX-License-Identifier: Apache-2.0
//
// Directed integration test for the integer out-of-order backend. The TB
// supplies already-decoded ALU instructions to isolate rename, issue,
// completion, and in-order retirement from frontend and Decode behavior.

`timescale 1ns/1ps

module rv32_ooo_integer_tb;
  import rv32_ooo_pkg::*;

  logic                         clk;
  logic                         rst;
  logic                         recover;
  logic                         decode_valid;
  logic                         decode_ready;
  fetch_entry_t                 decode_entry;
  logic [4:0]                   decode_rs1;
  logic [4:0]                   decode_rs2;
  logic [4:0]                   decode_rd;
  logic                         decode_rs1_used;
  logic                         decode_rs2_used;
  logic                         decode_reg_write;
  logic [31:0]                  decode_imm;
  rv32_pkg::alu_op_e            decode_alu_op;
  rv32_pkg::operand_a_sel_e     decode_operand_a_sel;
  rv32_pkg::operand_b_sel_e     decode_operand_b_sel;
  logic                         commit_valid;
  logic                         commit_ready;
  logic [31:0]                  commit_pc;
  logic [31:0]                  commit_instr;
  logic [4:0]                   commit_rd;
  logic                         commit_reg_write;
  logic [31:0]                  commit_result;
  int unsigned                  errors;

  rv32_ooo_backend dut (
    .clk_i(clk),
    .rst_i(rst),
    .recover_i(recover),
    .decode_valid_i(decode_valid),
    .decode_ready_o(decode_ready),
    .decode_entry_i(decode_entry),
    .decode_rs1_i(decode_rs1),
    .decode_rs2_i(decode_rs2),
    .decode_rd_i(decode_rd),
    .decode_rs1_used_i(decode_rs1_used),
    .decode_rs2_used_i(decode_rs2_used),
    .decode_reg_write_i(decode_reg_write),
    .decode_trap_i(1'b0),
    .decode_trap_cause_i(rv32_core_pkg::CORE_TRAP_NONE),
    .decode_imm_i(decode_imm),
    .decode_alu_op_i(decode_alu_op),
    .decode_branch_op_i(rv32_pkg::BR_EQ),
    .decode_control_flow_i(rv32_pkg::CF_NONE),
    .decode_operand_a_sel_i(decode_operand_a_sel),
    .decode_operand_b_sel_i(decode_operand_b_sel),
    .commit_valid_o(commit_valid),
    .commit_ready_i(commit_ready),
    .commit_pc_o(commit_pc),
    .commit_instr_o(commit_instr),
    .commit_rd_o(commit_rd),
    .commit_reg_write_o(commit_reg_write),
    .commit_result_o(commit_result)
  );

  always #5 clk = ~clk;

  task automatic drive_idle;
    begin
      recover = 1'b0;
      decode_valid = 1'b0;
      decode_entry = '0;
      decode_rs1 = '0;
      decode_rs2 = '0;
      decode_rd = '0;
      decode_rs1_used = 1'b0;
      decode_rs2_used = 1'b0;
      decode_reg_write = 1'b0;
      decode_imm = '0;
      decode_alu_op = rv32_pkg::ALU_ADD;
      decode_operand_a_sel = rv32_pkg::OP_A_RS1;
      decode_operand_b_sel = rv32_pkg::OP_B_RS2;
      commit_ready = 1'b1;
    end
  endtask

  task automatic reset_dut;
    begin
      rst = 1'b1;
      repeat (2) @(posedge clk);
      rst = 1'b0;
      @(negedge clk);
    end
  endtask

  task automatic dispatch_alu(
    input logic [31:0] pc,
    input logic [31:0] instr,
    input logic [4:0] rs1,
    input logic [4:0] rs2,
    input logic [4:0] rd,
    input logic rs1_used,
    input logic rs2_used,
    input logic reg_write,
    input logic [31:0] imm,
    input rv32_pkg::alu_op_e alu_op,
    input rv32_pkg::operand_a_sel_e operand_a_sel,
    input rv32_pkg::operand_b_sel_e operand_b_sel
  );
    begin
      decode_entry.pc = pc;
      decode_entry.instr = instr;
      decode_entry.predicted_next_pc = pc + 32'd4;
      decode_entry.access_fault = 1'b0;
      decode_rs1 = rs1;
      decode_rs2 = rs2;
      decode_rd = rd;
      decode_rs1_used = rs1_used;
      decode_rs2_used = rs2_used;
      decode_reg_write = reg_write;
      decode_imm = imm;
      decode_alu_op = alu_op;
      decode_operand_a_sel = operand_a_sel;
      decode_operand_b_sel = operand_b_sel;
      decode_valid = 1'b1;

      #1;

      while (decode_ready !== 1'b1) begin
        @(negedge clk);
      end

      @(posedge clk);
      #1;
      @(negedge clk);
      decode_valid = 1'b0;
    end
  endtask

  task automatic expect_commit(
    input string test_name,
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [4:0] expected_rd,
    input logic expected_reg_write,
    input logic [31:0] expected_result
  );
    int unsigned wait_cycles;
    begin
      wait_cycles = 0;
      while (commit_valid !== 1'b1 && wait_cycles < 20) begin
        @(negedge clk);
        wait_cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $display("%s: ERROR - timed out waiting for Commit", test_name);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $display("%s: ERROR - pc=%08h, expected %08h", test_name, commit_pc, expected_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $display("%s: ERROR - instr=%08h, expected %08h", test_name, commit_instr, expected_instr);
          errors++;
        end
        if (commit_rd !== expected_rd) begin
          $display("%s: ERROR - rd=%0d, expected %0d", test_name, commit_rd, expected_rd);
          errors++;
        end
        if (commit_reg_write !== expected_reg_write) begin
          $display("%s: ERROR - reg_write=%0b, expected %0b", test_name, commit_reg_write, expected_reg_write);
          errors++;
        end
        if (commit_result !== expected_result) begin
          $display("%s: ERROR - result=%08h, expected %08h", test_name, commit_result, expected_result);
          errors++;
        end

        @(posedge clk);
        #1;
      end
    end
  endtask

  task automatic expect_completion(
    input string test_name,
    input logic [31:0] expected_result
  );
    int unsigned wait_cycles;
    begin
      wait_cycles = 0;
      while (dut.cdb_valid !== 1'b1 && wait_cycles < 20) begin
        @(negedge clk);
        wait_cycles++;
      end

      if (dut.cdb_valid !== 1'b1) begin
        $display("%s: ERROR - timed out waiting for completion", test_name);
        errors++;
      end else if (dut.cdb_result !== expected_result) begin
        $display("%s: ERROR - completion result=%08h, expected %08h", test_name, dut.cdb_result, expected_result);
        errors++;
      end

      if (dut.cdb_valid === 1'b1) begin
        @(posedge clk);
        #1;
      end
    end
  endtask

  task automatic expect_stalled_commit(
    input string test_name,
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [4:0] expected_rd,
    input logic expected_reg_write,
    input logic [31:0] expected_result
  );
    int unsigned wait_cycles;
    int unsigned hold_cycles;
    begin
      wait_cycles = 0;
      while (commit_valid !== 1'b1 && wait_cycles < 20) begin
        @(negedge clk);
        wait_cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $display("%s: ERROR - timed out waiting for Commit", test_name);
        errors++;
      end else begin
        for (hold_cycles = 0; hold_cycles < 20; hold_cycles++) begin
          if (commit_valid !== 1'b1) begin
            $display("%s: ERROR - commit_valid deasserted unexpectedly", test_name);
            errors++;
          end
          if (commit_pc !== expected_pc) begin
            $display("%s: ERROR - pc=%08h, expected %08h", test_name, commit_pc, expected_pc);
            errors++;
          end
          if (commit_instr !== expected_instr) begin
            $display("%s: ERROR - instr=%08h, expected %08h", test_name, commit_instr, expected_instr);
            errors++;
          end
          if (commit_rd !== expected_rd) begin
            $display("%s: ERROR - rd=%0d, expected %0d", test_name, commit_rd, expected_rd);
            errors++;
          end
          if (commit_reg_write !== expected_reg_write) begin
            $display("%s: ERROR - reg_write=%0b, expected %0b", test_name, commit_reg_write, expected_reg_write);
            errors++;
          end
          if (commit_result !== expected_result) begin
            $display("%s: ERROR - result=%08h, expected %08h", test_name, commit_result, expected_result);
            errors++;
          end
          if (dut.commit_fire !== 1'b0) begin
            $display("%s: ERROR - commit_fire asserted unexpectedly", test_name);
            errors++;
          end
          @(negedge clk);
        end
        commit_ready = 1'b1;
        @(posedge clk);
        #1;
        if (commit_valid !== 1'b0) begin
          $display("%s: ERROR - commit_valid did not deassert after commit_ready", test_name);
          errors++;
        end
      end
    end
  endtask

  // The directed sequence covers the shortest integer path, dependent wakeup,
  // out-of-order completion with ordered retirement, and Commit backpressure.

  initial begin
    clk = 1'b0;
    rst = 1'b0;
    errors = 0;
    drive_idle();
    reset_dut();

    // A single LUI exercises the complete Rename-to-Commit path through p0.
    dispatch_alu(32'h0000_1000, 32'h1234_52b7, 5'd0, 5'd0, 5'd5, 1'b0, 1'b0, 1'b1, 32'h1234_5000, rv32_pkg::ALU_ADD, rv32_pkg::OP_A_ZERO, rv32_pkg::OP_B_IMM);
    expect_commit("single LUI", 32'h0000_1000, 32'h1234_52b7, 5'd5, 1'b1, 32'h1234_5000);

    // The consumer cannot issue until its producer broadcasts on the CDB.
    dispatch_alu(32'h0000_1004, 32'h00a0_0313, 5'd0, 5'd0, 5'd6, 1'b1, 1'b0, 1'b1, 32'h0000_000a, rv32_pkg::ALU_ADD, rv32_pkg::OP_A_RS1, rv32_pkg::OP_B_IMM);
    dispatch_alu(32'h0000_1008, 32'h0053_0393, 5'd6, 5'd0, 5'd7, 1'b1, 1'b0, 1'b1, 32'h0000_0005, rv32_pkg::ALU_ADD, rv32_pkg::OP_A_RS1, rv32_pkg::OP_B_IMM);
    expect_commit("dependent producer", 32'h0000_1004, 32'h00a0_0313, 5'd6, 1'b1, 32'h0000_000a);
    expect_commit("dependent consumer", 32'h0000_1008, 32'h0053_0393, 5'd7, 1'b1, 32'h0000_000f);

    // Hold retirement so completion order can be observed independently.
    commit_ready = 1'b0;
    fork
      begin
        expect_completion("older producer completion", 32'h0000_0014);
        expect_completion("younger independent completion", 32'h0000_001e);
        expect_completion("older dependent completion", 32'h0000_0015);
      end
      begin
        dispatch_alu(32'h0000_100c, 32'h0140_0413, 5'd0, 5'd0, 5'd8, 1'b1, 1'b0, 1'b1, 32'h0000_0014, rv32_pkg::ALU_ADD, rv32_pkg::OP_A_RS1, rv32_pkg::OP_B_IMM);
        dispatch_alu(32'h0000_1010, 32'h0014_0493, 5'd8, 5'd0, 5'd9, 1'b1, 1'b0, 1'b1, 32'h0000_0001, rv32_pkg::ALU_ADD, rv32_pkg::OP_A_RS1, rv32_pkg::OP_B_IMM);
        dispatch_alu(32'h0000_1014, 32'h01e0_0513, 5'd0, 5'd0, 5'd10, 1'b1, 1'b0, 1'b1, 32'h0000_001e, rv32_pkg::ALU_ADD, rv32_pkg::OP_A_RS1, rv32_pkg::OP_B_IMM);
      end
    join

    commit_ready = 1'b1;
    #1;
    expect_commit("older producer commit", 32'h0000_100c, 32'h0140_0413, 5'd8, 1'b1, 32'h0000_0014);
    expect_commit("older dependent commit", 32'h0000_1010, 32'h0014_0493, 5'd9, 1'b1, 32'h0000_0015);
    expect_commit("younger independent commit", 32'h0000_1014, 32'h01e0_0513, 5'd10, 1'b1, 32'h0000_001e);

    // A completed ROB Head must remain stable while Commit is backpressured.
    commit_ready = 1'b0;
    #1;
    dispatch_alu(32'h0000_1018, 32'h02c0_0593, 5'd0, 5'd0, 5'd11, 1'b1, 1'b0, 1'b1, 32'd44, rv32_pkg::ALU_ADD, rv32_pkg::OP_A_RS1, rv32_pkg::OP_B_IMM);
    expect_stalled_commit("stalled commit", 32'h0000_1018, 32'h02c0_0593, 5'd11, 1'b1, 32'd44);

    if (errors !== 0) begin
      $fatal(1, "rv32_ooo_integer_tb: FAIL - %0d errors", errors);
    end
    $display("rv32_ooo_integer_tb: PASS");
    $finish;
  end

endmodule
