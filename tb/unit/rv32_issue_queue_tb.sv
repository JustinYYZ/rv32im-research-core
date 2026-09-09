// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for Issue Queue occupancy, source wakeup, selection,
// functional-unit backpressure, simultaneous operations, and recovery flush.

`timescale 1ns/1ps

module rv32_issue_queue_tb;
  import rv32_ooo_pkg::*;

  logic                         clk;
  logic                         rst;
  logic                         flush;
  logic                         dispatch_valid;
  logic                         dispatch_ready;
  issue_uop_t                   dispatch_uop;
  logic                         dispatch_rs1_ready;
  logic                         dispatch_rs2_ready;
  logic                         cdb_valid;
  phys_reg_idx_t                cdb_phys_rd;
  logic [FU_COUNT-1:0]          fu_ready;
  logic                         issue_valid;
  issue_uop_t                   issue_uop;
  logic                         empty;
  logic                         full;
  logic [ISSUE_COUNT_WIDTH-1:0] count;
  int unsigned                  errors;

  rv32_issue_queue dut (
    .clk_i(clk),
    .rst_i(rst),
    .flush_i(flush),
    .dispatch_valid_i(dispatch_valid),
    .dispatch_ready_o(dispatch_ready),
    .dispatch_uop_i(dispatch_uop),
    .dispatch_rs1_ready_i(dispatch_rs1_ready),
    .dispatch_rs2_ready_i(dispatch_rs2_ready),
    .cdb_valid_i(cdb_valid),
    .cdb_phys_rd_i(cdb_phys_rd),
    .fu_ready_i(fu_ready),
    .issue_valid_o(issue_valid),
    .issue_uop_o(issue_uop),
    .empty_o(empty),
    .full_o(full),
    .count_o(count)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Return every request and backpressure input to its inactive value.
  task automatic drive_idle;
    begin
      flush = 1'b0;
      dispatch_valid = 1'b0;
      dispatch_uop = '0;
      dispatch_rs1_ready = 1'b0;
      dispatch_rs2_ready = 1'b0;
      cdb_valid = 1'b0;
      cdb_phys_rd = '0;
      fu_ready = '0;
    end
  endtask

  task automatic reset_dut;
    begin
      @(negedge clk);
      drive_idle();
      rst = 1'b1;
      @(posedge clk);
      #1;
      rst = 1'b0;
    end
  endtask

  task automatic check_status(
    input string test_name,
    input logic expected_empty,
    input logic expected_full,
    input logic [ISSUE_COUNT_WIDTH-1:0] expected_count,
    input logic expected_dispatch_ready,
    input logic expected_issue_valid
  );
    begin
      #1;
      if (empty !== expected_empty) begin
        $error("rv32_issue_queue_tb: %s: empty mismatch, got %b, expected %b", test_name, empty, expected_empty);
        errors++;
      end
      if (full !== expected_full) begin
        $error("rv32_issue_queue_tb: %s: full mismatch, got %b, expected %b", test_name, full, expected_full);
        errors++;
      end
      if (count !== expected_count) begin
        $error("rv32_issue_queue_tb: %s: count mismatch, got %0d, expected %0d", test_name, count, expected_count);
        errors++;
      end
      if (dispatch_ready !== expected_dispatch_ready) begin
        $error("rv32_issue_queue_tb: %s: dispatch_ready mismatch, got %b, expected %b", test_name, dispatch_ready, expected_dispatch_ready);
        errors++;
      end
      if (issue_valid !== expected_issue_valid) begin
        $error("rv32_issue_queue_tb: %s: issue_valid mismatch, got %b, expected %b", test_name, issue_valid, expected_issue_valid);
        errors++;
      end
    end
  endtask

  // Present one renamed uop and its initial PRF readiness for one accepted edge.
  task automatic dispatch_one(
    input issue_uop_t uop,
    input logic rs1_ready,
    input logic rs2_ready
  );
    begin
      @(negedge clk);
      flush = 1'b0;
      cdb_valid = 1'b0;
      cdb_phys_rd = '0;
      fu_ready = '0;
      dispatch_uop = uop;
      dispatch_rs1_ready = rs1_ready;
      dispatch_rs2_ready = rs2_ready;
      dispatch_valid = 1'b1;
      #1;
      if (!dispatch_ready) begin
        $error("rv32_issue_queue_tb: dispatch_one: Dispatch not accepted");
        errors++;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      dispatch_valid = 1'b0;
      dispatch_uop = '0;
      dispatch_rs1_ready = 1'b0;
      dispatch_rs2_ready = 1'b0;
    end
  endtask

  // Check the combinational Issue result, including the zero payload when invalid.
  task automatic check_issue(
    input string test_name,
    input logic expected_valid,
    input issue_uop_t expected_uop
  );
    begin
      #1;
      if (issue_valid !== expected_valid) begin
        $error("rv32_issue_queue_tb: %s - issue_valid=%b, expected %b", test_name, issue_valid, expected_valid);
        errors++;
      end
      if (expected_valid && (issue_uop !== expected_uop)) begin
        $error("rv32_issue_queue_tb: %s - issue payload mismatch", test_name);
        errors++;
      end
      if (!expected_valid && (issue_uop !== '0)) begin
        $error("rv32_issue_queue_tb: %s - invalid Issue must drive a zero payload", test_name);
        errors++;
      end
    end
  endtask

  task automatic issue_one(
    input string test_name,
    input fu_kind_e fu_kind,
    input issue_uop_t expected_uop
  );
    begin
      @(negedge clk);
      flush = 1'b0;
      dispatch_valid = 1'b0;
      cdb_valid = 1'b0;
      fu_ready = '0;
      fu_ready[fu_kind] = 1'b1;
      check_issue(test_name, 1'b1, expected_uop);
      @(posedge clk);
      #1;
      @(negedge clk);
      fu_ready = '0;
    end
  endtask

  // Broadcast one completed physical-register tag for a full clock edge.
  task automatic broadcast_cdb(
    input phys_reg_idx_t phys_rd
  );
    begin
      @(negedge clk);
      dispatch_valid = 1'b0;
      cdb_valid = 1'b1;
      cdb_phys_rd = phys_rd;
      @(posedge clk);
      #1;
      @(negedge clk);
      cdb_valid = 1'b0;
      cdb_phys_rd = '0;
    end
  endtask

  // Directed scenarios cover occupancy, wakeup, selection, backpressure, p0,
  // simultaneous Dispatch and Issue, and recovery Flush priority.
  task automatic test_reset_state;
    begin
      reset_dut();
      check_status("Reset State", 1'b1, 1'b0, '0, 1'b1, 1'b0);
    end
  endtask

  task automatic test_single_dispatch;
    issue_uop_t test_uop;
    begin
      reset_dut();

      test_uop = '0;
      test_uop.rob_tag.generation = 1'b1;
      test_uop.rob_tag.index = ROB_INDEX_WIDTH'(3);
      test_uop.phys_rs1 = PHYS_REG_INDEX_WIDTH'(7);
      test_uop.phys_rs2 = PHYS_REG_INDEX_WIDTH'(8);
      test_uop.phys_rd = PHYS_REG_INDEX_WIDTH'(32);
      test_uop.rs1_used = 1'b1;
      test_uop.rs2_used = 1'b1;
      test_uop.rd_write = 1'b1;
      test_uop.fu_kind = FU_ALU;

      dispatch_one(test_uop, 1'b1, 1'b0);
      check_status("Single Dispatch", 1'b0, 1'b0, ISSUE_COUNT_WIDTH'(1), 1'b1, 1'b0);
      if (!dut.entry_valid_q[0]) begin
        $error("rv32_issue_queue_tb: Single Dispatch: Entry 0 not valid after dispatch");
        errors++;
      end
      if (dut.entry_uop_q[0] !== test_uop) begin
        $error("rv32_issue_queue_tb: Single Dispatch: Entry 0 uop mismatch after dispatch");
        errors++;
      end
      if ((dut.entry_rs1_ready_q[0] !== 1'b1) || (dut.entry_rs2_ready_q[0] !== 1'b0)) begin
        $error("rv32_issue_queue_tb: Single Dispatch: Entry 0 source readiness mismatch after dispatch");
        errors++;
      end
    end
  endtask

  task automatic test_ready_selection;
    issue_uop_t test_uop;
    begin
      reset_dut();
      test_uop = '0;
      test_uop.rob_tag.index = ROB_INDEX_WIDTH'(1);
      test_uop.phys_rs1 = phys_reg_idx_t'(6);
      test_uop.phys_rs2 = phys_reg_idx_t'(7);
      test_uop.phys_rd = phys_reg_idx_t'(32);
      test_uop.rs1_used = 1'b1;
      test_uop.rs2_used = 1'b1;
      test_uop.rd_write = 1'b1;
      test_uop.fu_kind = FU_ALU;
      dispatch_one(test_uop, 1'b1, 1'b1);
      fu_ready[FU_ALU] = 1'b1;
      check_issue("ready ALU entry", 1'b1, test_uop);

      reset_dut();
      test_uop.rob_tag.index = ROB_INDEX_WIDTH'(2);
      dispatch_one(test_uop, 1'b0, 1'b1);
      fu_ready[FU_ALU] = 1'b1;
      check_issue("waiting ALU entry", 1'b0, '0);

      reset_dut();
      test_uop.rob_tag.index = ROB_INDEX_WIDTH'(3);
      test_uop.rs1_used = 1'b0;
      test_uop.rs2_used = 1'b0;
      dispatch_one(test_uop, 1'b0, 1'b0);
      fu_ready[FU_ALU] = 1'b1;
      check_issue("unused sources", 1'b1, test_uop);
    end
  endtask

  task automatic test_issue_removal;
    issue_uop_t test_uop;
    begin
      reset_dut();
      test_uop = '0;
      test_uop.rob_tag.index = ROB_INDEX_WIDTH'(4);
      test_uop.phys_rs1 = phys_reg_idx_t'(6);
      test_uop.phys_rs2 = phys_reg_idx_t'(7);
      test_uop.phys_rd = phys_reg_idx_t'(34);
      test_uop.rs1_used = 1'b1;
      test_uop.rs2_used = 1'b1;
      test_uop.rd_write = 1'b1;
      test_uop.fu_kind = FU_ALU;
      dispatch_one(test_uop, 1'b1, 1'b1);
      check_status("before issue", 1'b0, 1'b0, ISSUE_COUNT_WIDTH'(1), 1'b1, 1'b0);
      issue_one("select entry before removal", FU_ALU, test_uop);
      check_status("after issue", 1'b1, 1'b0, '0, 1'b1, 1'b0);
      if (dut.entry_valid_q[0] !== 1'b0) begin
        $error("rv32_issue_queue_tb: test_issue_removal: Entry 0 still valid after issue");
        errors++;
      end
      if ((dut.entry_rs1_ready_q[0] !== 1'b0) || (dut.entry_rs2_ready_q[0] !== 1'b0)) begin
        $error("rv32_issue_queue_tb: test_issue_removal: Entry 0 source readiness not cleared after issue");
        errors++;
      end
    end
  endtask

  task automatic test_cdb_wakeup;
    issue_uop_t test_uop;
    begin
      reset_dut();
      test_uop = '0;
      test_uop.rob_tag.index = ROB_INDEX_WIDTH'(5);
      test_uop.phys_rs1 = phys_reg_idx_t'(10);
      test_uop.phys_rs2 = phys_reg_idx_t'(11);
      test_uop.phys_rd = phys_reg_idx_t'(35);
      test_uop.rs1_used = 1'b1;
      test_uop.rs2_used = 1'b1;
      test_uop.rd_write = 1'b1;
      test_uop.fu_kind = FU_ALU;
      dispatch_one(test_uop, 1'b0, 1'b1);
      fu_ready[FU_ALU] = 1'b1;
      check_issue("waiting for p10", 1'b0, '0);
      @(negedge clk);
      cdb_valid = 1'b1;
      cdb_phys_rd = phys_reg_idx_t'(10);
      check_issue("CDB does not bypass selector combinationally", 1'b0, '0);
      @(posedge clk);
      #1;
      check_issue("CDB wakeup after clock edge", 1'b1, test_uop);
      @(negedge clk);
      cdb_valid = 1'b0;
      cdb_phys_rd = '0;
      fu_ready = '0;

      reset_dut();
      test_uop.rob_tag.index = ROB_INDEX_WIDTH'(6);
      test_uop.phys_rs1 = phys_reg_idx_t'(12);
      test_uop.phys_rs2 = phys_reg_idx_t'(13);
      dispatch_one(test_uop, 1'b0, 1'b0);
      fu_ready[FU_ALU] = 1'b1;
      broadcast_cdb(phys_reg_idx_t'(12));
      check_issue("still wait for p13", 1'b0, '0);
      broadcast_cdb(phys_reg_idx_t'(13));
      check_issue("both sources wakeup", 1'b1, test_uop);
      fu_ready = '0;

      reset_dut();
      test_uop.rob_tag.index = ROB_INDEX_WIDTH'(7);
      test_uop.phys_rs1 = phys_reg_idx_t'(14);
      test_uop.phys_rs2 = phys_reg_idx_t'(15);
      @(negedge clk);
      dispatch_valid = 1'b1;
      dispatch_uop = test_uop;
      dispatch_rs1_ready = 1'b0;
      dispatch_rs2_ready = 1'b1;
      cdb_valid = 1'b1;
      cdb_phys_rd = phys_reg_idx_t'(14);
      #1;
      if (!dispatch_ready) begin
        $error("rv32_issue_queue_tb: test_cdb_wakeup: Dispatch not accepted with CDB wakeup");
        errors++;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      dispatch_valid = 1'b0;
      cdb_valid = 1'b0;
      cdb_phys_rd = '0;
      fu_ready[FU_ALU] = 1'b1;
      check_issue("CDB wakeup for newly dispatched entry", 1'b1, test_uop);
      fu_ready = '0;
    end
  endtask

  task automatic test_fu_selection;
    issue_uop_t div_uop;
    issue_uop_t alu_uop;
    begin
      reset_dut();
      div_uop = '0;
      div_uop.rob_tag.index = ROB_INDEX_WIDTH'(8);
      div_uop.phys_rd = phys_reg_idx_t'(40);
      div_uop.rs1_used = 1'b0;
      div_uop.rs2_used = 1'b0;
      div_uop.rd_write = 1'b1;
      div_uop.fu_kind = FU_DIV;

      alu_uop = '0;
      alu_uop.rob_tag.index = ROB_INDEX_WIDTH'(9);
      alu_uop.phys_rd = phys_reg_idx_t'(41);
      alu_uop.rs1_used = 1'b0;
      alu_uop.rs2_used = 1'b0;
      alu_uop.rd_write = 1'b1;
      alu_uop.fu_kind = FU_ALU;

      dispatch_one(div_uop, 1'b0, 1'b0);
      dispatch_one(alu_uop, 1'b0, 1'b0);
      check_status("two ready entries", 1'b0, 1'b0, ISSUE_COUNT_WIDTH'(2), 1'b1, 1'b0);
      fu_ready[FU_DIV] = 1'b1;
      fu_ready[FU_ALU] = 1'b1;
      check_issue("lowest-slot priority", 1'b1, div_uop);
      fu_ready[FU_DIV] = 1'b0;
      check_issue("blocked FU does not prevent other FU", 1'b1, alu_uop);
      @(posedge clk);
      #1;
      fu_ready[FU_ALU] = 1'b0;
      check_status("after alu issue", 1'b0, 1'b0, ISSUE_COUNT_WIDTH'(1), 1'b1, 1'b0);
      fu_ready[FU_DIV] = 1'b1;
      check_issue("div entry still ready", 1'b1, div_uop);
      @(posedge clk);
      #1;
      fu_ready = '0;
      check_status("after div issue", 1'b1, 1'b0, '0, 1'b1, 1'b0);

    end
  endtask

  task automatic test_full_queue;
    issue_uop_t test_uop;
    issue_uop_t first_uop;
    int unsigned entry_idx;
    begin
      reset_dut();
      for (entry_idx = 0; entry_idx < ISSUE_ENTRIES; entry_idx++) begin
        test_uop = '0;
        test_uop.rob_tag.index = ROB_INDEX_WIDTH'(entry_idx);
        test_uop.phys_rd = phys_reg_idx_t'(32 + entry_idx);
        test_uop.rs1_used = 1'b0;
        test_uop.rs2_used = 1'b0;
        test_uop.rd_write = 1'b1;
        test_uop.fu_kind = FU_ALU;
        if (entry_idx == 0) begin
          first_uop = test_uop;
        end
        dispatch_one(test_uop, 1'b0, 1'b0);
      end
      check_status("full queue", 1'b0, 1'b1, ISSUE_COUNT_WIDTH'(ISSUE_ENTRIES), 1'b0, 1'b0);

      test_uop = '0;
      test_uop.rob_tag.index = ROB_INDEX_WIDTH'(8);
      test_uop.phys_rd = phys_reg_idx_t'(40);
      test_uop.rs1_used = 1'b0;
      test_uop.rs2_used = 1'b0;
      test_uop.rd_write = 1'b1;
      test_uop.fu_kind = FU_ALU;

      @(negedge clk);
      dispatch_valid = 1'b1;
      dispatch_uop = test_uop;
      dispatch_rs1_ready = 1'b0;
      dispatch_rs2_ready = 1'b0;
      #1;
      check_status("full queue blocks dispatch", 1'b0, 1'b1, ISSUE_COUNT_WIDTH'(ISSUE_ENTRIES), 1'b0, 1'b0);

      @(posedge clk);
      #1;
      check_status("full queue still blocks dispatch", 1'b0, 1'b1, ISSUE_COUNT_WIDTH'(ISSUE_ENTRIES), 1'b0, 1'b0);

      @(negedge clk);
      fu_ready[FU_ALU] = 1'b1;
      check_status("ready to issue first entry", 1'b0, 1'b1, ISSUE_COUNT_WIDTH'(ISSUE_ENTRIES), 1'b0, 1'b1);
      check_issue("issue first entry", 1'b1, first_uop);
      @(posedge clk);
      #1;
      check_status("after first issue", 1'b0, 1'b0, ISSUE_COUNT_WIDTH'(ISSUE_ENTRIES - 1), 1'b1, 1'b1);
      @(posedge clk);
      #1;
      @(negedge clk);
      dispatch_valid = 1'b0;
      dispatch_uop = '0;
      fu_ready = '0;
      check_status("simultaneous dispatch and issue", 1'b0, 1'b0, ISSUE_COUNT_WIDTH'(ISSUE_ENTRIES - 1), 1'b1, 1'b0);

      if (!dut.entry_valid_q[0] || dut.entry_uop_q[0] !== test_uop) begin
        $error("rv32_issue_queue_tb: simultaneous dispatch did not store the waiting uop");
        errors++;
      end
    end
  endtask

  task automatic test_p0_cdb_ignored;
    issue_uop_t test_uop;
    begin
      reset_dut();

      test_uop = '0;
      test_uop.rob_tag.index = ROB_INDEX_WIDTH'(10);
      test_uop.phys_rs1 = '0;
      test_uop.phys_rd = phys_reg_idx_t'(42);
      test_uop.rs1_used = 1'b1;
      test_uop.rs2_used = 1'b0;
      test_uop.rd_write = 1'b1;
      test_uop.fu_kind = FU_ALU;

      dispatch_one(test_uop, 1'b0, 1'b0);
      fu_ready[FU_ALU] = 1'b1;
      check_issue("waiting for p0", 1'b0, '0);
      broadcast_cdb('0);
      check_issue("CDB p0 ignored", 1'b0, '0);
      check_status("CDB p0 ignored", 1'b0, 1'b0, ISSUE_COUNT_WIDTH'(1), 1'b1, 1'b0);
      fu_ready = '0;
    end
  endtask

  task automatic test_flush_priority;
    issue_uop_t ready_uop;
    issue_uop_t waiting_uop;
    issue_uop_t incoming_uop;
    begin
      reset_dut();

      ready_uop = '0;
      ready_uop.rob_tag.index = ROB_INDEX_WIDTH'(11);
      ready_uop.phys_rd = phys_reg_idx_t'(43);
      ready_uop.rs1_used = 1'b0;
      ready_uop.rs2_used = 1'b0;
      ready_uop.rd_write = 1'b1;
      ready_uop.fu_kind = FU_ALU;
      dispatch_one(ready_uop, 1'b0, 1'b0);

      waiting_uop = '0;
      waiting_uop.rob_tag.index = ROB_INDEX_WIDTH'(12);
      waiting_uop.phys_rs1 = phys_reg_idx_t'(17);
      waiting_uop.phys_rd = phys_reg_idx_t'(44);
      waiting_uop.rs1_used = 1'b1;
      waiting_uop.rs2_used = 1'b0;
      waiting_uop.rd_write = 1'b1;
      waiting_uop.fu_kind = FU_ALU;
      dispatch_one(waiting_uop, 1'b0, 1'b0);
      check_status("before flush", 1'b0, 1'b0, ISSUE_COUNT_WIDTH'(2), 1'b1, 1'b0);

      incoming_uop = '0;
      incoming_uop.rob_tag.index = ROB_INDEX_WIDTH'(13);
      incoming_uop.phys_rd = phys_reg_idx_t'(45);
      incoming_uop.rs1_used = 1'b0;
      incoming_uop.rs2_used = 1'b0;
      incoming_uop.rd_write = 1'b1;
      incoming_uop.fu_kind = FU_ALU;

      @(negedge clk);
      flush = 1'b1;
      dispatch_valid = 1'b1;
      dispatch_uop = incoming_uop;
      dispatch_rs1_ready = 1'b0;
      dispatch_rs2_ready = 1'b0;
      cdb_valid = 1'b1;
      cdb_phys_rd = phys_reg_idx_t'(17);
      fu_ready[FU_ALU] = 1'b1;

      check_status("flush blocks all operations", 1'b0, 1'b0, ISSUE_COUNT_WIDTH'(2), 1'b0, 1'b0);
      @(posedge clk);
      #1;
      check_status("flush clears queue", 1'b1, 1'b0, '0, 1'b0, 1'b0);
      @(negedge clk);
      drive_idle();
      check_status("after flush deassertion", 1'b1, 1'b0, '0, 1'b1, 1'b0);
    end
  endtask

  initial begin
    rst = 1'b0;
    flush = 1'b0;
    dispatch_valid = 1'b0;
    dispatch_uop = '0;
    dispatch_rs1_ready = 1'b0;
    dispatch_rs2_ready = 1'b0;
    cdb_valid = 1'b0;
    cdb_phys_rd = '0;
    fu_ready = '0;
    errors = 0;

    test_reset_state();
    test_single_dispatch();
    test_ready_selection();
    test_issue_removal();
    test_cdb_wakeup();
    test_fu_selection();
    test_full_queue();
    test_p0_cdb_ignored();
    test_flush_priority();

    if (errors !== 0) begin
      $fatal(1, "rv32_issue_queue_tb: %0d errors detected", errors);
    end
    $display("rv32_issue_queue_tb: All tests passed");
    $finish;
  end

endmodule
