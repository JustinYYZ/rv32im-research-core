// SPDX-License-Identifier: Apache-2.0
//
// Single-dispatch, single-issue out-of-order backend with integer/control-flow
// execution and buffered RV32M producers. A shared CDB completes the ROB and
// wakes dependents; retirement preserves program order and recovers speculative
// state on redirects or traps. Data-memory execution is not yet integrated.

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
  input  logic                         decode_trap_i,
  input  rv32_core_pkg::trap_cause_e   decode_trap_cause_i,
  input  logic [31:0]                  decode_imm_i,
  input  rv32_pkg::alu_op_e            decode_alu_op_i,
  input  rv32_pkg::muldiv_op_e         decode_muldiv_op_i,
  input  rv32_pkg::branch_op_e         decode_branch_op_i,
  input  rv32_pkg::control_flow_e      decode_control_flow_i,
  input  rv32_pkg::operand_a_sel_e     decode_operand_a_sel_i,
  input  rv32_pkg::operand_b_sel_e     decode_operand_b_sel_i,

  output logic                         commit_valid_o,
  input  logic                         commit_ready_i,
  output logic [31:0]                  commit_pc_o,
  output logic [31:0]                  commit_instr_o,
  output logic [4:0]                   commit_rd_o,
  output logic                         commit_reg_write_o,
  output logic [31:0]                  commit_result_o,
  output logic                         commit_trap_o,
  output rv32_core_pkg::trap_cause_e   commit_trap_cause_o,

  output logic                         redirect_valid_o,
  output logic [31:0]                  redirect_pc_o
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
  logic [31:0]         execute_actual_next_pc;

  // Each producer retains its completion until selected by the arbiter. Only
  // the final CDB payload drives PRF writeback, ROB completion, and IQ wakeup.
  logic                alu_completion_valid;
  logic                alu_completion_ready;
  completion_payload_t alu_completion_payload;

  logic                mul_completion_valid;
  logic                mul_completion_ready;
  completion_payload_t mul_completion_payload;

  logic                div_completion_valid;
  logic                div_completion_ready;
  completion_payload_t div_completion_payload;

  logic                alu_issue_valid;
  logic                mul_issue_valid;
  logic                mul_issue_ready;
  logic                div_issue_valid;
  logic                div_issue_ready;

  logic                cdb_valid;
  rob_tag_t            cdb_rob_tag;
  phys_reg_idx_t       cdb_phys_rd;
  logic                cdb_rd_write;
  logic [31:0]         cdb_result;
  logic [31:0]         cdb_actual_next_pc;
  completion_payload_t cdb_payload;

  logic                rob_retire_valid;
  rob_entry_t          rob_head_entry;
  logic                commit_fire;
  logic                trap_commit;

  logic backend_recover;

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
    .recover_i(backend_recover)
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
    .recover_i(backend_recover)
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
    .flush_i(backend_recover),

    .alloc_valid_i(rob_alloc_valid),
    .alloc_payload_i(rob_alloc_payload),
    .alloc_ready_o(rob_alloc_ready),
    .alloc_tag_o(rob_alloc_tag),

    .complete_valid_i(cdb_valid),
    .complete_tag_i(cdb_rob_tag),
    .complete_result_i(cdb_result),
    .complete_actual_next_pc_i(cdb_actual_next_pc),

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
    .flush_i(backend_recover),

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
    .recover_i(backend_recover),

    .decode_valid_i(decode_valid_i),
    .decode_ready_o(decode_ready_o),
    .decode_entry_i(decode_entry_i),
    .decode_rs1_i(decode_rs1_i),
    .decode_rs2_i(decode_rs2_i),
    .decode_rd_i(decode_rd_i),
    .decode_rs1_used_i(decode_rs1_used_i),
    .decode_rs2_used_i(decode_rs2_used_i),
    .decode_reg_write_i(decode_reg_write_i),
    .decode_trap_i(decode_trap_i),
    .decode_trap_cause_i(decode_trap_cause_i),
    .decode_imm_i(decode_imm_i),
    .decode_alu_op_i(decode_alu_op_i),
    .decode_muldiv_op_i(decode_muldiv_op_i),
    .decode_branch_op_i(decode_branch_op_i),
    .decode_control_flow_i(decode_control_flow_i),
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

  // Route the single selected uop to one execution path. The Issue Stage
  // addresses the shared PRF read ports for ALU/branch and MUL/DIV alike.
  assign alu_issue_valid = issue_valid && ((issue_uop.fu_kind == FU_ALU) || (issue_uop.fu_kind == FU_BRANCH));
  assign mul_issue_valid = issue_valid && (issue_uop.fu_kind == FU_MUL);
  assign div_issue_valid = issue_valid && (issue_uop.fu_kind == FU_DIV);
  rv32_issue_stage issue_stage (
    .rst_i(rst_i),
    .flush_i(backend_recover),

    .issue_valid_i(alu_issue_valid),
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
    .completion_result_o(execute_result),
    .completion_actual_next_pc_o(execute_actual_next_pc)
  );

  rv32_ooo_multiplier multiplier (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .flush_i(backend_recover),

    .issue_valid_i(mul_issue_valid),
    .issue_ready_o(mul_issue_ready),
    .issue_uop_i(issue_uop),

    .issue_lhs_i(prf_rdata1),
    .issue_rhs_i(prf_rdata2),

    .completion_valid_o(mul_completion_valid),
    .completion_ready_i(mul_completion_ready),
    .completion_payload_o(mul_completion_payload)
  );

  rv32_ooo_divider divider (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .flush_i(backend_recover),

    .issue_valid_i(div_issue_valid),
    .issue_ready_o(div_issue_ready),
    .issue_uop_i(issue_uop),

    .issue_lhs_i(prf_rdata1),
    .issue_rhs_i(prf_rdata2),

    .completion_valid_o(div_completion_valid),
    .completion_ready_i(div_completion_ready),
    .completion_payload_o(div_completion_payload)
  );

  // The existing ALU/branch buffer supplies one of the three CDB producers.
  // Its scalar outputs form the same payload used by the MUL/DIV wrappers.
  rv32_completion_buffer completion_buffer (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .flush_i(backend_recover),

    .execute_valid_i(execute_valid),
    .execute_ready_o(execute_ready),
    .execute_rob_tag_i(execute_rob_tag),
    .execute_phys_rd_i(execute_phys_rd),
    .execute_rd_write_i(execute_rd_write),
    .execute_result_i(execute_result),
    .execute_actual_next_pc_i(execute_actual_next_pc),

    .cdb_valid_o(alu_completion_valid),
    .cdb_ready_i(alu_completion_ready),
    .cdb_rob_tag_o(alu_completion_payload.rob_tag),
    .cdb_phys_rd_o(alu_completion_payload.phys_rd),
    .cdb_rd_write_o(alu_completion_payload.rd_write),
    .cdb_result_o(alu_completion_payload.result),
    .cdb_actual_next_pc_o(alu_completion_payload.actual_next_pc)
  );

  // PRF and ROB accept one broadcast per cycle without downstream stalls.
  // Producer-side ready still provides backpressure when another source wins.
  rv32_cdb_arbiter cdb_arbiter (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .flush_i(backend_recover),

    .alu_valid_i(alu_completion_valid),
    .alu_ready_o(alu_completion_ready),
    .alu_payload_i(alu_completion_payload),

    .mul_valid_i(mul_completion_valid),
    .mul_ready_o(mul_completion_ready),
    .mul_payload_i(mul_completion_payload),

    .div_valid_i(div_completion_valid),
    .div_ready_o(div_completion_ready),
    .div_payload_i(div_completion_payload),

    .cdb_valid_o(cdb_valid),
    .cdb_ready_i(1'b1),
    .cdb_payload_o(cdb_payload)
  );

  assign cdb_rob_tag = cdb_payload.rob_tag;
  assign cdb_phys_rd = cdb_payload.phys_rd;
  assign cdb_rd_write = cdb_payload.rd_write;
  assign cdb_result = cdb_payload.result;
  assign cdb_actual_next_pc = cdb_payload.actual_next_pc;

  // Scheduling considers each producer's capacity independently, so a busy
  // divider does not block ready ALU/MUL work. Memory Issue remains disabled.
  always_comb begin
    fu_ready = '0;
    fu_ready[FU_ALU] = issue_ready;
    fu_ready[FU_BRANCH] = issue_ready;
    fu_ready[FU_MUL] = mul_issue_ready;
    fu_ready[FU_DIV] = div_issue_ready;
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
  assign commit_trap_o = commit_valid_o && rob_head_entry.payload.trap;
  assign commit_trap_cause_o = rv32_core_pkg::trap_cause_e'(commit_trap_o ? rob_head_entry.payload.trap_cause : rv32_core_pkg::CORE_TRAP_NONE);
  assign trap_commit = commit_fire && rob_head_entry.payload.trap;
  assign redirect_valid_o = commit_fire &&
                            !rob_head_entry.payload.trap &&
                            (rob_head_entry.payload.control_flow != rv32_pkg::CF_NONE) &&
                            (rob_head_entry.actual_next_pc != rob_head_entry.payload.predicted_next_pc);
  assign redirect_pc_o = redirect_valid_o ? rob_head_entry.actual_next_pc : 32'b0;
  assign backend_recover = recover_i || redirect_valid_o || trap_commit;

endmodule
