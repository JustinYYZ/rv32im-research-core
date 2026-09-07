// SPDX-License-Identifier: Apache-2.0
//
// Single-allocation physical-register free list for the out-of-order backend.
// The speculative bitmap serves Rename, while a committed bitmap provides the
// checkpoint restored after a pipeline recovery.

`timescale 1ns/1ps

module rv32_free_list
  import rv32_ooo_pkg::*;
(
  input  logic          clk_i,
  input  logic          rst_i,

  input  logic          alloc_valid_i,
  output logic          alloc_ready_o,
  output phys_reg_idx_t alloc_phys_rd_o,

  input  logic          commit_valid_i,
  input  phys_reg_idx_t commit_new_phys_rd_i,
  input  phys_reg_idx_t commit_old_phys_rd_i,

  input  logic          recover_i
);

  // A set bit means that the corresponding physical register is available.
  // Rename consumes the speculative bitmap; Recovery restores its checkpoint.
  logic [PHYS_REGS-1:0] free_q;
  logic [PHYS_REGS-1:0] committed_free_q;

  // Offer the lowest-numbered free register and use p0 as the empty-list output.
  logic candidate_found;
  int scan_idx;
  always_comb begin
    alloc_ready_o = 1'b0;
    alloc_phys_rd_o = '0;
    candidate_found = 1'b0;
    for (scan_idx = 1; scan_idx < PHYS_REGS; scan_idx++) begin
      if (free_q[scan_idx] && !candidate_found) begin
        alloc_phys_rd_o = phys_reg_idx_t'(scan_idx);
        alloc_ready_o = 1'b1;
        candidate_found = 1'b1;
      end
    end
  end

  // The architectural startup map owns p0-p31; p32-p63 begin free.
  int state_idx;
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      for (state_idx = 0; state_idx < PHYS_REGS; state_idx++) begin
        if (state_idx < 32) begin
          free_q[state_idx] <= 1'b0;
          committed_free_q[state_idx] <= 1'b0;
        end else begin
          free_q[state_idx] <= 1'b1;
          committed_free_q[state_idx] <= 1'b1;
        end
      end
    end else begin
      if (commit_valid_i) begin
        if (commit_old_phys_rd_i != '0) begin
          free_q[commit_old_phys_rd_i] <= 1'b1;
          committed_free_q[commit_old_phys_rd_i] <= 1'b1;
        end
        if (commit_new_phys_rd_i != '0) begin
          free_q[commit_new_phys_rd_i] <= 1'b0;
          committed_free_q[commit_new_phys_rd_i] <= 1'b0;
        end
      end
      if (!recover_i && alloc_valid_i && alloc_ready_o) begin
        free_q[alloc_phys_rd_o] <= 1'b0;
      end
      if (recover_i) begin
        free_q <= committed_free_q;
        if (commit_valid_i) begin
          if (commit_old_phys_rd_i != '0) begin
            free_q[commit_old_phys_rd_i] <= 1'b1;
          end
          if (commit_new_phys_rd_i != '0) begin
            free_q[commit_new_phys_rd_i] <= 1'b0;
          end
        end
      end
    end
  end

endmodule
