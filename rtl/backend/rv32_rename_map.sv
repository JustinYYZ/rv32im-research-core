// SPDX-License-Identifier: Apache-2.0
//
// Speculative and committed architectural-to-physical register maps for the
// out-of-order backend. The register alias table (RAT) tracks speculative
// mappings; the retirement RAT (RRAT) tracks committed mappings for recovery.

`timescale 1ns/1ps

module rv32_rename_map
  import rv32_ooo_pkg::*;
(
  input  logic          clk_i,
  input  logic          rst_i,

  input  logic [4:0]    arch_rs1_i,
  output phys_reg_idx_t phys_rs1_o,
  input  logic [4:0]    arch_rs2_i,
  output phys_reg_idx_t phys_rs2_o,

  input  logic [4:0]    rename_arch_rd_i,
  output phys_reg_idx_t rename_old_phys_rd_o,
  input  logic          rename_valid_i,
  input  phys_reg_idx_t rename_new_phys_rd_i,

  input  logic          commit_valid_i,
  input  logic [4:0]    commit_arch_rd_i,
  input  phys_reg_idx_t commit_phys_rd_i,

  input  logic          recover_i
);

  localparam int unsigned ARCH_REGS = 32;

  // Each architectural register has a speculative and a committed mapping.
  phys_reg_idx_t rat_q[0:ARCH_REGS-1];
  phys_reg_idx_t rrat_q[0:ARCH_REGS-1];

  // Dispatch samples the old destination mapping before the Rename edge.
  // All three lookup ports hardwire x0 to p0.
  assign phys_rs1_o = (arch_rs1_i == 5'd0) ? 5'd0 : rat_q[arch_rs1_i];
  assign phys_rs2_o = (arch_rs2_i == 5'd0) ? 5'd0 : rat_q[arch_rs2_i];
  assign rename_old_phys_rd_o = (rename_arch_rd_i == 5'd0) ? 5'd0 : rat_q[rename_arch_rd_i];

  // Synchronous reset establishes x0->p0 through x31->p31 in both maps.
  int i;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      for (i = 0; i < ARCH_REGS; i++) begin
        rat_q[i] <= phys_reg_idx_t'(i);
        rrat_q[i] <= phys_reg_idx_t'(i);
      end
    end else begin
      // Retirement updates the recovery checkpoint even during recovery.
      // Requests targeting architectural x0 cannot change either mapping.
      if (commit_valid_i && commit_arch_rd_i != 5'd0) begin
        rrat_q[commit_arch_rd_i] <= commit_phys_rd_i;
      end
      // Recovery suppresses speculative Rename updates on the same edge.
      if (!recover_i && rename_valid_i && rename_arch_rd_i != 5'd0) begin
        rat_q[rename_arch_rd_i] <= rename_new_phys_rd_i;
      end
      // Restore all committed mappings, discarding speculative state.
      if (recover_i) begin
        for (i = 0; i < ARCH_REGS; i++) begin
          rat_q[i] <= rrat_q[i];
        end
        // The copy reads pre-edge RRAT values. Override the retiring destination
        // with this edge's Commit so recovered RAT includes the new checkpoint.
        if (commit_valid_i && commit_arch_rd_i != 5'd0) begin
          rat_q[commit_arch_rd_i] <= commit_phys_rd_i;
        end
      end
    end
  end
endmodule
