// SPDX-License-Identifier: Apache-2.0
//
// Multi-cycle in-order RV32IM architectural reference core.
//
// The core processes one instruction at a time. It allows one
// outstanding instruction request or data request, commits instructions in
// program order, and exposes architectural commit information for checking
// later pipeline and out-of-order implementations.

`timescale 1ns/1ps

module rv32_reference_core #(
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

  typedef enum logic [3:0] {
    CORE_STATE_RESET,
    CORE_STATE_FETCH_REQUEST,
    CORE_STATE_FETCH_WAIT,
    CORE_STATE_EXECUTE,
    CORE_STATE_DATA_REQUEST,
    CORE_STATE_DATA_WAIT,
    CORE_STATE_MULDIV_REQUEST,
    CORE_STATE_MULDIV_WAIT,
    CORE_STATE_COMMIT,
    CORE_STATE_TRAP,
    CORE_STATE_HALT
  } core_state_e;

  core_state_e state_q;
  logic [31:0] pc_q;
  logic [31:0] instr_q;

  logic [4:0]                  rs1_addr;
  logic [4:0]                  rs2_addr;
  logic [4:0]                  rd_addr;
  logic                        rs1_used;
  logic                        rs2_used;

  rv32_pkg::alu_op_e           alu_op;
  rv32_pkg::operand_a_sel_e    operand_a_sel;
  rv32_pkg::operand_b_sel_e    operand_b_sel;
  rv32_pkg::imm_kind_e         imm_kind;
  rv32_pkg::muldiv_op_e        muldiv_op;

  rv32_pkg::branch_op_e        branch_op;
  rv32_pkg::control_flow_e     control_flow;
  rv32_pkg::writeback_sel_e    writeback_sel;

  rv32_pkg::mem_op_e           mem_op;
  rv32_pkg::mem_size_e         mem_size;
  logic                        load_unsigned;

  logic                        reg_write;
  logic                        illegal;
  rv32_pkg::system_op_e        system_op;

  logic [31:0] imm;
  logic [31:0] rs1_data;
  logic [31:0] rs2_data;
  logic [31:0] alu_lhs;
  logic [31:0] alu_rhs;
  logic [31:0] alu_result;
  logic branch_taken;

  logic multiplier_req_valid;
  logic multiplier_req_ready;
  logic multiplier_resp_valid;
  logic [31:0] multiplier_result;

  logic divider_req_valid;
  logic divider_req_ready;
  logic divider_resp_valid;
  logic [31:0] divider_result;

  logic pending_rd_write_q;
  logic [4:0] pending_rd_addr_q;
  logic [31:0] pending_rd_wdata_q;
  logic [31:0] pending_next_pc_q;

  logic regfile_we;
  logic [4:0] regfile_waddr;
  logic [31:0] regfile_wdata;

  logic [31:0] lsu_aligned_addr;
  logic [31:0] lsu_store_word;
  logic [3:0]  lsu_store_mask;
  logic [31:0] lsu_load_value;
  logic lsu_misaligned;

  rv32_pkg::mem_op_e lsu_mem_op;
  rv32_pkg::mem_size_e lsu_mem_size;
  logic lsu_load_unsigned;
  logic [31:0] lsu_addr;
  logic [31:0] lsu_store_value;

  rv32_pkg::mem_op_e pending_mem_op_q;
  rv32_pkg::mem_size_e pending_mem_size_q;
  logic pending_load_unsigned_q;
  logic [31:0] pending_effective_addr_q;
  logic [31:0] pending_store_value_q;

  logic [31:0] pending_mem_addr_q;
  logic [3:0] pending_mem_rmask_q;
  logic [3:0] pending_mem_wmask_q;
  logic [31:0] pending_mem_rdata_q;
  logic [31:0] pending_mem_wdata_q;

  rv32_core_pkg::trap_cause_e pending_trap_cause_q;
  logic [31:0] pending_trap_pc_q;
  logic [31:0] pending_trap_instr_q;


  // Decode and execute inputs remain combinational while instr_q and pc_q hold
  // the current instruction. Values needed by later states are copied into the
  // pending registers before the state machine leaves EXECUTE.

  rv32_decoder decoder (
    .instr_i(instr_q),
    .rs1_addr_o(rs1_addr),
    .rs2_addr_o(rs2_addr),
    .rd_addr_o(rd_addr),
    .rs1_used_o(rs1_used),
    .rs2_used_o(rs2_used),
    .alu_op_o(alu_op),
    .operand_a_sel_o(operand_a_sel),
    .operand_b_sel_o(operand_b_sel),
    .imm_kind_o(imm_kind),
    .muldiv_op_o(muldiv_op),
    .branch_op_o(branch_op),
    .control_flow_o(control_flow),
    .writeback_sel_o(writeback_sel),
    .mem_op_o(mem_op),
    .mem_size_o(mem_size),
    .load_unsigned_o(load_unsigned),
    .reg_write_o(reg_write),
    .illegal_o(illegal),
    .system_op_o(system_op)
  );

  rv32_imm_gen imm_gen (
    .instr_i(instr_q),
    .kind_i(imm_kind),
    .imm_o(imm)
  );

  rv32_regfile regfile (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .raddr1_i(rs1_addr),
    .rdata1_o(rs1_data),
    .raddr2_i(rs2_addr),
    .rdata2_o(rs2_data),
    .we_i(regfile_we),
    .waddr_i(regfile_waddr),
    .wdata_i(regfile_wdata)
  );

  always_comb begin
    alu_lhs = 32'd0;
    case (operand_a_sel)
      rv32_pkg::OP_A_RS1: alu_lhs = rs1_data;
      rv32_pkg::OP_A_PC:  alu_lhs = pc_q;
      rv32_pkg::OP_A_ZERO:alu_lhs = 32'd0;
      default: alu_lhs = 32'd0;
    endcase
    alu_rhs = 32'd0;
    case (operand_b_sel)
      rv32_pkg::OP_B_RS2: alu_rhs = rs2_data;
      rv32_pkg::OP_B_IMM: alu_rhs = imm;
      default: alu_rhs = 32'd0;
    endcase
  end

  rv32_alu alu (
    .op_i(alu_op),
    .lhs_i(alu_lhs),
    .rhs_i(alu_rhs),
    .result_o(alu_result)
  );

  rv32_branch_unit branch_unit (
    .op_i(branch_op),
    .lhs_i(rs1_data),
    .rhs_i(rs2_data),
    .taken_o(branch_taken)
  );

  always_comb begin
    lsu_mem_op = mem_op;
    lsu_mem_size = mem_size;
    lsu_load_unsigned = load_unsigned;
    lsu_addr = alu_result;
    lsu_store_value = rs2_data;
    if (state_q == CORE_STATE_DATA_REQUEST || state_q == CORE_STATE_DATA_WAIT) begin
      lsu_mem_op = pending_mem_op_q;
      lsu_mem_size = pending_mem_size_q;
      lsu_load_unsigned = pending_load_unsigned_q;
      lsu_addr = pending_effective_addr_q;
      lsu_store_value = pending_store_value_q;
    end
  end

  rv32_lsu lsu (
    .mem_op_i(lsu_mem_op),
    .mem_size_i(lsu_mem_size),
    .load_unsigned_i(lsu_load_unsigned),
    .addr_i(lsu_addr),
    .store_value_i(lsu_store_value),
    .load_word_i(dmem_resp_rdata_i),
    .aligned_addr_o(lsu_aligned_addr),
    .store_word_o(lsu_store_word),
    .store_mask_o(lsu_store_mask),
    .load_value_o(lsu_load_value),
    .misaligned_o(lsu_misaligned)
  );

  rv32_multiplier multiplier (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .req_valid_i(multiplier_req_valid),
    .req_ready_o(multiplier_req_ready),
    .op_i(muldiv_op),
    .lhs_i(rs1_data),
    .rhs_i(rs2_data),
    .resp_valid_o(multiplier_resp_valid),
    .result_o(multiplier_result)
  );

  rv32_divider divider (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .req_valid_i(divider_req_valid),
    .req_ready_o(divider_req_ready),
    .op_i(muldiv_op),
    .lhs_i(rs1_data),
    .rhs_i(rs2_data),
    .resp_valid_o(divider_resp_valid),
    .result_o(divider_result)
  );
  // Request outputs are asserted only in their REQUEST states and therefore
  // remain stable until the corresponding ready handshake. Commit outputs are
  // valid for one COMMIT or TRAP cycle and are inactive in HALT.
  assign imem_req_valid_o = (state_q == CORE_STATE_FETCH_REQUEST);
  assign imem_req_addr_o = pc_q;
  assign dmem_req_valid_o = (state_q == CORE_STATE_DATA_REQUEST);
  assign dmem_req_addr_o = (dmem_req_valid_o) ? lsu_aligned_addr : 32'd0;
  assign dmem_req_write_o = (dmem_req_valid_o && pending_mem_op_q == rv32_pkg::MEM_STORE);
  assign dmem_req_wdata_o = (dmem_req_write_o) ? lsu_store_word : 32'd0;
  assign dmem_req_wstrb_o = (dmem_req_write_o) ? lsu_store_mask : 4'b0000;

  assign commit_valid_o = (state_q == CORE_STATE_COMMIT) || (state_q == CORE_STATE_TRAP);
  assign commit_pc_o = (state_q == CORE_STATE_TRAP) ? pending_trap_pc_q : pc_q;
  assign commit_instr_o = (state_q == CORE_STATE_TRAP) ? pending_trap_instr_q : instr_q;
  assign commit_rd_write_o = (state_q == CORE_STATE_COMMIT) && pending_rd_write_q;
  assign commit_rd_addr_o = pending_rd_addr_q;
  assign commit_rd_wdata_o = pending_rd_wdata_q;
  assign commit_mem_valid_o = (state_q == CORE_STATE_COMMIT) && (pending_mem_op_q != rv32_pkg::MEM_NONE);
  assign commit_mem_write_o = (commit_mem_valid_o && pending_mem_op_q == rv32_pkg::MEM_STORE);
  assign commit_mem_addr_o = (commit_mem_valid_o) ? pending_mem_addr_q : 32'd0;
  assign commit_mem_rmask_o = (commit_mem_valid_o) ? pending_mem_rmask_q : 4'b0000;
  assign commit_mem_wmask_o = (commit_mem_valid_o) ? pending_mem_wmask_q : 4'b0000;
  assign commit_mem_rdata_o = (commit_mem_valid_o) ? pending_mem_rdata_q : 32'd0;
  assign commit_mem_wdata_o = (commit_mem_valid_o) ? pending_mem_wdata_q : 32'd0;
  assign commit_trap_o = (state_q == CORE_STATE_TRAP);
  assign commit_trap_cause_o = rv32_core_pkg::trap_cause_e'((state_q == CORE_STATE_TRAP) ? pending_trap_cause_q : (rv32_core_pkg::CORE_TRAP_NONE));
  assign halted_o = (state_q == CORE_STATE_HALT);

  assign regfile_we = (state_q == CORE_STATE_COMMIT) && pending_rd_write_q;
  assign regfile_waddr = pending_rd_addr_q;
  assign regfile_wdata = pending_rd_wdata_q;

  assign multiplier_req_valid = (state_q == CORE_STATE_MULDIV_REQUEST) && ((muldiv_op == rv32_pkg::MD_MUL) || (muldiv_op == rv32_pkg::MD_MULH) || (muldiv_op == rv32_pkg::MD_MULHSU) || (muldiv_op == rv32_pkg::MD_MULHU));
  assign divider_req_valid = (state_q == CORE_STATE_MULDIV_REQUEST) && ((muldiv_op == rv32_pkg::MD_DIV) || (muldiv_op == rv32_pkg::MD_DIVU) || (muldiv_op == rv32_pkg::MD_REM) || (muldiv_op == rv32_pkg::MD_REMU));

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= CORE_STATE_RESET;
      pc_q <= RESET_PC;
      instr_q <= 32'd0;
      pending_rd_write_q <= 1'b0;
      pending_rd_addr_q <= 5'd0;
      pending_rd_wdata_q <= 32'd0;
      pending_next_pc_q <= RESET_PC;
      pending_mem_op_q <= rv32_pkg::MEM_NONE;
      pending_mem_size_q <= rv32_pkg::MEM_BYTE;
      pending_load_unsigned_q <= 1'b0;
      pending_effective_addr_q <= 32'd0;
      pending_store_value_q <= 32'd0;
      pending_mem_addr_q <= 32'd0;
      pending_mem_rmask_q <= 4'b0000;
      pending_mem_wmask_q <= 4'b0000;
      pending_mem_rdata_q <= 32'd0;
      pending_mem_wdata_q <= 32'd0;
      pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_NONE;
      pending_trap_pc_q <= RESET_PC;
      pending_trap_instr_q <= 32'd0;
    end else begin
      case (state_q)
        CORE_STATE_RESET: begin
          if (pc_q[1:0] != 2'b00) begin
            pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED;
            pending_trap_pc_q <= pc_q;
            pending_trap_instr_q <= 32'd0;
            pending_rd_write_q <= 1'b0;
            pending_rd_addr_q <= 5'd0;
            pending_rd_wdata_q <= 32'd0;
            pending_mem_op_q <= rv32_pkg::MEM_NONE;
            pending_mem_rmask_q <= 4'b0000;
            pending_mem_wmask_q <= 4'b0000;
            pending_mem_wdata_q <= 32'd0;
            state_q <= CORE_STATE_TRAP;
          end else begin
            state_q <= CORE_STATE_FETCH_REQUEST;
          end
        end
        CORE_STATE_FETCH_REQUEST: begin
          if (imem_req_valid_o && imem_req_ready_i) begin
            state_q <= CORE_STATE_FETCH_WAIT;
          end else begin
            state_q <= CORE_STATE_FETCH_REQUEST;
          end
        end
        CORE_STATE_FETCH_WAIT: begin
          if (imem_resp_valid_i) begin
            if (imem_resp_error_i) begin
              pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_INSTRUCTION_ACCESS_FAULT;
              pending_trap_pc_q <= pc_q;
              pending_trap_instr_q <= 32'd0;
              pending_rd_write_q <= 1'b0;
              pending_rd_addr_q <= 5'd0;
              pending_rd_wdata_q <= 32'd0;
              pending_mem_op_q <= rv32_pkg::MEM_NONE;
              pending_mem_rmask_q <= 4'b0000;
              pending_mem_wmask_q <= 4'b0000;
              pending_mem_wdata_q <= 32'd0;
              state_q <= CORE_STATE_TRAP;
            end else begin
              instr_q <= imem_resp_data_i;
              state_q <= CORE_STATE_EXECUTE;
            end
          end
        end
        CORE_STATE_EXECUTE: begin
          if (illegal) begin
            pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_ILLEGAL_INSTRUCTION;
            pending_trap_pc_q <= pc_q;
            pending_trap_instr_q <= instr_q;
            pending_rd_write_q <= 1'b0;
            pending_rd_addr_q <= 5'd0;
            pending_rd_wdata_q <= 32'd0;
            pending_mem_op_q <= rv32_pkg::MEM_NONE;
            pending_mem_rmask_q <= 4'b0000;
            pending_mem_wmask_q <= 4'b0000;
            pending_mem_wdata_q <= 32'd0;
            state_q <= CORE_STATE_TRAP;
          end else if (system_op == rv32_pkg::SYS_ECALL) begin
            pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_ECALL;
            pending_trap_pc_q <= pc_q;
            pending_trap_instr_q <= instr_q;
            pending_rd_write_q <= 1'b0;
            pending_rd_addr_q <= 5'd0;
            pending_rd_wdata_q <= 32'd0;
            pending_mem_op_q <= rv32_pkg::MEM_NONE;
            pending_mem_rmask_q <= 4'b0000;
            pending_mem_wmask_q <= 4'b0000;
            pending_mem_wdata_q <= 32'd0;
            state_q <= CORE_STATE_TRAP;
          end else if (system_op == rv32_pkg::SYS_EBREAK) begin
            pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_BREAKPOINT;
            pending_trap_pc_q <= pc_q;
            pending_trap_instr_q <= instr_q;
            pending_rd_write_q <= 1'b0;
            pending_rd_addr_q <= 5'd0;
            pending_rd_wdata_q <= 32'd0;
            pending_mem_op_q <= rv32_pkg::MEM_NONE;
            pending_mem_rmask_q <= 4'b0000;
            pending_mem_wmask_q <= 4'b0000;
            pending_mem_wdata_q <= 32'd0;
            state_q <= CORE_STATE_TRAP;
          end else if (system_op == rv32_pkg::SYS_FENCE) begin
            pending_rd_write_q <= 1'b0;
            pending_rd_addr_q <= 5'd0;
            pending_rd_wdata_q <= 32'd0;
            pending_mem_op_q <= rv32_pkg::MEM_NONE;
            pending_mem_rmask_q <= 4'b0000;
            pending_mem_wmask_q <= 4'b0000;
            pending_mem_wdata_q <= 32'd0;
            pending_next_pc_q <= pc_q + 32'd4;
            state_q <= CORE_STATE_COMMIT;
          end else if (!illegal &&
              control_flow == rv32_pkg::CF_NONE &&
              mem_op == rv32_pkg::MEM_NONE &&
              muldiv_op == rv32_pkg::MD_NONE &&
              system_op == rv32_pkg::SYS_NONE &&
              writeback_sel == rv32_pkg::WB_ALU &&
              reg_write) begin
            pending_rd_write_q <= reg_write && rd_addr != 5'd0;
            pending_rd_addr_q <= rd_addr;
            pending_rd_wdata_q <= alu_result;
            pending_next_pc_q <= pc_q + 32'd4;
            state_q <= CORE_STATE_COMMIT;
          end else if (!illegal &&
                       control_flow == rv32_pkg::CF_BRANCH &&
                       mem_op == rv32_pkg::MEM_NONE &&
                       system_op == rv32_pkg::SYS_NONE) begin
            if (!branch_taken || alu_result[1:0] == 2'b00) begin
              pending_rd_write_q <= 1'b0;
              pending_rd_addr_q <= 5'd0;
              pending_rd_wdata_q <= 32'd0;
              pending_next_pc_q <= branch_taken ? alu_result : (pc_q + 32'd4);
              state_q <= CORE_STATE_COMMIT;
            end else begin
              pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED;
              pending_trap_pc_q <= pc_q;
              pending_trap_instr_q <= instr_q;
              pending_rd_write_q <= 1'b0;
              pending_rd_addr_q <= 5'd0;
              pending_rd_wdata_q <= 32'd0;
              pending_mem_op_q <= rv32_pkg::MEM_NONE;
              pending_mem_rmask_q <= 4'b0000;
              pending_mem_wmask_q <= 4'b0000;
              pending_mem_wdata_q <= 32'd0;
              state_q <= CORE_STATE_TRAP;
            end
          end else if (!illegal &&
                       control_flow == rv32_pkg::CF_JAL) begin
            if (alu_result[1:0] == 2'b00) begin
              pending_rd_write_q <= reg_write && rd_addr != 5'd0;
              pending_rd_addr_q <= rd_addr;
              pending_rd_wdata_q <= pc_q + 32'd4;
              pending_next_pc_q <= alu_result;
              state_q <= CORE_STATE_COMMIT;
            end else begin
              pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED;
              pending_trap_pc_q <= pc_q;
              pending_trap_instr_q <= instr_q;
              pending_rd_write_q <= 1'b0;
              pending_rd_addr_q <= 5'd0;
              pending_rd_wdata_q <= 32'd0;
              pending_mem_op_q <= rv32_pkg::MEM_NONE;
              pending_mem_rmask_q <= 4'b0000;
              pending_mem_wmask_q <= 4'b0000;
              pending_mem_wdata_q <= 32'd0;
              state_q <= CORE_STATE_TRAP;
            end
          end else if (!illegal &&
                       control_flow == rv32_pkg::CF_JALR) begin
            if (alu_result[1] == 1'b0) begin
              pending_rd_write_q <= reg_write && rd_addr != 5'd0;
              pending_rd_addr_q <= rd_addr;
              pending_rd_wdata_q <= pc_q + 32'd4;
              pending_next_pc_q <= alu_result & ~32'd1; // Clear bit zero
              state_q <= CORE_STATE_COMMIT;
            end else begin
              pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED;
              pending_trap_pc_q <= pc_q;
              pending_trap_instr_q <= instr_q;
              pending_rd_write_q <= 1'b0;
              pending_rd_addr_q <= 5'd0;
              pending_rd_wdata_q <= 32'd0;
              pending_mem_op_q <= rv32_pkg::MEM_NONE;
              pending_mem_rmask_q <= 4'b0000;
              pending_mem_wmask_q <= 4'b0000;
              pending_mem_wdata_q <= 32'd0;
              state_q <= CORE_STATE_TRAP;
            end
          end else if (!illegal &&
                       control_flow == rv32_pkg::CF_NONE &&
                       mem_op != rv32_pkg::MEM_NONE &&
                       system_op == rv32_pkg::SYS_NONE) begin
            if (!lsu_misaligned) begin
              pending_mem_op_q <= mem_op;
              pending_mem_size_q <= mem_size;
              pending_load_unsigned_q <= load_unsigned;
              pending_effective_addr_q <= alu_result;
              pending_store_value_q <= rs2_data;
              pending_next_pc_q <= pc_q + 32'd4;
              pending_mem_addr_q <= lsu_aligned_addr;
              pending_mem_rdata_q <= 32'd0;
              if (mem_op == rv32_pkg::MEM_LOAD) begin
                pending_rd_write_q <= reg_write && rd_addr != 5'd0;
                pending_rd_addr_q <= rd_addr;
                pending_rd_wdata_q <= 32'd0;
                pending_mem_wmask_q <= 4'b0000;
                pending_mem_wdata_q <= 32'd0;
                if (mem_size == rv32_pkg::MEM_BYTE) begin
                  pending_mem_rmask_q <= 4'b0001 << alu_result[1:0];
                end else if (mem_size == rv32_pkg::MEM_HALF) begin
                  if (alu_result[1] == 1'b0) begin
                    pending_mem_rmask_q <= 4'b0011;
                  end else begin
                    pending_mem_rmask_q <= 4'b1100;
                  end
                end else begin
                  pending_mem_rmask_q <= 4'b1111;
                end
              end else begin
                pending_rd_write_q <= 1'b0;
                pending_rd_addr_q <= 5'd0;
                pending_rd_wdata_q <= 32'd0;
                pending_mem_rmask_q <= 4'b0000;
                pending_mem_wmask_q <= lsu_store_mask;
                pending_mem_wdata_q <= lsu_store_word;
              end
              state_q <= CORE_STATE_DATA_REQUEST;
            end else begin
              if (mem_op == rv32_pkg::MEM_LOAD) begin
                pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_LOAD_ADDRESS_MISALIGNED;
              end else begin
                pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_STORE_ADDRESS_MISALIGNED;
              end
              pending_trap_pc_q <= pc_q;
              pending_trap_instr_q <= instr_q;
              pending_rd_write_q <= 1'b0;
              pending_rd_addr_q <= 5'd0;
              pending_rd_wdata_q <= 32'd0;
              pending_mem_op_q <= rv32_pkg::MEM_NONE;
              pending_mem_rmask_q <= 4'b0000;
              pending_mem_wmask_q <= 4'b0000;
              pending_mem_wdata_q <= 32'd0;
              state_q <= CORE_STATE_TRAP;
            end
          end else if (!illegal &&
                       control_flow == rv32_pkg::CF_NONE &&
                       mem_op == rv32_pkg::MEM_NONE &&
                       muldiv_op != rv32_pkg::MD_NONE &&
                       system_op == rv32_pkg::SYS_NONE &&
                       reg_write) begin
            pending_rd_write_q <= reg_write && rd_addr != 5'd0;
            pending_rd_addr_q <= rd_addr;
            pending_rd_wdata_q <= 32'd0;
            pending_next_pc_q <= pc_q + 32'd4;
            state_q <= CORE_STATE_MULDIV_REQUEST;
          end else begin
            pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_ILLEGAL_INSTRUCTION;
            pending_trap_pc_q <= pc_q;
            pending_trap_instr_q <= instr_q;
            pending_rd_write_q <= 1'b0;
            pending_rd_addr_q <= 5'd0;
            pending_rd_wdata_q <= 32'd0;
            pending_mem_op_q <= rv32_pkg::MEM_NONE;
            pending_mem_rmask_q <= 4'b0000;
            pending_mem_wmask_q <= 4'b0000;
            pending_mem_wdata_q <= 32'd0;
            state_q <= CORE_STATE_TRAP;
          end
        end
        CORE_STATE_DATA_REQUEST: begin
          if (dmem_req_valid_o && dmem_req_ready_i) begin
            state_q <= CORE_STATE_DATA_WAIT;
          end
        end
        CORE_STATE_DATA_WAIT: begin
          if (dmem_resp_valid_i) begin
            if (dmem_resp_error_i) begin
              if (pending_mem_op_q == rv32_pkg::MEM_LOAD) begin
                pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_LOAD_ACCESS_FAULT;
              end else begin
                pending_trap_cause_q <= rv32_core_pkg::CORE_TRAP_STORE_ACCESS_FAULT;
              end
              pending_trap_pc_q <= pc_q;
              pending_trap_instr_q <= instr_q;
              pending_rd_write_q <= 1'b0;
              pending_rd_addr_q <= 5'd0;
              pending_rd_wdata_q <= 32'd0;
              pending_mem_op_q <= rv32_pkg::MEM_NONE;
              pending_mem_rmask_q <= 4'b0000;
              pending_mem_wmask_q <= 4'b0000;
              pending_mem_wdata_q <= 32'd0;
              state_q <= CORE_STATE_TRAP;
            end else begin
              if (pending_mem_op_q == rv32_pkg::MEM_LOAD) begin
                pending_mem_rdata_q <= dmem_resp_rdata_i;
                pending_rd_wdata_q <= lsu_load_value;
              end
              state_q <= CORE_STATE_COMMIT;
            end
          end
        end
        CORE_STATE_MULDIV_REQUEST: begin
          if ((multiplier_req_valid && multiplier_req_ready) || (divider_req_valid && divider_req_ready)) begin
            state_q <= CORE_STATE_MULDIV_WAIT;
          end
        end
        CORE_STATE_MULDIV_WAIT: begin
          if (multiplier_resp_valid) begin
            pending_rd_wdata_q <= multiplier_result;
            state_q <= CORE_STATE_COMMIT;
          end else if (divider_resp_valid) begin
            pending_rd_wdata_q <= divider_result;
            state_q <= CORE_STATE_COMMIT;
          end
        end
        CORE_STATE_COMMIT: begin
          pc_q <= pending_next_pc_q;
          pending_mem_op_q <= rv32_pkg::MEM_NONE;
          state_q <= CORE_STATE_FETCH_REQUEST;
        end
        CORE_STATE_TRAP: begin
          state_q <= CORE_STATE_HALT;
        end
        CORE_STATE_HALT: begin
          state_q <= CORE_STATE_HALT;
        end
        default: begin
          // A synchronous reset recovers an invalid state encoding.
        end
      endcase
    end
  end

endmodule
