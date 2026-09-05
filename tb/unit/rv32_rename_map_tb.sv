// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for speculative RAT updates, committed RRAT updates,
// externally visible x0 mappings, recovery of committed mappings, and
// same-cycle Rename/Commit interactions with recovery.

`timescale 1ns/1ps

module rv32_rename_map_tb;
  import rv32_ooo_pkg::*;

  logic          clk;
  logic          rst;
  logic [4:0]    arch_rs1;
  phys_reg_idx_t phys_rs1;
  logic [4:0]    arch_rs2;
  phys_reg_idx_t phys_rs2;
  logic [4:0]    rename_arch_rd;
  phys_reg_idx_t rename_old_phys_rd;
  logic          rename_valid;
  phys_reg_idx_t rename_new_phys_rd;
  logic          commit_valid;
  logic [4:0]    commit_arch_rd;
  phys_reg_idx_t commit_phys_rd;
  logic          recover;
  int unsigned   errors;
  int unsigned  reg_idx;

  rv32_rename_map dut (
    .clk_i(clk),
    .rst_i(rst),
    .arch_rs1_i(arch_rs1),
    .phys_rs1_o(phys_rs1),
    .arch_rs2_i(arch_rs2),
    .phys_rs2_o(phys_rs2),
    .rename_arch_rd_i(rename_arch_rd),
    .rename_old_phys_rd_o(rename_old_phys_rd),
    .rename_valid_i(rename_valid),
    .rename_new_phys_rd_i(rename_new_phys_rd),
    .commit_valid_i(commit_valid),
    .commit_arch_rd_i(commit_arch_rd),
    .commit_phys_rd_i(commit_phys_rd),
    .recover_i(recover)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Drive reset before the active edge and wait for state updates to settle.
  task automatic reset_dut;
    begin
      @(negedge clk);
      rst = 1'b1;
      rename_valid = 1'b0;
      commit_valid = 1'b0;
      recover = 1'b0;
      @(posedge clk);
      #1;
      rst = 1'b0;
    end
  endtask

  // Allow combinational lookups to settle before checking all three ports.
  // Call with Rename inactive or with rd matching the intended destination.
  task automatic check_lookup(
    input string test_name,
    input logic [4:0] rs1,
    input phys_reg_idx_t expected_rs1,
    input logic [4:0] rs2,
    input phys_reg_idx_t expected_rs2,
    input logic [4:0] rd,
    input phys_reg_idx_t expected_old_rd
  );
    begin
      arch_rs1 = rs1;
      arch_rs2 = rs2;
      rename_arch_rd = rd;
      #1;
      if (phys_rs1 !== expected_rs1) begin
        $error("%s: phys_rs1 mismatch: got %0d, expected %0d", test_name, phys_rs1, expected_rs1);
        errors++;
      end
      if (phys_rs2 !== expected_rs2) begin
        $error("%s: phys_rs2 mismatch: got %0d, expected %0d", test_name, phys_rs2, expected_rs2);
        errors++;
      end
      if (rename_old_phys_rd !== expected_old_rd) begin
        $error("%s: rename_old_phys_rd mismatch: got %0d, expected %0d", test_name, rename_old_phys_rd, expected_old_rd);
        errors++;
      end
    end
  endtask

  // Check the old mapping before the accepting edge replaces it in RAT.
  task automatic rename_reg(
    input logic [4:0] arch_rd,
    input phys_reg_idx_t new_phys_rd,
    input phys_reg_idx_t expected_old_phys_rd
  );
    begin
      @(negedge clk);
      commit_valid = 1'b0;
      recover = 1'b0;
      rename_arch_rd = arch_rd;
      rename_new_phys_rd = new_phys_rd;
      rename_valid = 1'b1;
      #1;
      if (rename_old_phys_rd !== expected_old_phys_rd) begin
        $error("rename x%0d: old_phys_rd mismatch: got %0d, expected %0d", arch_rd, rename_old_phys_rd, expected_old_phys_rd);
        errors++;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      rename_valid = 1'b0;
      rename_arch_rd = '0;
      rename_new_phys_rd = '0;
    end
  endtask

  // Hold a standalone Commit request across one active clock edge.
  task automatic commit_mapping(
    input logic [4:0] arch_rd,
    input phys_reg_idx_t phys_rd
  );
    begin
      @(negedge clk);
      rename_valid = 1'b0;
      recover = 1'b0;
      commit_arch_rd = arch_rd;
      commit_phys_rd = phys_rd;
      commit_valid = 1'b1;
      @(posedge clk);
      #1;
      @(negedge clk);
      commit_valid = 1'b0;
      commit_arch_rd = '0;
      commit_phys_rd = '0;
    end
  endtask

  // Restore the checkpoint without accepting a Rename or Commit request.
  task automatic recover_map;
    begin
      @(negedge clk);
      rename_valid = 1'b0;
      commit_valid = 1'b0;
      recover = 1'b1;
      @(posedge clk);
      #1;
      @(negedge clk);
      recover = 1'b0;
    end
  endtask

  initial begin
    rst = 1'b0;
    arch_rs1 = '0;
    arch_rs2 = '0;
    rename_arch_rd = '0;
    rename_valid = 1'b0;
    rename_new_phys_rd = '0;
    commit_valid = 1'b0;
    commit_arch_rd = '0;
    commit_phys_rd = '0;
    recover = 1'b0;
    errors = 0;

    // Check all 32 initial RAT mappings through each external lookup port.
    reset_dut();
    for (reg_idx = 0; reg_idx < 32; reg_idx++) begin
      check_lookup($sformatf("Reset check for x%0d", reg_idx), reg_idx[4:0], phys_reg_idx_t'(reg_idx), reg_idx[4:0], phys_reg_idx_t'(reg_idx), reg_idx[4:0], phys_reg_idx_t'(reg_idx));
    end
    // An uncommitted mapping must disappear on recovery.
    rename_reg(5'd5, phys_reg_idx_t'(32), phys_reg_idx_t'(5));
    check_lookup("rename x5 to p32", 5'd5, phys_reg_idx_t'(32), 5'd5, phys_reg_idx_t'(32), 5'd5, phys_reg_idx_t'(32));
    recover_map();
    check_lookup("recover uncommitted x5", 5'd5, phys_reg_idx_t'(5), 5'd0, phys_reg_idx_t'(0), 5'd5, phys_reg_idx_t'(5));
    // Commit p32, then overwrite RAT with p33 to make recovery observable.
    rename_reg(5'd5, phys_reg_idx_t'(32), phys_reg_idx_t'(5));
    commit_mapping(5'd5, phys_reg_idx_t'(32));
    rename_reg(5'd5, phys_reg_idx_t'(33), phys_reg_idx_t'(32));
    check_lookup("rename x5 to p33 after commit", 5'd5, phys_reg_idx_t'(33), 5'd5, phys_reg_idx_t'(33), 5'd5, phys_reg_idx_t'(33));
    recover_map();
    check_lookup("recover after commit", 5'd5, phys_reg_idx_t'(32), 5'd5, phys_reg_idx_t'(32), 5'd5, phys_reg_idx_t'(32));
    // x0 lookups remain p0 after attempted updates and subsequent recovery.
    rename_reg(5'd0, phys_reg_idx_t'(40), phys_reg_idx_t'(0));
    check_lookup("rename x0 ignored", 5'd0, phys_reg_idx_t'(0), 5'd0, phys_reg_idx_t'(0), 5'd0, phys_reg_idx_t'(0));
    commit_mapping(5'd0, phys_reg_idx_t'(41));
    check_lookup("commit x0 ignored", 5'd0, phys_reg_idx_t'(0), 5'd0, phys_reg_idx_t'(0), 5'd0, phys_reg_idx_t'(0));
    recover_map();
    check_lookup("x0 after recovery", 5'd0, phys_reg_idx_t'(0), 5'd5, phys_reg_idx_t'(32), 5'd0, phys_reg_idx_t'(0));

    // Recovery must replace p33 with committed p32 and reject incoming p34.
    rename_reg(5'd5, phys_reg_idx_t'(33), phys_reg_idx_t'(32));
    @(negedge clk);
    commit_valid = 1'b0;
    rename_valid = 1'b1;
    rename_arch_rd = 5'd5;
    rename_new_phys_rd = phys_reg_idx_t'(34);
    recover = 1'b1;
    @(posedge clk);
    #1;
    @(negedge clk);
    rename_valid = 1'b0;
    rename_arch_rd = '0;
    rename_new_phys_rd = '0;
    recover = 1'b0;
    check_lookup("recover defeats same-cycle rename", 5'd5, phys_reg_idx_t'(32), 5'd0, phys_reg_idx_t'(0), 5'd5, phys_reg_idx_t'(32));

    // A same-edge Commit must be visible immediately in the recovered RAT.
    rename_reg(5'd5, phys_reg_idx_t'(35), phys_reg_idx_t'(32));
    @(negedge clk);
    rename_valid = 1'b0;
    commit_valid = 1'b1;
    commit_arch_rd = 5'd5;
    commit_phys_rd = phys_reg_idx_t'(35);
    recover = 1'b1;
    @(posedge clk);
    #1;
    @(negedge clk);
    commit_valid = 1'b0;
    commit_arch_rd = '0;
    commit_phys_rd = '0;
    recover = 1'b0;
    check_lookup("commit during recovery", 5'd5, phys_reg_idx_t'(35), 5'd0, phys_reg_idx_t'(0), 5'd5, phys_reg_idx_t'(35));
    // Recover again from a different speculative value to check RRAT retention.
    rename_reg(5'd5, phys_reg_idx_t'(36), phys_reg_idx_t'(35));
    recover_map();
    check_lookup("same-cycle commit retained", 5'd5, phys_reg_idx_t'(35), 5'd0, phys_reg_idx_t'(0), 5'd5, phys_reg_idx_t'(35));

    if (errors == 0) begin
      $display("rv32_rename_map_tb: PASS");
    end else begin
      $fatal(1, "rv32_rename_map_tb: FAIL - %0d errors", errors);
    end
    $finish;
  end

endmodule
