// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for physical-register allocation, exhaustion,
// retirement release, p0 protection, and committed-state recovery.

`timescale 1ns/1ps

module rv32_free_list_tb;
  import rv32_ooo_pkg::*;

  logic          clk;
  logic          rst;
  logic          alloc_valid;
  logic          alloc_ready;
  phys_reg_idx_t alloc_phys_rd;
  logic          commit_valid;
  phys_reg_idx_t commit_new_phys_rd;
  phys_reg_idx_t commit_old_phys_rd;
  logic          recover;
  int unsigned   errors;

  rv32_free_list dut (
    .clk_i(clk),
    .rst_i(rst),
    .alloc_valid_i(alloc_valid),
    .alloc_ready_o(alloc_ready),
    .alloc_phys_rd_o(alloc_phys_rd),
    .commit_valid_i(commit_valid),
    .commit_new_phys_rd_i(commit_new_phys_rd),
    .commit_old_phys_rd_i(commit_old_phys_rd),
    .recover_i(recover)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  task automatic reset_dut;
    begin
      @(negedge clk);
      rst = 1'b1;
      alloc_valid = 1'b0;
      commit_valid = 1'b0;
      commit_new_phys_rd = '0;
      commit_old_phys_rd = '0;
      recover = 1'b0;
      @(posedge clk);
      #1;
      rst = 1'b0;
    end
  endtask

  task automatic check_candidate(input string test_name, input logic expected_ready, input phys_reg_idx_t expected_phys_rd);
    begin
      #1;
      if (alloc_ready !== expected_ready) begin
        $error("rv32_free_list_tb: %s - alloc_ready mismatch: got %b, expected %b", test_name, alloc_ready, expected_ready);
        errors++;
      end
      if (alloc_phys_rd !== expected_phys_rd) begin
        $error("rv32_free_list_tb: %s - alloc_phys_rd mismatch: got %0d, expected %0d", test_name, alloc_phys_rd, expected_phys_rd);
        errors++;
      end
    end
  endtask

  // Accept the physical register currently offered by the combinational encoder.
  task automatic allocate_one(output phys_reg_idx_t allocated);
    begin
      allocated = '0;
      @(negedge clk);
      commit_valid = 1'b0;
      recover = 1'b0;
      alloc_valid = 1'b1;
      #1;
      if (alloc_ready !== 1'b1) begin
        $error("rv32_free_list_tb: allocate_one - no allocation available");
        errors++;
      end else begin
        allocated = alloc_phys_rd;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      alloc_valid = 1'b0;
    end
  endtask

  task automatic expect_allocate(input string test_name, input phys_reg_idx_t expected_phys_rd);
    phys_reg_idx_t actual_phys_rd;
    begin
      allocate_one(actual_phys_rd);
      if (actual_phys_rd !== expected_phys_rd) begin
        $error("rv32_free_list_tb: %s - got p%0d, expected p%0d", test_name, actual_phys_rd, expected_phys_rd);
        errors++;
      end
    end
  endtask

  // Apply a retirement update, optionally on the same edge as Recovery.
  task automatic commit_rename(input phys_reg_idx_t new_phys_rd, input phys_reg_idx_t old_phys_rd, input logic recover_same_cycle);
    begin
      @(negedge clk);
      alloc_valid = 1'b0;
      commit_new_phys_rd = new_phys_rd;
      commit_old_phys_rd = old_phys_rd;
      commit_valid = 1'b1;
      recover = recover_same_cycle;
      @(posedge clk);
      #1;
      @(negedge clk);
      commit_valid = 1'b0;
      recover = 1'b0;
      commit_new_phys_rd = '0;
      commit_old_phys_rd = '0;
    end
  endtask

  task automatic recover_free_list;
    begin
      @(negedge clk);
      alloc_valid = 1'b0;
      commit_valid = 1'b0;
      recover = 1'b1;
      @(posedge clk);
      #1;
      @(negedge clk);
      recover = 1'b0;
    end
  endtask

  task automatic test_reset_and_exhaustion;
    int unsigned expected_idx;
    begin
      reset_dut();
      check_candidate("reset candidate", 1'b1, phys_reg_idx_t'(32));
      for (expected_idx = 32; expected_idx < PHYS_REGS; expected_idx++) begin
        expect_allocate("ordered allocation", phys_reg_idx_t'(expected_idx));
      end
      check_candidate("exhausted free list", 1'b0, phys_reg_idx_t'(0));
    end
  endtask

  task automatic test_commit_release;
    begin
      reset_dut();
      expect_allocate("new mapping", phys_reg_idx_t'(32));
      commit_rename(phys_reg_idx_t'(32), phys_reg_idx_t'(5), 1'b0);
      check_candidate("released old mapping", 1'b1, phys_reg_idx_t'(5));
      expect_allocate("reallocated old mapping", phys_reg_idx_t'(5));
      check_candidate("new mapping remains occupied", 1'b1, phys_reg_idx_t'(33));
    end
  endtask

  task automatic test_speculative_recovery;
    begin
      reset_dut();
      expect_allocate("first speculative mapping", phys_reg_idx_t'(32));
      expect_allocate("second speculative mapping", phys_reg_idx_t'(33));
      recover_free_list();
      check_candidate("recovered speculative mappings", 1'b1, phys_reg_idx_t'(32));
    end
  endtask

  task automatic test_committed_recovery;
    begin
      reset_dut();
      expect_allocate("mapping before commit", phys_reg_idx_t'(32));
      commit_rename(phys_reg_idx_t'(32), phys_reg_idx_t'(5), 1'b0);
      expect_allocate("released mapping reused speculatively", phys_reg_idx_t'(5));
      expect_allocate("additional speculative mapping", phys_reg_idx_t'(33));
      recover_free_list();
      check_candidate("committed checkpoint restored", 1'b1, phys_reg_idx_t'(5));
      expect_allocate("recovered old mapping", phys_reg_idx_t'(5));
      check_candidate("committed new mapping remains occupied", 1'b1, phys_reg_idx_t'(33));
    end
  endtask

  task automatic test_p0_protection;
    begin
      reset_dut();
      commit_rename(phys_reg_idx_t'(0), phys_reg_idx_t'(0), 1'b0);
      check_candidate("p0 release ignored", 1'b1, phys_reg_idx_t'(32));
      // The encoder intentionally skips p0, so inspect both bitmaps directly.
      if ((dut.free_q[0] !== 1'b0) || (dut.committed_free_q[0] !== 1'b0)) begin
        $error("rv32_free_list_tb: p0 entered a free bitmap");
        errors++;
      end
    end
  endtask

  task automatic test_recovery_over_allocation;
    begin
      reset_dut();
      @(negedge clk);
      alloc_valid = 1'b1;
      commit_valid = 1'b0;
      recover = 1'b1;
      check_candidate("allocation offered during recovery", 1'b1, phys_reg_idx_t'(32));
      @(posedge clk);
      #1;
      @(negedge clk);
      alloc_valid = 1'b0;
      recover = 1'b0;
      check_candidate("recovery defeats allocation", 1'b1, phys_reg_idx_t'(32));
    end
  endtask

  task automatic test_commit_during_recovery;
    begin
      reset_dut();
      expect_allocate("mapping before simultaneous commit and recovery", phys_reg_idx_t'(32));
      commit_rename(phys_reg_idx_t'(32), phys_reg_idx_t'(5), 1'b1);
      check_candidate("simultaneous commit release", 1'b1, phys_reg_idx_t'(5));
      expect_allocate("released mapping after simultaneous commit", phys_reg_idx_t'(5));
      check_candidate("simultaneously committed mapping remains occupied", 1'b1, phys_reg_idx_t'(33));
      recover_free_list();
      check_candidate("later recovery retains simultaneous commit", 1'b1, phys_reg_idx_t'(5));
    end
  endtask

  initial begin
    rst = 1'b0;
    alloc_valid = 1'b0;
    commit_valid = 1'b0;
    commit_new_phys_rd = '0;
    commit_old_phys_rd = '0;
    recover = 1'b0;
    errors = 0;

    test_reset_and_exhaustion();
    test_commit_release();
    test_speculative_recovery();
    test_committed_recovery();
    test_p0_protection();
    test_recovery_over_allocation();
    test_commit_during_recovery();

    if (errors !== 0) begin
      $fatal(1, "rv32_free_list_tb: FAIL - %0d error(s)", errors);
    end
    $display("rv32_free_list_tb: PASS - All tests completed successfully");
    $finish;
  end

endmodule
