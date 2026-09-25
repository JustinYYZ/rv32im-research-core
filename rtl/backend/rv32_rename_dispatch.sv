// SPDX-License-Identifier: Apache-2.0
//
// Atomic rename and dispatch control for the single-issue out-of-order backend.
// A decoded instruction may update the Free List, rename map, physical register
// file, ROB, and Issue Queue only when every resource it needs can accept it.

`timescale 1ns/1ps

module rv32_rename_dispatch
  import rv32_ooo_pkg::*;
(
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
  input  rv32_pkg::mem_op_e            decode_mem_op_i,
  input  rv32_pkg::mem_size_e          decode_mem_size_i,
  input  logic                         decode_load_unsigned_i,
  input  rv32_pkg::branch_op_e         decode_branch_op_i,
  input  rv32_pkg::control_flow_e      decode_control_flow_i,
  input  rv32_pkg::operand_a_sel_e     decode_operand_a_sel_i,
  input  rv32_pkg::operand_b_sel_e     decode_operand_b_sel_i,

  input  phys_reg_idx_t                map_phys_rs1_i,
  input  phys_reg_idx_t                map_phys_rs2_i,
  input  phys_reg_idx_t                map_old_phys_rd_i,
  input  logic                         prf_rs1_ready_i,
  input  logic                         prf_rs2_ready_i,

  input  logic                         free_alloc_ready_i,
  input  phys_reg_idx_t                free_alloc_phys_rd_i,
  output logic                         free_alloc_valid_o,

  output logic                         map_rename_valid_o,
  output logic [4:0]                   map_rename_arch_rd_o,
  output phys_reg_idx_t                map_rename_new_phys_rd_o,

  input  logic                         rob_alloc_ready_i,
  input  rob_tag_t                     rob_alloc_tag_i,
  output logic                         rob_alloc_valid_o,
  output rob_alloc_payload_t           rob_alloc_payload_o,

  input  logic                         issue_dispatch_ready_i,
  output logic                         issue_dispatch_valid_o,
  output issue_uop_t                   issue_dispatch_uop_o,
  output logic                         issue_dispatch_rs1_ready_o,
  output logic                         issue_dispatch_rs2_ready_o,

  output logic                         prf_alloc_valid_o,
  output phys_reg_idx_t                prf_alloc_addr_o,
  output logic                         dispatch_fire_o
);

  // Writes to x0 and instructions without register writeback do not consume a
  // physical destination.
  logic destination_required;
  assign destination_required = decode_reg_write_i && !decode_trap_i && (decode_rd_i != 5'd0);

  logic mul_operation;
  logic div_operation;

  // Dispatch is atomic across the ROB, Issue Queue, and optional physical-register
  // allocation. Every state-changing valid derives from the same accepted input.
  assign decode_ready_o = !rst_i && !recover_i && rob_alloc_ready_i && issue_dispatch_ready_i &&
                          (!destination_required || free_alloc_ready_i);
  assign free_alloc_valid_o = dispatch_fire_o && destination_required;
  assign map_rename_valid_o = dispatch_fire_o && destination_required;
  assign map_rename_arch_rd_o = decode_rd_i;
  assign map_rename_new_phys_rd_o = destination_required ? free_alloc_phys_rd_i : '0;

  assign rob_alloc_valid_o = dispatch_fire_o;
  assign rob_alloc_payload_o.pc = decode_entry_i.pc;
  assign rob_alloc_payload_o.instr = decode_entry_i.instr;
  assign rob_alloc_payload_o.predicted_next_pc = decode_entry_i.predicted_next_pc;
  assign rob_alloc_payload_o.control_flow = decode_trap_i ? rv32_pkg::CF_NONE : decode_control_flow_i;
  assign rob_alloc_payload_o.trap = decode_trap_i;
  assign rob_alloc_payload_o.trap_cause = decode_trap_cause_i;
  assign rob_alloc_payload_o.rd = decode_rd_i;
  assign rob_alloc_payload_o.reg_write = destination_required;
  assign rob_alloc_payload_o.new_phys_rd = destination_required ? free_alloc_phys_rd_i : '0;
  assign rob_alloc_payload_o.old_phys_rd = destination_required ? map_old_phys_rd_i : '0;

  assign issue_dispatch_valid_o = dispatch_fire_o;
  assign issue_dispatch_uop_o.pc = decode_entry_i.pc;
  assign issue_dispatch_uop_o.instr = decode_entry_i.instr;
  assign issue_dispatch_uop_o.imm = decode_imm_i;
  assign issue_dispatch_uop_o.rob_tag = rob_alloc_tag_i;
  assign issue_dispatch_uop_o.phys_rs1 = map_phys_rs1_i;
  assign issue_dispatch_uop_o.phys_rs2 = map_phys_rs2_i;
  assign issue_dispatch_uop_o.phys_rd = destination_required ? free_alloc_phys_rd_i : '0;
  assign issue_dispatch_uop_o.rs1_used = !decode_trap_i && decode_rs1_used_i;
  assign issue_dispatch_uop_o.rs2_used = !decode_trap_i && decode_rs2_used_i;
  assign issue_dispatch_uop_o.rd_write = destination_required;
  assign issue_dispatch_uop_o.alu_op = decode_alu_op_i;
  // Trap uops remain MD_NONE because they complete through the ordinary
  // integer path.
  assign issue_dispatch_uop_o.muldiv_op = decode_trap_i ? rv32_pkg::MD_NONE : decode_muldiv_op_i;
  assign issue_dispatch_uop_o.mem_op = decode_trap_i ? rv32_pkg::MEM_NONE : decode_mem_op_i;
  assign issue_dispatch_uop_o.mem_size = decode_trap_i ? rv32_pkg::MEM_BYTE : decode_mem_size_i;
  assign issue_dispatch_uop_o.load_unsigned = !decode_trap_i && decode_load_unsigned_i;
  assign issue_dispatch_uop_o.branch_op = decode_branch_op_i;
  assign issue_dispatch_uop_o.control_flow = decode_trap_i ? rv32_pkg::CF_NONE : decode_control_flow_i;
  assign issue_dispatch_uop_o.operand_a_sel = decode_operand_a_sel_i;
  assign issue_dispatch_uop_o.operand_b_sel = decode_operand_b_sel_i;
  // Trap and control-flow routing takes priority over RV32M classification.
  assign mul_operation = decode_muldiv_op_i == rv32_pkg::MD_MUL || decode_muldiv_op_i == rv32_pkg::MD_MULH || decode_muldiv_op_i == rv32_pkg::MD_MULHSU || decode_muldiv_op_i == rv32_pkg::MD_MULHU;
  assign div_operation = decode_muldiv_op_i == rv32_pkg::MD_DIV || decode_muldiv_op_i == rv32_pkg::MD_DIVU || decode_muldiv_op_i == rv32_pkg::MD_REM || decode_muldiv_op_i == rv32_pkg::MD_REMU;
  assign issue_dispatch_uop_o.fu_kind = decode_trap_i ? FU_ALU :
                                        decode_control_flow_i != rv32_pkg::CF_NONE ? FU_BRANCH :
                                        decode_mem_op_i != rv32_pkg::MEM_NONE ? FU_MEMORY :
                                        mul_operation ? FU_MUL :
                                        div_operation ? FU_DIV :
                                        FU_ALU;
  assign issue_dispatch_rs1_ready_o = decode_trap_i || !decode_rs1_used_i || prf_rs1_ready_i;
  assign issue_dispatch_rs2_ready_o = decode_trap_i || !decode_rs2_used_i || prf_rs2_ready_i;

  assign prf_alloc_valid_o = dispatch_fire_o && destination_required;
  assign prf_alloc_addr_o = destination_required ? free_alloc_phys_rd_i : '0;
  assign dispatch_fire_o = decode_valid_i && decode_ready_o;

endmodule
