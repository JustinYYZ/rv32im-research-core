// SPDX-License-Identifier: Apache-2.0
//
// Directed unit test for atomic single-instruction rename and dispatch. This TB
// drives decoded instructions and models the combinational resource responses;
// stateful RAT, Free List, ROB, PRF, and Issue Queue integration belongs to the
// later integer-backend test.

`timescale 1ns/1ps

module rv32_rename_dispatch_tb;
  import rv32_ooo_pkg::*;

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
  rv32_pkg::branch_op_e         decode_branch_op;
  rv32_pkg::control_flow_e      decode_control_flow;
  rv32_pkg::operand_a_sel_e     decode_operand_a_sel;
  rv32_pkg::operand_b_sel_e     decode_operand_b_sel;
  phys_reg_idx_t                map_phys_rs1;
  phys_reg_idx_t                map_phys_rs2;
  phys_reg_idx_t                map_old_phys_rd;
  logic                         prf_rs1_ready;
  logic                         prf_rs2_ready;
  logic                         free_alloc_ready;
  phys_reg_idx_t                free_alloc_phys_rd;
  logic                         free_alloc_valid;
  logic                         map_rename_valid;
  logic [4:0]                   map_rename_arch_rd;
  phys_reg_idx_t                map_rename_new_phys_rd;
  logic                         rob_alloc_ready;
  rob_tag_t                     rob_alloc_tag;
  logic                         rob_alloc_valid;
  rob_alloc_payload_t           rob_alloc_payload;
  logic                         issue_dispatch_ready;
  logic                         issue_dispatch_valid;
  issue_uop_t                   issue_dispatch_uop;
  logic                         issue_dispatch_rs1_ready;
  logic                         issue_dispatch_rs2_ready;
  logic                         prf_alloc_valid;
  phys_reg_idx_t                prf_alloc_addr;
  logic                         dispatch_fire;
  int unsigned                  errors;

  rv32_rename_dispatch dut (
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
    .decode_branch_op_i(decode_branch_op),
    .decode_control_flow_i(decode_control_flow),
    .decode_operand_a_sel_i(decode_operand_a_sel),
    .decode_operand_b_sel_i(decode_operand_b_sel),
    .map_phys_rs1_i(map_phys_rs1),
    .map_phys_rs2_i(map_phys_rs2),
    .map_old_phys_rd_i(map_old_phys_rd),
    .prf_rs1_ready_i(prf_rs1_ready),
    .prf_rs2_ready_i(prf_rs2_ready),
    .free_alloc_ready_i(free_alloc_ready),
    .free_alloc_phys_rd_i(free_alloc_phys_rd),
    .free_alloc_valid_o(free_alloc_valid),
    .map_rename_valid_o(map_rename_valid),
    .map_rename_arch_rd_o(map_rename_arch_rd),
    .map_rename_new_phys_rd_o(map_rename_new_phys_rd),
    .rob_alloc_ready_i(rob_alloc_ready),
    .rob_alloc_tag_i(rob_alloc_tag),
    .rob_alloc_valid_o(rob_alloc_valid),
    .rob_alloc_payload_o(rob_alloc_payload),
    .issue_dispatch_ready_i(issue_dispatch_ready),
    .issue_dispatch_valid_o(issue_dispatch_valid),
    .issue_dispatch_uop_o(issue_dispatch_uop),
    .issue_dispatch_rs1_ready_o(issue_dispatch_rs1_ready),
    .issue_dispatch_rs2_ready_o(issue_dispatch_rs2_ready),
    .prf_alloc_valid_o(prf_alloc_valid),
    .prf_alloc_addr_o(prf_alloc_addr),
    .dispatch_fire_o(dispatch_fire)
  );

  // Common input setup and reset/recovery side-effect checks.
  task automatic drive_idle;
    begin
      rst = 1'b0;
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
      decode_branch_op = rv32_pkg::BR_EQ;
      decode_control_flow = rv32_pkg::CF_NONE;
      decode_operand_a_sel = rv32_pkg::OP_A_RS1;
      decode_operand_b_sel = rv32_pkg::OP_B_RS2;
      map_phys_rs1 = '0;
      map_phys_rs2 = '0;
      map_old_phys_rd = '0;
      prf_rs1_ready = 1'b0;
      prf_rs2_ready = 1'b0;
      free_alloc_ready = 1'b1;
      free_alloc_phys_rd = '0;
      rob_alloc_ready = 1'b1;
      rob_alloc_tag = '0;
      issue_dispatch_ready = 1'b1;
    end
  endtask

  task automatic check_no_side_effects(
    input string test_name
  );
    begin
      #1;
      if (decode_ready !== 1'b0) begin
        $error("%s: decode_ready unexpectedly high", test_name);
        errors++;
      end
      if (dispatch_fire !== 1'b0) begin
        $error("%s: dispatch_fire unexpectedly high", test_name);
        errors++;
      end
      if (free_alloc_valid !== 1'b0) begin
        $error("%s: free_alloc_valid unexpectedly high", test_name);
        errors++;
      end
      if (map_rename_valid !== 1'b0) begin
        $error("%s: map_rename_valid unexpectedly high", test_name);
        errors++;
      end
      if (rob_alloc_valid !== 1'b0) begin
        $error("%s: rob_alloc_valid unexpectedly high", test_name);
        errors++;
      end
      if (issue_dispatch_valid !== 1'b0) begin
        $error("%s: issue_dispatch_valid unexpectedly high", test_name);
        errors++;
      end
      if (prf_alloc_valid !== 1'b0) begin
        $error("%s: prf_alloc_valid unexpectedly high", test_name);
        errors++;
      end
    end
  endtask

  task automatic test_reset_recovery_suppression;
    begin
      decode_valid = 1'b1;
      decode_reg_write = 1'b1;
      decode_rd = 5'd5;
      free_alloc_phys_rd = phys_reg_idx_t'(40);

      rst = 1'b1;
      check_no_side_effects("reset suppression");

      rst = 1'b0;
      recover = 1'b1;
      check_no_side_effects("recovery suppression");
      recover = 1'b0;
    end
  endtask

  // A normal ADD checks every ROB and Issue Queue field and destination allocation.

  task automatic test_normal_add;
    rob_alloc_payload_t expected_rob;
    issue_uop_t expected_uop;
    begin
      drive_idle();

      decode_valid = 1'b1;
      decode_entry.pc = 32'h8000_0000;
      decode_entry.instr = 32'h0020_82b3; // ADD x5, x1, x2
      decode_entry.predicted_next_pc = 32'h8000_0004;
      decode_entry.access_fault = 1'b0;
      decode_rs1 = 5'd1;
      decode_rs2 = 5'd2;
      decode_rd = 5'd5;
      decode_rs1_used = 1'b1;
      decode_rs2_used = 1'b1;
      decode_reg_write = 1'b1;
      decode_imm = 32'd0;
      decode_alu_op = rv32_pkg::ALU_ADD;
      decode_operand_a_sel = rv32_pkg::OP_A_RS1;
      decode_operand_b_sel = rv32_pkg::OP_B_RS2;

      map_phys_rs1 = phys_reg_idx_t'(11);
      map_phys_rs2 = phys_reg_idx_t'(22);
      map_old_phys_rd = phys_reg_idx_t'(5);
      prf_rs1_ready = 1'b1;
      prf_rs2_ready = 1'b1;
      free_alloc_phys_rd = phys_reg_idx_t'(40);
      rob_alloc_tag.generation = 1'b1;
      rob_alloc_tag.index = ROB_INDEX_WIDTH'(3);

      expected_rob = '0;
      expected_rob.pc = 32'h8000_0000;
      expected_rob.instr = 32'h0020_82b3;
      expected_rob.predicted_next_pc = 32'h8000_0004;
      expected_rob.control_flow = rv32_pkg::CF_NONE;
      expected_rob.rd = 5'd5;
      expected_rob.reg_write = 1'b1;
      expected_rob.trap = 1'b0;
      expected_rob.trap_cause = rv32_core_pkg::CORE_TRAP_NONE;
      expected_rob.new_phys_rd = phys_reg_idx_t'(40);
      expected_rob.old_phys_rd = phys_reg_idx_t'(5);

      expected_uop = '0;
      expected_uop.pc = 32'h8000_0000;
      expected_uop.instr = 32'h0020_82b3;
      expected_uop.imm = 32'd0;
      expected_uop.rob_tag = rob_alloc_tag;
      expected_uop.phys_rs1 = phys_reg_idx_t'(11);
      expected_uop.phys_rs2 = phys_reg_idx_t'(22);
      expected_uop.phys_rd = phys_reg_idx_t'(40);
      expected_uop.rs1_used = 1'b1;
      expected_uop.rs2_used = 1'b1;
      expected_uop.rd_write = 1'b1;
      expected_uop.alu_op = rv32_pkg::ALU_ADD;
      expected_uop.branch_op = rv32_pkg::BR_EQ;
      expected_uop.control_flow = rv32_pkg::CF_NONE;
      expected_uop.operand_a_sel = rv32_pkg::OP_A_RS1;
      expected_uop.operand_b_sel = rv32_pkg::OP_B_RS2;
      expected_uop.fu_kind = FU_ALU;

      #1;

      if (decode_ready !== 1'b1 || dispatch_fire !== 1'b1) begin
        $error("test_normal_add: decode_ready or dispatch_fire unexpectedly low");
        errors++;
      end
      if (free_alloc_valid !== 1'b1 || map_rename_valid !== 1'b1 || rob_alloc_valid !== 1'b1 ||
          issue_dispatch_valid !== 1'b1 || prf_alloc_valid !== 1'b1) begin
        $error("test_normal_add: one or more allocation valids unexpectedly low");
        errors++;
      end
      if (map_rename_arch_rd !== 5'd5 || map_rename_new_phys_rd !== phys_reg_idx_t'(40) || prf_alloc_addr !== phys_reg_idx_t'(40)) begin
        $error("test_normal_add: map_rename_arch_rd or map_rename_new_phys_rd mismatch");
        errors++;
      end
      if (rob_alloc_payload !== expected_rob) begin
        $error("test_normal_add: rob_alloc_payload mismatch");
        errors++;
      end
      if (issue_dispatch_uop !== expected_uop || issue_dispatch_rs1_ready !== 1'b1 || issue_dispatch_rs2_ready !== 1'b1) begin
        $error("test_normal_add: issue_dispatch_uop or issue_dispatch_rs1_ready or issue_dispatch_rs2_ready mismatch");
        errors++;
      end
    end
  endtask

  // Instructions without a real destination still enter the ROB and Issue Queue.
  task automatic test_no_destination(
    input string test_name,
    input logic [4:0] test_rd,
    input logic test_reg_write
  );
    begin
      drive_idle();

      decode_valid = 1'b1;
      decode_rd = test_rd;
      decode_reg_write = test_reg_write;
      decode_rs1_used = 1'b1;
      decode_rs2_used = 1'b1;

      free_alloc_ready = 1'b0;
      free_alloc_phys_rd = phys_reg_idx_t'(40);
      map_old_phys_rd = phys_reg_idx_t'(17);

      #1;

      if (decode_ready !== 1'b1 || dispatch_fire !== 1'b1 || rob_alloc_valid !== 1'b1 || issue_dispatch_valid !== 1'b1) begin
        $error("%s: decode_ready or dispatch_fire unexpectedly low", test_name);
        errors++;
      end

      if (free_alloc_valid !== 1'b0 || map_rename_valid !== 1'b0 || prf_alloc_valid !== 1'b0) begin
        $error("%s: free_alloc_valid or map_rename_valid or prf_alloc_valid unexpectedly high", test_name);
        errors++;
      end

      if (rob_alloc_payload.reg_write !== 1'b0 ||
          rob_alloc_payload.new_phys_rd !== '0 ||
          rob_alloc_payload.old_phys_rd !== '0 ||
          issue_dispatch_uop.rd_write !== 1'b0 ||
          issue_dispatch_uop.phys_rd !== '0) begin
        $error("%s: destination metadata was not cleared", test_name);
        errors++;
      end
    end
  endtask

  // Each unavailable required resource must block the complete transaction.
  task automatic test_resource_stall(
    input string test_name,
    input logic test_rob_ready,
    input logic test_issue_ready,
    input logic test_free_ready
  );
    begin
      drive_idle();

      decode_valid = 1'b1;
      decode_reg_write = 1'b1;
      decode_rd = 5'd5;
      rob_alloc_ready = test_rob_ready;
      issue_dispatch_ready = test_issue_ready;
      free_alloc_ready = test_free_ready;

      check_no_side_effects(test_name);
    end
  endtask

  // Unused sources are ready immediately; used sources inherit PRF readiness.
  task automatic test_source_readiness(
    input string test_name,
    input logic test_rs1_used,
    input logic test_rs2_used,
    input logic test_prf_rs1_ready,
    input logic test_prf_rs2_ready,
    input logic expected_rs1_ready,
    input logic expected_rs2_ready
  );
    begin
      drive_idle();

      decode_valid = 1'b1;
      decode_reg_write = 1'b0;
      decode_rs1_used = test_rs1_used;
      decode_rs2_used = test_rs2_used;
      prf_rs1_ready = test_prf_rs1_ready;
      prf_rs2_ready = test_prf_rs2_ready;

      #1;

      if (issue_dispatch_rs1_ready !== expected_rs1_ready ||
          issue_dispatch_rs2_ready !== expected_rs2_ready) begin
        $error("%s: test_source_readiness: issue_dispatch_rs1_ready or issue_dispatch_rs2_ready mismatch", test_name);
        errors++;
      end

      if (issue_dispatch_uop.rs1_used !== test_rs1_used ||
          issue_dispatch_uop.rs2_used !== test_rs2_used) begin
        $error("%s: test_source_readiness: issue_dispatch_uop.rs1_used or issue_dispatch_uop.rs2_used mismatch", test_name);
        errors++;
      end

      if (decode_ready !== 1'b1 || dispatch_fire !== 1'b1 ||
          rob_alloc_valid !== 1'b1 || issue_dispatch_valid !== 1'b1) begin
        $error("%s: test_source_readiness: decode_ready or dispatch_fire unexpectedly low", test_name);
        errors++;
      end
    end
  endtask

  initial begin
    errors = 0;
    drive_idle();

    test_reset_recovery_suppression();
    test_normal_add();

    test_no_destination("test_no_destination: rd=x0, reg_write=1", 5'd0, 1'b1);
    test_no_destination("test_no_destination: rd=x5, reg_write=0", 5'd5, 1'b0);

    test_resource_stall("test_resource_stall: rob_alloc_ready=0", 1'b0, 1'b1, 1'b1);
    test_resource_stall("test_resource_stall: issue_dispatch_ready=0", 1'b1, 1'b0, 1'b1);
    test_resource_stall("test_resource_stall: free_alloc_ready=0", 1'b1, 1'b1, 1'b0);

    test_source_readiness("test_source_readiness: both sources unused", 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);
    test_source_readiness("test_source_readiness: rs1 waiting, rs2 unused", 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1);
    test_source_readiness("test_source_readiness: rs1 ready, rs2 waiting", 1'b1, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0);

    if (errors !== 0) begin
      $fatal(1, "rv32_rename_dispatch_tb: %0d errors", errors);
    end
    $display("rv32_rename_dispatch_tb: all tests passed");
    $finish;
  end

endmodule
