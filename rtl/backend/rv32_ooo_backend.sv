// SPDX-License-Identifier: Apache-2.0
//
// Integer out-of-order backend integration. The first version accepts one
// decoded instruction per cycle and connects rename, scheduling, execution,
// completion, and in-order retirement. Control flow, memory, and RV32M are
// added in later stages.

`timescale 1ns/1ps

module rv32_ooo_backend
  import rv32_ooo_pkg::*;
(
  input  logic                         clk_i,
  input  logic                         rst_i,
  input  logic                         recover_i,

  input  logic                         decode_valid_i,
  output logic                         decode_ready_o,
  input  fetch_entry_t                 decode_entry_i,
  input  logic [4:0]                   decode_rs1_i,
  input  logic [4:0]                   decode_rs2_i,
  input  logic [4:0]                   decode_rd_i,
  input  logic                         decode_rs1_used_i,
  input  logic                         decode_rs2_used_i,
  input  logic                         decode_reg_write_i,
  input  logic [31:0]                  decode_imm_i,
  input  rv32_pkg::alu_op_e            decode_alu_op_i,
  input  rv32_pkg::operand_a_sel_e     decode_operand_a_sel_i,
  input  rv32_pkg::operand_b_sel_e     decode_operand_b_sel_i,

  output logic                         commit_valid_o,
  input  logic                         commit_ready_i,
  output logic [31:0]                  commit_pc_o,
  output logic [31:0]                  commit_instr_o,
  output logic [4:0]                   commit_rd_o,
  output logic                         commit_reg_write_o,
  output logic [31:0]                  commit_result_o
);

  phys_reg_idx_t map_phys_rs1;
  phys_reg_idx_t map_phys_rs2;
  phys_reg_idx_t map_rename_old_phys_rd;
  logic          map_rename_valid;
  logic [4:0]    map_rename_arch_rd;
  phys_reg_idx_t map_rename_new_phys_rd;

  logic          free_alloc_valid;
  logic          free_alloc_ready;
  phys_reg_idx_t free_alloc_phys_rd;

  logic          prf_rs1_ready;
  logic          prf_rs2_ready;
  logic          prf_alloc_valid;
  phys_reg_idx_t prf_alloc_addr;

  logic               rob_alloc_valid;
  logic               rob_alloc_ready;
  rob_tag_t           rob_alloc_tag;
  rob_alloc_payload_t rob_alloc_payload;

  logic       issue_dispatch_valid;
  logic       issue_dispatch_ready;
  issue_uop_t issue_dispatch_uop;
  logic       issue_dispatch_rs1_ready;
  logic       issue_dispatch_rs2_ready;

  logic dispatch_fire;

  logic [FU_COUNT-1:0] fu_ready;
  logic                issue_valid;
  logic                issue_ready;
  issue_uop_t          issue_uop;

  phys_reg_idx_t       prf_raddr1;
  logic [31:0]         prf_rdata1;
  phys_reg_idx_t       prf_raddr2;
  logic [31:0]         prf_rdata2;

  logic                execute_valid;
  logic                execute_ready;
  rob_tag_t            execute_rob_tag;
  phys_reg_idx_t       execute_phys_rd;
  logic                execute_rd_write;
  logic [31:0]         execute_result;

  logic                cdb_valid;
  rob_tag_t            cdb_rob_tag;
  phys_reg_idx_t       cdb_phys_rd;
  logic                cdb_rd_write;
  logic [31:0]         cdb_result;

  logic                rob_retire_valid;
  rob_entry_t          rob_head_entry;
  logic                commit_fire;

  rv32_rename_map rename_map (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .arch_rs1_i(decode_rs1_i),
    .phys_rs1_o(map_phys_rs1),
    .arch_rs2_i(decode_rs2_i),
    .phys_rs2_o(map_phys_rs2),
    .rename_arch_rd_i(map_rename_arch_rd),
    .rename_old_phys_rd_o(map_rename_old_phys_rd),
    .rename_valid_i(map_rename_valid),
    .rename_new_phys_rd_i(map_rename_new_phys_rd),
    .commit_valid_i(commit_fire && rob_head_entry.payload.reg_write),
    .commit_arch_rd_i(rob_head_entry.payload.rd),
    .commit_phys_rd_i(rob_head_entry.payload.new_phys_rd),
    .recover_i(recover_i)
  );

  rv32_free_list free_list (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .alloc_valid_i(free_alloc_valid),
    .alloc_ready_o(free_alloc_ready),
    .alloc_phys_rd_o(free_alloc_phys_rd),
    .commit_valid_i(commit_fire && rob_head_entry.payload.reg_write),
    .commit_new_phys_rd_i(rob_head_entry.payload.new_phys_rd),
    .commit_old_phys_rd_i(rob_head_entry.payload.old_phys_rd),
    .recover_i(recover_i)
  );

  rv32_phys_regfile phys_regfile (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .raddr1_i(prf_raddr1),
    .rdata1_o(prf_rdata1),
    .rready1_o(),
    .raddr2_i(prf_raddr2),
    .rdata2_o(prf_rdata2),
    .rready2_o(),
    .rename_raddr1_i(map_phys_rs1),
    .rename_rready1_o(prf_rs1_ready),
    .rename_raddr2_i(map_phys_rs2),
    .rename_rready2_o(prf_rs2_ready),
    .alloc_valid_i(prf_alloc_valid),
    .alloc_addr_i(prf_alloc_addr),
    .wb_valid_i(cdb_valid && cdb_rd_write),
    .wb_addr_i(cdb_phys_rd),
    .wb_data_i(cdb_result)
  );

  rv32_rob rob (
    .clk_i(clk_i),
    .rst_i(rst_i),

    .alloc_valid_i(rob_alloc_valid),
    .alloc_payload_i(rob_alloc_payload),
    .alloc_ready_o(rob_alloc_ready),
    .alloc_tag_o(rob_alloc_tag),

    .complete_valid_i(cdb_valid),
    .complete_tag_i(cdb_rob_tag),
    .complete_result_i(cdb_result),

    .retire_ready_i(commit_ready_i && !recover_i),
    .retire_valid_o(rob_retire_valid),
    .head_valid_o(),
    .head_tag_o(),
    .head_entry_o(rob_head_entry),

    .empty_o(),
    .full_o(),
    .count_o()
  );

  rv32_issue_queue issue_queue (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .flush_i(recover_i),

    .dispatch_valid_i(issue_dispatch_valid),
    .dispatch_ready_o(issue_dispatch_ready),
    .dispatch_uop_i(issue_dispatch_uop),
    .dispatch_rs1_ready_i(issue_dispatch_rs1_ready),
    .dispatch_rs2_ready_i(issue_dispatch_rs2_ready),

    .cdb_valid_i(cdb_valid && cdb_rd_write),
    .cdb_phys_rd_i(cdb_phys_rd),

    .fu_ready_i(fu_ready),
    .issue_valid_o(issue_valid),
    .issue_uop_o(issue_uop),

    .empty_o(),
    .full_o(),
    .count_o()
  );

  rv32_rename_dispatch rename_dispatch (
    .rst_i(rst_i),
    .recover_i(recover_i),

    .decode_valid_i(decode_valid_i),
    .decode_ready_o(decode_ready_o),
    .decode_entry_i(decode_entry_i),
    .decode_rs1_i(decode_rs1_i),
    .decode_rs2_i(decode_rs2_i),
    .decode_rd_i(decode_rd_i),
    .decode_rs1_used_i(decode_rs1_used_i),
    .decode_rs2_used_i(decode_rs2_used_i),
    .decode_reg_write_i(decode_reg_write_i),
    .decode_imm_i(decode_imm_i),
    .decode_alu_op_i(decode_alu_op_i),
    .decode_operand_a_sel_i(decode_operand_a_sel_i),
    .decode_operand_b_sel_i(decode_operand_b_sel_i),

    .map_phys_rs1_i(map_phys_rs1),
    .map_phys_rs2_i(map_phys_rs2),
    .map_old_phys_rd_i(map_rename_old_phys_rd),
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

  rv32_issue_stage issue_stage (
    .rst_i(rst_i),
    .flush_i(recover_i),

    .issue_valid_i(issue_valid),
    .issue_ready_o(issue_ready),
    .issue_uop_i(issue_uop),

    .prf_raddr1_o(prf_raddr1),
    .prf_rdata1_i(prf_rdata1),
    .prf_raddr2_o(prf_raddr2),
    .prf_rdata2_i(prf_rdata2),

    .completion_ready_i(execute_ready),
    .completion_valid_o(execute_valid),
    .completion_rob_tag_o(execute_rob_tag),
    .completion_phys_rd_o(execute_phys_rd),
    .completion_rd_write_o(execute_rd_write),
    .completion_result_o(execute_result)
  );

  rv32_completion_buffer completion_buffer (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .flush_i(recover_i),

    .execute_valid_i(execute_valid),
    .execute_ready_o(execute_ready),
    .execute_rob_tag_i(execute_rob_tag),
    .execute_phys_rd_i(execute_phys_rd),
    .execute_rd_write_i(execute_rd_write),
    .execute_result_i(execute_result),

    .cdb_valid_o(cdb_valid),
    .cdb_ready_i(1'b1),
    .cdb_rob_tag_o(cdb_rob_tag),
    .cdb_phys_rd_o(cdb_phys_rd),
    .cdb_rd_write_o(cdb_rd_write),
    .cdb_result_o(cdb_result)
  );

  // Completion backpressure propagates through the Issue Stage to the Issue
  // Queue. Only the integer ALU is available in this backend stage.
  always_comb begin
    fu_ready = '0;
    fu_ready[FU_ALU] = issue_ready;
  end

  // Retirement follows ready/valid semantics. RRAT and Free List state changes
  // are driven by commit_fire, so a stalled ROB Head keeps its payload stable.
  assign commit_valid_o = !rst_i && !recover_i && rob_retire_valid;
  assign commit_fire = commit_valid_o && commit_ready_i;
  assign commit_pc_o = commit_valid_o ? rob_head_entry.payload.pc : 32'b0;
  assign commit_instr_o = commit_valid_o ? rob_head_entry.payload.instr : 32'b0;
  assign commit_rd_o = commit_valid_o ? rob_head_entry.payload.rd : 5'b0;
  assign commit_reg_write_o = commit_valid_o && rob_head_entry.payload.reg_write;
  assign commit_result_o = commit_valid_o ? rob_head_entry.result : 32'b0;

endmodule
