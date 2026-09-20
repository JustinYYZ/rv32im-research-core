// SPDX-License-Identifier: Apache-2.0
//
// Out-of-order RV32IM core integration top. The current core connects Fetch,
// Decode, register renaming, dynamic integer scheduling, ordered retirement,
// control-flow recovery, and precise synchronous traps. OoO memory and RV32M
// execution are intentionally left for later integration stages.

`timescale 1ns/1ps

module rv32_ooo_core #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
    input  logic                            clk_i,
    input  logic                            rst_i,

    output logic                            imem_req_valid_o,
    input  logic                            imem_req_ready_i,
    output logic [31:0]                     imem_req_addr_o,
    input  logic                            imem_resp_valid_i,
    input  logic [31:0]                     imem_resp_data_i,
    input  logic                            imem_resp_error_i,

    output logic                            dmem_req_valid_o,
    input  logic                            dmem_req_ready_i,
    output logic [31:0]                     dmem_req_addr_o,
    output logic                            dmem_req_write_o,
    output logic [31:0]                     dmem_req_wdata_o,
    output logic [3:0]                      dmem_req_wstrb_o,
    input  logic                            dmem_resp_valid_i,
    input  logic [31:0]                     dmem_resp_rdata_i,
    input  logic                            dmem_resp_error_i,

    output logic                            commit_valid_o,
    output logic [31:0]                     commit_pc_o,
    output logic [31:0]                     commit_instr_o,
    output logic                            commit_rd_write_o,
    output logic [4:0]                      commit_rd_addr_o,
    output logic [31:0]                     commit_rd_wdata_o,
    output logic                            commit_mem_valid_o,
    output logic                            commit_mem_write_o,
    output logic [31:0]                     commit_mem_addr_o,
    output logic [3:0]                      commit_mem_rmask_o,
    output logic [3:0]                      commit_mem_wmask_o,
    output logic [31:0]                     commit_mem_rdata_o,
    output logic [31:0]                     commit_mem_wdata_o,
    output logic                            commit_trap_o,
    output rv32_core_pkg::trap_cause_e      commit_trap_cause_o,
    output logic                            halted_o
);

  logic                         fetch_valid;
  logic                         fetch_ready;
  rv32_ooo_pkg::fetch_entry_t   fetch_entry;
  logic                         redirect_valid;
  logic [31:0]                  redirect_pc;

  logic [4:0]                   decoder_rs1;
  logic [4:0]                   decoder_rs2;
  logic [4:0]                   decoder_rd;
  logic                         decoder_rs1_used;
  logic                         decoder_rs2_used;
  rv32_pkg::alu_op_e            decoder_alu_op;
  rv32_pkg::operand_a_sel_e     decoder_operand_a_sel;
  rv32_pkg::operand_b_sel_e     decoder_operand_b_sel;
  rv32_pkg::imm_kind_e          decoder_imm_kind;
  rv32_pkg::muldiv_op_e         decoder_muldiv_op;
  rv32_pkg::branch_op_e         decoder_branch_op;
  rv32_pkg::control_flow_e      decoder_control_flow;
  rv32_pkg::writeback_sel_e     decoder_writeback_sel;
  rv32_pkg::mem_op_e            decoder_mem_op;
  rv32_pkg::mem_size_e          decoder_mem_size;
  logic                         decoder_load_unsigned;
  logic                         decoder_reg_write;
  logic                         decoder_illegal;
  rv32_pkg::system_op_e         decoder_system_op;
  logic [31:0]                  decoder_imm;
  logic                         decoder_trap;
  rv32_core_pkg::trap_cause_e   decoder_trap_cause;

  logic integer_supported;

  logic backend_decode_valid;
  logic backend_decode_ready;

  logic halted_q;
  logic frontend_redirect_valid;

  rv32_ooo_frontend #(
    .RESET_PC(RESET_PC)
  ) frontend (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .halt_i(halted_q),
    .redirect_valid_i(frontend_redirect_valid),
    .redirect_pc_i(redirect_pc),
    .icache_req_valid_o(imem_req_valid_o),
    .icache_req_ready_i(imem_req_ready_i),
    .icache_req_addr_o(imem_req_addr_o),
    .icache_resp_valid_i(imem_resp_valid_i),
    .icache_resp_data_i(imem_resp_data_i),
    .icache_resp_error_i(imem_resp_error_i),
    .fetch_valid_o(fetch_valid),
    .fetch_ready_i(fetch_ready),
    .fetch_entry_o(fetch_entry)
  );

  rv32_decoder decoder (
    .instr_i(fetch_entry.instr),
    .rs1_addr_o(decoder_rs1),
    .rs2_addr_o(decoder_rs2),
    .rd_addr_o(decoder_rd),
    .rs1_used_o(decoder_rs1_used),
    .rs2_used_o(decoder_rs2_used),
    .alu_op_o(decoder_alu_op),
    .operand_a_sel_o(decoder_operand_a_sel),
    .operand_b_sel_o(decoder_operand_b_sel),
    .imm_kind_o(decoder_imm_kind),
    .muldiv_op_o(decoder_muldiv_op),
    .branch_op_o(decoder_branch_op),
    .control_flow_o(decoder_control_flow),
    .writeback_sel_o(decoder_writeback_sel),
    .mem_op_o(decoder_mem_op),
    .mem_size_o(decoder_mem_size),
    .load_unsigned_o(decoder_load_unsigned),
    .reg_write_o(decoder_reg_write),
    .illegal_o(decoder_illegal),
    .system_op_o(decoder_system_op)
  );

  rv32_imm_gen imm_gen (
    .instr_i(fetch_entry.instr),
    .kind_i(decoder_imm_kind),
    .imm_o(decoder_imm)
  );

  always_comb begin
    decoder_trap = 1'b0;
    decoder_trap_cause = rv32_core_pkg::CORE_TRAP_NONE;

    if (fetch_entry.access_fault) begin
      decoder_trap = 1'b1;
      decoder_trap_cause = rv32_core_pkg::CORE_TRAP_INSTRUCTION_ACCESS_FAULT;
    end else if (decoder_illegal) begin
      decoder_trap = 1'b1;
      decoder_trap_cause = rv32_core_pkg::CORE_TRAP_ILLEGAL_INSTRUCTION;
    end else if (decoder_system_op == rv32_pkg::SYS_ECALL) begin
      decoder_trap = 1'b1;
      decoder_trap_cause = rv32_core_pkg::CORE_TRAP_ECALL;
    end else if (decoder_system_op == rv32_pkg::SYS_EBREAK) begin
      decoder_trap = 1'b1;
      decoder_trap_cause = rv32_core_pkg::CORE_TRAP_BREAKPOINT;
    end
  end

  rv32_ooo_backend backend (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .recover_i(1'b0),
    .decode_valid_i(backend_decode_valid),
    .decode_ready_o(backend_decode_ready),
    .decode_entry_i(fetch_entry),
    .decode_rs1_i(decoder_rs1),
    .decode_rs2_i(decoder_rs2),
    .decode_rd_i(decoder_rd),
    .decode_rs1_used_i(decoder_rs1_used),
    .decode_rs2_used_i(decoder_rs2_used),
    .decode_reg_write_i(decoder_reg_write),
    .decode_trap_i(decoder_trap),
    .decode_trap_cause_i(decoder_trap_cause),
    .decode_imm_i(decoder_imm),
    .decode_alu_op_i(decoder_alu_op),
    .decode_muldiv_op_i(decoder_muldiv_op),
    .decode_branch_op_i(decoder_branch_op),
    .decode_control_flow_i(decoder_control_flow),
    .decode_operand_a_sel_i(decoder_operand_a_sel),
    .decode_operand_b_sel_i(decoder_operand_b_sel),

    .commit_valid_o(commit_valid_o),
    .commit_ready_i(1'b1),
    .commit_pc_o(commit_pc_o),
    .commit_instr_o(commit_instr_o),
    .commit_rd_o(commit_rd_addr_o),
    .commit_reg_write_o(commit_rd_write_o),
    .commit_result_o(commit_rd_wdata_o),
    .commit_trap_o(commit_trap_o),
    .commit_trap_cause_o(commit_trap_cause_o),

    .redirect_valid_o(redirect_valid),
    .redirect_pc_o(redirect_pc)
  );

  // The data-memory interface remains inactive until the ordered O6 memory path
  // is integrated. Unsupported memory and RV32M operations are not consumed.
  assign dmem_req_valid_o = 1'b0;
  assign dmem_req_addr_o = 32'b0;
  assign dmem_req_write_o = 1'b0;
  assign dmem_req_wdata_o = 32'b0;
  assign dmem_req_wstrb_o = 4'b0;

  assign commit_mem_valid_o = 1'b0;
  assign commit_mem_write_o = 1'b0;
  assign commit_mem_addr_o = 32'b0;
  assign commit_mem_rmask_o = 4'b0;
  assign commit_mem_wmask_o = 4'b0;
  assign commit_mem_rdata_o = 32'b0;
  assign commit_mem_wdata_o = 32'b0;
  assign halted_o = halted_q;

  assign backend_decode_valid = !halted_q && fetch_valid && (integer_supported || decoder_trap);
  assign fetch_ready = !halted_q && backend_decode_ready && (integer_supported || decoder_trap);

  assign frontend_redirect_valid = redirect_valid || commit_trap_o;

  // Keep RV32M blocked until O5E connects real execution and completion paths.
  // O5A only transports and classifies its control metadata.
  assign integer_supported = !fetch_entry.access_fault &&
                             !decoder_illegal &&
                             decoder_mem_op == rv32_pkg::MEM_NONE &&
                             decoder_muldiv_op == rv32_pkg::MD_NONE &&
                             (decoder_system_op == rv32_pkg::SYS_NONE ||
                              decoder_system_op == rv32_pkg::SYS_FENCE);

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      halted_q <= 1'b0;
    end else if (commit_trap_o) begin
      halted_q <= 1'b1;
    end
  end

endmodule
