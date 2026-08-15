// SPDX-License-Identifier: Apache-2.0
//
// Five-stage in-order RV32IM pipeline core.
//
// The core implements blocking instruction and data ports, RAW hazard control,
// operand forwarding, branch/jump recovery, multicycle RV32M execution, and
// precise synchronous traps reported through the architectural commit interface.

`timescale 1ns/1ps

module rv32_pipeline_core #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000,
    parameter logic ENABLE_FORWARDING = 1'b1
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

  logic [31:0] fetch_pc_q;
  logic fetch_pending_q;
  logic fetch_discard_q;
  rv32_pipeline_pkg::if_id_payload_t if_id_q;
  rv32_pipeline_pkg::id_ex_payload_t id_ex_q;
  rv32_pipeline_pkg::ex_mem_payload_t ex_mem_q;
  rv32_pipeline_pkg::mem_wb_payload_t mem_wb_q;

  rv32_pipeline_pkg::id_ex_payload_t id_ex_d;
  rv32_pipeline_pkg::ex_mem_payload_t ex_mem_d;
  rv32_pipeline_pkg::mem_wb_payload_t mem_wb_d;

  logic [4:0] id_rs1_addr;
  logic [4:0] id_rs2_addr;
  logic [4:0] id_rd_addr;
  logic       id_rs1_used;
  logic       id_rs2_used;

  rv32_pkg::alu_op_e id_alu_op;
  rv32_pkg::operand_a_sel_e id_operand_a_sel;
  rv32_pkg::operand_b_sel_e id_operand_b_sel;
  rv32_pkg::imm_kind_e id_imm_kind;
  rv32_pkg::muldiv_op_e id_muldiv_op;

  rv32_pkg::branch_op_e id_branch_op;
  rv32_pkg::control_flow_e id_control_flow;
  rv32_pkg::writeback_sel_e id_writeback_sel;
  rv32_pkg::mem_op_e id_mem_op;
  rv32_pkg::mem_size_e id_mem_size;
  rv32_pkg::system_op_e id_system_op;

  logic        id_load_unsigned;
  logic        id_reg_write;
  logic        id_illegal;
  logic [31:0] id_imm;

  logic [31:0] id_rs1_data;
  logic [31:0] id_rs2_data;
  logic [31:0] id_rs1_data_effective;
  logic [31:0] id_rs2_data_effective;

  logic id_trap;
  rv32_core_pkg::trap_cause_e id_trap_cause;

  logic [31:0] ex_alu_lhs;
  logic [31:0] ex_alu_rhs;
  logic [31:0] ex_alu_result;
  logic        ex_branch_taken;
  logic        ex_redirect_valid;
  logic [31:0] ex_redirect_target;

  logic [31:0] ex_rs1_data_forwarded;
  logic [31:0] ex_rs2_data_forwarded;

  logic ex_trap;
  rv32_core_pkg::trap_cause_e ex_trap_cause;

  logic [31:0] mem_aligned_addr;
  logic [31:0] mem_store_word;
  logic [3:0]  mem_store_mask;
  logic [31:0] mem_load_value;
  logic        mem_misaligned;

  logic        dmem_pending_q;
  logic        mem_active;
  logic        mem_complete;

  logic mem_trap;
  rv32_core_pkg::trap_cause_e mem_trap_cause;

  logic        multiplier_req_valid;
  logic        multiplier_req_ready;
  logic        multiplier_resp_valid;
  logic [31:0] multiplier_result;

  logic        divider_req_valid;
  logic        divider_req_ready;
  logic        divider_resp_valid;
  logic [31:0] divider_result;

  logic        muldiv_pending_q;
  logic        muldiv_active;
  logic        muldiv_is_multiply;
  logic        muldiv_is_divide;
  logic        muldiv_complete;
  logic [31:0] muldiv_result;

  logic id_stall;

  logic halted_q;
  logic trap_inflight;

  rv32_decoder decoder (
    .instr_i(if_id_q.instr),
    .rs1_addr_o(id_rs1_addr),
    .rs2_addr_o(id_rs2_addr),
    .rd_addr_o(id_rd_addr),
    .rs1_used_o(id_rs1_used),
    .rs2_used_o(id_rs2_used),
    .alu_op_o(id_alu_op),
    .operand_a_sel_o(id_operand_a_sel),
    .operand_b_sel_o(id_operand_b_sel),
    .imm_kind_o(id_imm_kind),
    .muldiv_op_o(id_muldiv_op),
    .branch_op_o(id_branch_op),
    .control_flow_o(id_control_flow),
    .writeback_sel_o(id_writeback_sel),
    .mem_op_o(id_mem_op),
    .mem_size_o(id_mem_size),
    .load_unsigned_o(id_load_unsigned),
    .reg_write_o(id_reg_write),
    .illegal_o(id_illegal),
    .system_op_o(id_system_op)
  );

  rv32_imm_gen imm_gen (
    .instr_i(if_id_q.instr),
    .kind_i(id_imm_kind),
    .imm_o(id_imm)
  );

  rv32_regfile regfile (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .raddr1_i(id_rs1_addr),
    .rdata1_o(id_rs1_data),
    .raddr2_i(id_rs2_addr),
    .rdata2_o(id_rs2_data),
    .we_i(mem_wb_q.valid && !mem_wb_q.trap && mem_wb_q.rd_write),
    .waddr_i(mem_wb_q.rd_addr),
    .wdata_i(mem_wb_q.rd_wdata)
  );

  always_comb begin
    id_rs1_data_effective = id_rs1_data;
    id_rs2_data_effective = id_rs2_data;
    if (if_id_q.valid &&
        id_rs1_used &&
        id_rs1_addr != 5'd0 &&
        mem_wb_q.valid &&
        mem_wb_q.rd_write &&
        mem_wb_q.rd_addr == id_rs1_addr) begin
      id_rs1_data_effective = mem_wb_q.rd_wdata;
    end
    if (if_id_q.valid &&
        id_rs2_used &&
        id_rs2_addr != 5'd0 &&
        mem_wb_q.valid &&
        mem_wb_q.rd_write &&
        mem_wb_q.rd_addr == id_rs2_addr) begin
      id_rs2_data_effective = mem_wb_q.rd_wdata;
    end
  end

  always_comb begin
    ex_alu_lhs = 32'd0;
    case (id_ex_q.operand_a_sel)
      rv32_pkg::OP_A_RS1: ex_alu_lhs = ex_rs1_data_forwarded;
      rv32_pkg::OP_A_PC:  ex_alu_lhs = id_ex_q.pc;
      rv32_pkg::OP_A_ZERO:ex_alu_lhs = 32'd0;
      default: ex_alu_lhs = 32'd0;
    endcase
    ex_alu_rhs = 32'd0;
    case (id_ex_q.operand_b_sel)
      rv32_pkg::OP_B_RS2: ex_alu_rhs = ex_rs2_data_forwarded;
      rv32_pkg::OP_B_IMM: ex_alu_rhs = id_ex_q.imm;
      default: ex_alu_rhs = 32'd0;
    endcase
  end

  rv32_alu alu (
    .op_i(id_ex_q.alu_op),
    .lhs_i(ex_alu_lhs),
    .rhs_i(ex_alu_rhs),
    .result_o(ex_alu_result)
  );

  rv32_branch_unit branch_unit (
    .op_i(id_ex_q.branch_op),
    .lhs_i(ex_rs1_data_forwarded),
    .rhs_i(ex_rs2_data_forwarded),
    .taken_o(ex_branch_taken)
  );

  rv32_lsu lsu (
    .mem_op_i(ex_mem_q.mem_op),
    .mem_size_i(ex_mem_q.mem_size),
    .load_unsigned_i(ex_mem_q.load_unsigned),
    .addr_i(ex_mem_q.effective_addr),
    .store_value_i(ex_mem_q.store_value),
    .load_word_i(dmem_resp_rdata_i),
    .aligned_addr_o(mem_aligned_addr),
    .store_word_o(mem_store_word),
    .store_mask_o(mem_store_mask),
    .load_value_o(mem_load_value),
    .misaligned_o(mem_misaligned)
  );

  always_comb begin
    muldiv_active = 1'b0;
    muldiv_is_multiply = 1'b0;
    muldiv_is_divide = 1'b0;

    if (id_ex_q.valid) begin
      case (id_ex_q.muldiv_op)
        rv32_pkg::MD_MUL,
        rv32_pkg::MD_MULH,
        rv32_pkg::MD_MULHSU,
        rv32_pkg::MD_MULHU: begin
          muldiv_active = 1'b1;
          muldiv_is_multiply = 1'b1;
        end
        rv32_pkg::MD_DIV,
        rv32_pkg::MD_DIVU,
        rv32_pkg::MD_REM,
        rv32_pkg::MD_REMU: begin
          muldiv_active = 1'b1;
          muldiv_is_divide = 1'b1;
        end
        default: begin
          muldiv_active = 1'b0;
          muldiv_is_multiply = 1'b0;
          muldiv_is_divide = 1'b0;
        end
      endcase
    end
  end

  always_comb begin
    multiplier_req_valid = !rst_i && muldiv_active && muldiv_is_multiply && !muldiv_pending_q && !mem_active;
    divider_req_valid = !rst_i && muldiv_active && muldiv_is_divide && !muldiv_pending_q && !mem_active;
    muldiv_complete = muldiv_pending_q && ((muldiv_is_multiply && multiplier_resp_valid) || (muldiv_is_divide && divider_resp_valid));
    muldiv_result = 32'd0;
    if (muldiv_is_multiply) begin
      muldiv_result = multiplier_result;
    end else if (muldiv_is_divide) begin
      muldiv_result = divider_result;
    end
  end

  rv32_multiplier multiplier (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .req_valid_i(multiplier_req_valid),
    .req_ready_o(multiplier_req_ready),
    .op_i(id_ex_q.muldiv_op),
    .lhs_i(ex_rs1_data_forwarded),
    .rhs_i(ex_rs2_data_forwarded),
    .resp_valid_o(multiplier_resp_valid),
    .result_o(multiplier_result)
  );

  rv32_divider divider (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .req_valid_i(divider_req_valid),
    .req_ready_o(divider_req_ready),
    .op_i(id_ex_q.muldiv_op),
    .lhs_i(ex_rs1_data_forwarded),
    .rhs_i(ex_rs2_data_forwarded),
    .resp_valid_o(divider_resp_valid),
    .result_o(divider_result)
  );

  always_comb begin
    id_ex_d = '0;
    if (if_id_q.valid &&
        (id_trap ||
         id_system_op == rv32_pkg::SYS_FENCE ||
         (!id_illegal &&
          id_system_op == rv32_pkg::SYS_NONE &&
          ((id_control_flow == rv32_pkg::CF_NONE &&
            ((id_mem_op == rv32_pkg::MEM_NONE &&
              id_writeback_sel == rv32_pkg::WB_ALU &&
              id_reg_write) ||
            id_mem_op == rv32_pkg::MEM_LOAD ||
            id_mem_op == rv32_pkg::MEM_STORE)) ||
          id_control_flow == rv32_pkg::CF_BRANCH ||
          id_control_flow == rv32_pkg::CF_JAL ||
          id_control_flow == rv32_pkg::CF_JALR)))) begin
      id_ex_d.valid = if_id_q.valid;
      id_ex_d.pc = if_id_q.pc;
      id_ex_d.instr = if_id_q.instr;
      id_ex_d.trap = id_trap;
      id_ex_d.trap_cause = id_trap_cause;
      if (!id_trap && id_system_op != rv32_pkg::SYS_FENCE) begin
        id_ex_d.rs1_addr = id_rs1_addr;
        id_ex_d.rs2_addr = id_rs2_addr;
        id_ex_d.rd_addr = id_rd_addr;
        id_ex_d.rs1_used = id_rs1_used;
        id_ex_d.rs2_used = id_rs2_used;
        id_ex_d.rs1_data = id_rs1_data_effective;
        id_ex_d.rs2_data = id_rs2_data_effective;
        id_ex_d.imm = id_imm;
        id_ex_d.alu_op = id_alu_op;
        id_ex_d.muldiv_op = id_muldiv_op;
        id_ex_d.operand_a_sel = id_operand_a_sel;
        id_ex_d.operand_b_sel = id_operand_b_sel;
        id_ex_d.reg_write = id_reg_write;
        id_ex_d.branch_op = id_branch_op;
        id_ex_d.control_flow = id_control_flow;
        id_ex_d.writeback_sel = id_writeback_sel;
        id_ex_d.mem_op = id_mem_op;
        id_ex_d.mem_size = id_mem_size;
        id_ex_d.load_unsigned = id_load_unsigned;
      end
    end
  end

  always_comb begin
    ex_redirect_valid = 1'b0;
    ex_redirect_target = 32'd0;
    if (id_ex_q.valid && (!muldiv_active || muldiv_complete) && !ex_trap) begin
      case (id_ex_q.control_flow)
        rv32_pkg::CF_BRANCH: begin
          ex_redirect_valid = ex_branch_taken;
          ex_redirect_target = ex_alu_result;
        end
        rv32_pkg::CF_JAL: begin
          ex_redirect_valid = 1'b1;
          ex_redirect_target = ex_alu_result;
        end
        rv32_pkg::CF_JALR: begin
          ex_redirect_valid = 1'b1;
          ex_redirect_target = ex_alu_result & ~32'd1;
        end
        default: begin
          ex_redirect_valid = 1'b0;
          ex_redirect_target = 32'd0;
        end
      endcase
    end
  end

  always_comb begin
    ex_mem_d = '0;
    if (id_ex_q.valid && (!muldiv_active || muldiv_complete)) begin
      ex_mem_d.valid = id_ex_q.valid;
      ex_mem_d.pc = id_ex_q.pc;
      ex_mem_d.instr = id_ex_q.instr;
      ex_mem_d.trap = id_ex_q.trap || ex_trap;
      if (id_ex_q.trap) begin
        ex_mem_d.trap_cause = id_ex_q.trap_cause;
      end else if (ex_trap) begin
        ex_mem_d.trap_cause = ex_trap_cause;
      end else begin
        ex_mem_d.trap_cause = rv32_core_pkg::CORE_TRAP_NONE;
      end
      if (!id_ex_q.trap && !ex_trap) begin
        ex_mem_d.mem_op = id_ex_q.mem_op;
        ex_mem_d.mem_size = id_ex_q.mem_size;
        ex_mem_d.load_unsigned = id_ex_q.load_unsigned;
        ex_mem_d.effective_addr = ex_alu_result;
        ex_mem_d.store_value = ex_rs2_data_forwarded;
        if (id_ex_q.reg_write && id_ex_q.rd_addr != 5'd0) begin
          ex_mem_d.rd_write = id_ex_q.reg_write && id_ex_q.rd_addr != 5'd0;
          ex_mem_d.rd_addr = id_ex_q.rd_addr;
          case (id_ex_q.writeback_sel)
            rv32_pkg::WB_ALU: begin
              if (muldiv_active) begin
                ex_mem_d.rd_wdata = muldiv_result;
              end else begin
                ex_mem_d.rd_wdata = ex_alu_result;
              end
            end
            rv32_pkg::WB_PC_PLUS_4: ex_mem_d.rd_wdata = id_ex_q.pc + 32'd4;
            default: ex_mem_d.rd_wdata = 32'd0;
          endcase
        end
      end
    end
  end

  always_comb begin
    mem_wb_d = '0;
    if (ex_mem_q.valid) begin
      if (mem_trap) begin
        mem_wb_d.valid = 1'b1;
        mem_wb_d.pc = ex_mem_q.pc;
        mem_wb_d.instr = ex_mem_q.instr;
      end else if (ex_mem_q.mem_op == rv32_pkg::MEM_NONE) begin
        mem_wb_d.valid = 1'b1;
        mem_wb_d.pc = ex_mem_q.pc;
        mem_wb_d.instr = ex_mem_q.instr;
        mem_wb_d.rd_write = ex_mem_q.rd_write;
        mem_wb_d.rd_addr = ex_mem_q.rd_addr;
        mem_wb_d.rd_wdata = ex_mem_q.rd_wdata;
      end else if (mem_complete && !dmem_resp_error_i) begin
        mem_wb_d.valid = 1'b1;
        mem_wb_d.pc = ex_mem_q.pc;
        mem_wb_d.instr = ex_mem_q.instr;
        mem_wb_d.mem_op = ex_mem_q.mem_op;
        mem_wb_d.mem_addr = mem_aligned_addr;

        if (ex_mem_q.mem_op == rv32_pkg::MEM_LOAD) begin
          mem_wb_d.rd_write = ex_mem_q.rd_write;
          mem_wb_d.rd_addr = ex_mem_q.rd_addr;
          mem_wb_d.rd_wdata = mem_load_value;
          mem_wb_d.mem_rdata = dmem_resp_rdata_i;

          case (ex_mem_q.mem_size)
            rv32_pkg::MEM_BYTE: mem_wb_d.mem_rmask = 4'b0001 << ex_mem_q.effective_addr[1:0];
            rv32_pkg::MEM_HALF: mem_wb_d.mem_rmask = ex_mem_q.effective_addr[1] ? 4'b1100 : 4'b0011;
            rv32_pkg::MEM_WORD: mem_wb_d.mem_rmask = 4'b1111;
            default: mem_wb_d.mem_rmask = 4'b0000;
          endcase
        end else begin
          mem_wb_d.rd_write = 1'b0;
          mem_wb_d.rd_addr = 5'd0;
          mem_wb_d.rd_wdata = 32'd0;
          mem_wb_d.mem_wmask = mem_store_mask;
          mem_wb_d.mem_wdata = mem_store_word;
        end
      end
    end
    mem_wb_d.trap = ex_mem_q.trap || mem_trap;
    if (ex_mem_q.trap) begin
      mem_wb_d.trap_cause = ex_mem_q.trap_cause;
    end else if (mem_trap) begin
      mem_wb_d.trap_cause = mem_trap_cause;
    end else begin
      mem_wb_d.trap_cause = rv32_core_pkg::CORE_TRAP_NONE;
    end
  end

  always_comb begin
    mem_active = ex_mem_q.valid && (ex_mem_q.mem_op != rv32_pkg::MEM_NONE);
    mem_complete = dmem_resp_valid_i && mem_active && dmem_pending_q;
  end

  rv32_hazard_unit hazard_unit (
    .consumer_valid_i(if_id_q.valid),
    .consumer_rs1_used_i(id_rs1_used),
    .consumer_rs2_used_i(id_rs2_used),
    .consumer_rs1_addr_i(id_rs1_addr),
    .consumer_rs2_addr_i(id_rs2_addr),
    .id_ex_valid_i(id_ex_q.valid),
    .id_ex_rd_write_i(id_ex_q.reg_write),
    .id_ex_rd_addr_i(id_ex_q.rd_addr),
    .ex_mem_valid_i(ex_mem_q.valid),
    .ex_mem_rd_write_i(ex_mem_q.rd_write),
    .ex_mem_rd_addr_i(ex_mem_q.rd_addr),
    .mem_wb_valid_i(mem_wb_q.valid),
    .mem_wb_rd_write_i(mem_wb_q.rd_write),
    .mem_wb_rd_addr_i(mem_wb_q.rd_addr),
    .id_ex_data_ready_i(ENABLE_FORWARDING),
    .ex_mem_data_ready_i(ENABLE_FORWARDING),
    .mem_wb_data_ready_i(ENABLE_FORWARDING),
    .stall_o(id_stall)
  );

  rv32_forwarding_unit forwarding_unit (
    .consumer_valid_i(id_ex_q.valid),
    .consumer_rs1_used_i(id_ex_q.rs1_used),
    .consumer_rs2_used_i(id_ex_q.rs2_used),
    .consumer_rs1_addr_i(id_ex_q.rs1_addr),
    .consumer_rs2_addr_i(id_ex_q.rs2_addr),
    .consumer_rs1_data_i(id_ex_q.rs1_data),
    .consumer_rs2_data_i(id_ex_q.rs2_data),
    .ex_mem_valid_i(ex_mem_q.valid),
    .ex_mem_rd_write_i(ex_mem_q.rd_write),
    .ex_mem_rd_addr_i(ex_mem_q.rd_addr),
    .ex_mem_rd_data_i(ex_mem_q.rd_wdata),
    .mem_wb_valid_i(mem_wb_q.valid),
    .mem_wb_rd_write_i(mem_wb_q.rd_write),
    .mem_wb_rd_addr_i(mem_wb_q.rd_addr),
    .mem_wb_rd_data_i(mem_wb_q.rd_wdata),
    .rs1_data_o(ex_rs1_data_forwarded),
    .rs2_data_o(ex_rs2_data_forwarded)
  );

  always_comb begin
    id_trap = 1'b0;
    id_trap_cause = rv32_core_pkg::CORE_TRAP_NONE;
    if (if_id_q.valid) begin
      if (if_id_q.trap) begin
        id_trap = 1'b1;
        id_trap_cause = if_id_q.trap_cause;
      end else if (id_illegal) begin
        id_trap = 1'b1;
        id_trap_cause = rv32_core_pkg::CORE_TRAP_ILLEGAL_INSTRUCTION;
      end else if (id_system_op == rv32_pkg::SYS_ECALL) begin
        id_trap = 1'b1;
        id_trap_cause = rv32_core_pkg::CORE_TRAP_ECALL;
      end else if (id_system_op == rv32_pkg::SYS_EBREAK) begin
        id_trap = 1'b1;
        id_trap_cause = rv32_core_pkg::CORE_TRAP_BREAKPOINT;
      end
    end
  end

  always_comb begin
    ex_trap = 1'b0;
    ex_trap_cause = rv32_core_pkg::CORE_TRAP_NONE;
    if (id_ex_q.valid && !id_ex_q.trap) begin
      case (id_ex_q.control_flow)
        rv32_pkg::CF_BRANCH: begin
          if (ex_branch_taken && ex_alu_result[1:0] != 2'b00) begin
            ex_trap = 1'b1;
            ex_trap_cause = rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED;
          end
        end
        rv32_pkg::CF_JAL: begin
          if (ex_alu_result[1:0] != 2'b00) begin
            ex_trap = 1'b1;
            ex_trap_cause = rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED;
          end
        end
        rv32_pkg::CF_JALR: begin
          if (ex_alu_result[1] != 1'b0) begin
            ex_trap = 1'b1;
            ex_trap_cause = rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED;
          end
        end
        default: begin
        end
      endcase
    end
  end

  always_comb begin
    mem_trap = 1'b0;
    mem_trap_cause = rv32_core_pkg::CORE_TRAP_NONE;
    if (mem_active && !ex_mem_q.trap) begin
      if (mem_misaligned) begin
        mem_trap = 1'b1;
        if (ex_mem_q.mem_op == rv32_pkg::MEM_LOAD) begin
          mem_trap_cause = rv32_core_pkg::CORE_TRAP_LOAD_ADDRESS_MISALIGNED;
        end else if (ex_mem_q.mem_op == rv32_pkg::MEM_STORE) begin
          mem_trap_cause = rv32_core_pkg::CORE_TRAP_STORE_ADDRESS_MISALIGNED;
        end
      end else if (mem_complete && dmem_resp_error_i) begin
        mem_trap = 1'b1;
        if (ex_mem_q.mem_op == rv32_pkg::MEM_LOAD) begin
          mem_trap_cause = rv32_core_pkg::CORE_TRAP_LOAD_ACCESS_FAULT;
        end else if (ex_mem_q.mem_op == rv32_pkg::MEM_STORE) begin
          mem_trap_cause = rv32_core_pkg::CORE_TRAP_STORE_ACCESS_FAULT;
        end
      end
    end
  end

  always_comb begin
    trap_inflight = id_trap ||
                    ex_trap ||
                    mem_trap ||
                    (id_ex_q.valid && id_ex_q.trap) ||
                    (ex_mem_q.valid && ex_mem_q.trap) ||
                    (mem_wb_q.valid && mem_wb_q.trap);
  end

  always_comb begin
    // Requests are blocking: each port allows at most one outstanding response.
    // Commit and regfile side effects come exclusively from the MEM/WB payload.
    imem_req_valid_o = !rst_i && !halted_q && !trap_inflight && !fetch_pending_q && !id_stall && !ex_redirect_valid && !mem_active && !muldiv_active;
    imem_req_addr_o = fetch_pc_q;
    dmem_req_valid_o = !rst_i && !halted_q && mem_active && !dmem_pending_q && !mem_misaligned;
    dmem_req_addr_o = dmem_req_valid_o ? mem_aligned_addr : 32'd0;
    dmem_req_write_o = dmem_req_valid_o && (ex_mem_q.mem_op == rv32_pkg::MEM_STORE);
    dmem_req_wdata_o = dmem_req_write_o ? mem_store_word : 32'd0;
    dmem_req_wstrb_o = dmem_req_write_o ? mem_store_mask : 4'b0000;

    commit_valid_o = mem_wb_q.valid;
    commit_pc_o = mem_wb_q.valid ? mem_wb_q.pc : 32'd0;
    commit_instr_o = mem_wb_q.valid ? mem_wb_q.instr : 32'd0;
    commit_rd_write_o = mem_wb_q.valid && !mem_wb_q.trap && mem_wb_q.rd_write;
    commit_rd_addr_o = mem_wb_q.valid ? mem_wb_q.rd_addr : 5'd0;
    commit_rd_wdata_o = mem_wb_q.valid ? mem_wb_q.rd_wdata : 32'd0;
    commit_mem_valid_o = mem_wb_q.valid && !mem_wb_q.trap&& (mem_wb_q.mem_op != rv32_pkg::MEM_NONE);
    commit_mem_write_o = commit_mem_valid_o && (mem_wb_q.mem_op == rv32_pkg::MEM_STORE);
    commit_mem_addr_o = commit_mem_valid_o ? mem_wb_q.mem_addr : 32'd0;
    commit_mem_rmask_o = commit_mem_valid_o ? mem_wb_q.mem_rmask : 4'b0000;
    commit_mem_wmask_o = commit_mem_valid_o ? mem_wb_q.mem_wmask : 4'b0000;
    commit_mem_rdata_o = commit_mem_valid_o ? mem_wb_q.mem_rdata : 32'd0;
    commit_mem_wdata_o = commit_mem_valid_o ? mem_wb_q.mem_wdata : 32'd0;
    commit_trap_o = mem_wb_q.valid && mem_wb_q.trap;
    commit_trap_cause_o = rv32_core_pkg::trap_cause_e'(commit_trap_o ? mem_wb_q.trap_cause : (rv32_core_pkg::CORE_TRAP_NONE));
    halted_o = halted_q;
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      fetch_pc_q <= RESET_PC;
      fetch_pending_q <= 1'b0;
      fetch_discard_q <= 1'b0;
      if_id_q <= '0;
      id_ex_q <= '0;
      ex_mem_q <= '0;
      mem_wb_q <= '0;
      dmem_pending_q <= 1'b0;
      muldiv_pending_q <= 1'b0;
      halted_q <= 1'b0;
    end else if (mem_wb_q.valid && mem_wb_q.trap) begin
      halted_q <= 1'b1;
      fetch_pending_q <= 1'b0;
      fetch_discard_q <= 1'b0;
      if_id_q <= '0;
      id_ex_q <= '0;
      ex_mem_q <= '0;
      mem_wb_q <= '0;
      dmem_pending_q <= 1'b0;
      muldiv_pending_q <= 1'b0;
    end else if (!halted_q) begin
      // Memory and RV32M operations hold younger stages until their response.
      // Redirects and traps clear younger payloads before normal stage movement.
      if (mem_active) begin
        if (mem_trap) begin
          ex_mem_q <= '0;
          mem_wb_q <= mem_wb_d;
          id_ex_q <= '0;
          if_id_q <= '0;
          dmem_pending_q <= 1'b0;
        end else if (mem_complete) begin
          ex_mem_q <= '0;
          mem_wb_q <= mem_wb_d;
        end else begin
          mem_wb_q <= '0;
        end
      end else if (muldiv_active) begin
        mem_wb_q <= mem_wb_d;
        if (muldiv_complete) begin
          id_ex_q <= '0;
          ex_mem_q <= ex_mem_d;
        end else begin
          ex_mem_q <= '0;
        end
      end else begin
        ex_mem_q <= ex_mem_d;
        mem_wb_q <= mem_wb_d;
        if (ex_trap) begin
          id_ex_q <= '0;
          if_id_q <= '0;
        end else if (ex_redirect_valid) begin
          id_ex_q <= '0;
          if_id_q <= '0;
          fetch_pc_q <= ex_redirect_target;
          if (fetch_pending_q) begin
            fetch_discard_q <= 1'b1;
          end
        end else if (id_stall) begin
          id_ex_q <= '0;
        end else begin
          id_ex_q <= id_ex_d;
          if (if_id_q.valid) begin
            if_id_q <= '0;
          end
        end
      end
      if ((multiplier_req_valid && multiplier_req_ready) || (divider_req_valid && divider_req_ready)) begin
        muldiv_pending_q <= 1'b1;
      end else if (muldiv_complete) begin
        muldiv_pending_q <= 1'b0;
      end
      if (dmem_req_valid_o && dmem_req_ready_i) begin
        dmem_pending_q <= 1'b1;
      end else if (mem_complete) begin
        dmem_pending_q <= 1'b0;
      end
      if (imem_req_valid_o && imem_req_ready_i) begin
        fetch_pending_q <= 1'b1;
      end
      if (fetch_pending_q && imem_resp_valid_i) begin
        fetch_pending_q <= 1'b0;
        if (fetch_discard_q) begin
          fetch_discard_q <= 1'b0;
        end else if (trap_inflight || halted_q) begin
        end else if (mem_active || muldiv_active) begin
        end else if (ex_redirect_valid) begin
        end else if (imem_resp_error_i) begin
          if_id_q.valid <= 1'b1;
          if_id_q.pc <= fetch_pc_q;
          if_id_q.instr <= 32'd0;
          if_id_q.trap <= 1'b1;
          if_id_q.trap_cause <= rv32_core_pkg::CORE_TRAP_INSTRUCTION_ACCESS_FAULT;
        end else begin
          if_id_q.valid <= 1'b1;
          if_id_q.pc <= fetch_pc_q;
          if_id_q.instr <= imem_resp_data_i;
          if_id_q.trap <= 1'b0;
          if_id_q.trap_cause <= rv32_core_pkg::CORE_TRAP_NONE;
          fetch_pc_q <= fetch_pc_q + 32'd4;
        end
      end
    end
  end

endmodule
