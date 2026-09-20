// SPDX-License-Identifier: Apache-2.0
//
// One-entry registered completion buffer between the integer execution path and
// the CDB. It holds result and resolved next-PC metadata while the CDB is busy,
// and permits consume-and-replace on one edge.

`timescale 1ns/1ps

module rv32_completion_buffer
  import rv32_ooo_pkg::*;
(
  input  logic                         clk_i,
  input  logic                         rst_i,
  input  logic                         flush_i,

  input  logic                         execute_valid_i,
  output logic                         execute_ready_o,
  input  rob_tag_t                     execute_rob_tag_i,
  input  phys_reg_idx_t                execute_phys_rd_i,
  input  logic                         execute_rd_write_i,
  input  logic [31:0]                  execute_result_i,
  input  logic [31:0]                  execute_actual_next_pc_i,

  output logic                         cdb_valid_o,
  input  logic                         cdb_ready_i,
  output rob_tag_t                     cdb_rob_tag_o,
  output phys_reg_idx_t                cdb_phys_rd_o,
  output logic                         cdb_rd_write_o,
  output logic [31:0]                  cdb_result_o,
  output logic [31:0]                  cdb_actual_next_pc_o
);

  // The valid bit qualifies every payload register; invalid payload data does not
  // require reset.
  logic valid_q;
  rob_tag_t rob_tag_q;
  phys_reg_idx_t phys_rd_q;
  logic rd_write_q;
  logic [31:0] result_q;
  logic [31:0] actual_next_pc_q;
  // An occupied entry can accept a replacement when its current completion is
  // consumed on the same edge. CDB outputs never bypass the execute input.
  assign execute_ready_o = !rst_i && !flush_i && (!valid_q || cdb_ready_i);
  assign cdb_valid_o = !rst_i && !flush_i && valid_q;
  assign cdb_rob_tag_o = rob_tag_q;
  assign cdb_phys_rd_o = phys_rd_q;
  assign cdb_rd_write_o = rd_write_q;
  assign cdb_result_o = result_q;
  assign cdb_actual_next_pc_o = actual_next_pc_q;
  // Reset and recovery Flush discard the buffered speculative result. A stalled
  // entry holds all state until the CDB accepts it.
  always_ff @(posedge clk_i) begin
    if (rst_i || flush_i) begin
      valid_q <= 1'b0;
    end else if (execute_valid_i && execute_ready_o) begin
      valid_q <= 1'b1;
      rob_tag_q <= execute_rob_tag_i;
      phys_rd_q <= execute_phys_rd_i;
      rd_write_q <= execute_rd_write_i;
      result_q <= execute_result_i;
      actual_next_pc_q <= execute_actual_next_pc_i;
    end else if (cdb_ready_i && valid_q) begin
      valid_q <= 1'b0;
    end
  end

endmodule
