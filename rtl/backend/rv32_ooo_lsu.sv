// SPDX-License-Identifier: Apache-2.0
//
// One-entry, ordered load/store execution unit. The Issue Queue must supply
// only a memory uop at the ROB Head. The LSU owns the accepted uop through its
// memory request, response, and held completion.
//
// Flush cancels an unaccepted request or completion. An already accepted
// request is drained before another uop can issue; its response is discarded.

`timescale 1ns/1ps

module rv32_ooo_lsu
  import rv32_ooo_pkg::*;
(
  input  logic                           clk_i,
  input  logic                           rst_i,
  input  logic                           flush_i,

  input  logic                           issue_valid_i,
  output logic                           issue_ready_o,
  input  issue_uop_t                     issue_uop_i,
  input  logic [31:0]                    issue_base_i,
  input  logic [31:0]                    issue_store_value_i,

  output logic                           dmem_req_valid_o,
  input  logic                           dmem_req_ready_i,
  output logic [31:0]                    dmem_req_addr_o,
  output logic                           dmem_req_write_o,
  output logic [31:0]                    dmem_req_wdata_o,
  output logic [3:0]                     dmem_req_wstrb_o,
  input  logic                           dmem_resp_valid_i,
  input  logic [31:0]                    dmem_resp_rdata_i,
  input  logic                           dmem_resp_error_i,

  output logic                           completion_valid_o,
  input  logic                           completion_ready_i,
  output completion_payload_t            completion_payload_o,
  output logic                           completion_trap_o,
  output rv32_core_pkg::trap_cause_e     completion_trap_cause_o,
  output logic                           completion_mem_valid_o,
  output logic                           completion_mem_write_o,
  output logic [31:0]                    completion_mem_addr_o,
  output logic [3:0]                     completion_mem_rmask_o,
  output logic [3:0]                     completion_mem_wmask_o,
  output logic [31:0]                    completion_mem_rdata_o,
  output logic [31:0]                    completion_mem_wdata_o
);

  typedef enum logic [1:0] {
    MEM_STATE_IDLE,
    MEM_STATE_REQUEST,
    MEM_STATE_RESPONSE,
    MEM_STATE_COMPLETE
  } mem_state_e;

  mem_state_e state_q;
  mem_state_e state_d;

  issue_uop_t uop_q;
  logic [31:0] effective_addr_q;
  logic [31:0] store_value_q;
  logic [31:0] result_q;
  logic [31:0] response_word_q;
  logic trap_q;
  rv32_core_pkg::trap_cause_e trap_cause_q;
  logic  discard_response_q;
  logic [31:0] lsu_aligned_addr;
  logic [31:0] lsu_store_word;
  logic [3:0] lsu_store_mask;
  logic [31:0] lsu_load_value;
  logic lsu_misaligned;

  assign completion_valid_o = !rst_i && !flush_i && (state_q == MEM_STATE_COMPLETE);

  rv32_lsu lsu(
    .mem_op_i(uop_q.mem_op),
    .mem_size_i(uop_q.mem_size),
    .load_unsigned_i(uop_q.load_unsigned),
    .addr_i(effective_addr_q),
    .store_value_i(store_value_q),
    .load_word_i(dmem_resp_rdata_i),
    .aligned_addr_o(lsu_aligned_addr),
    .store_word_o(lsu_store_word),
    .store_mask_o(lsu_store_mask),
    .load_value_o(lsu_load_value),
    .misaligned_o(lsu_misaligned)
  );

  always_comb begin
    state_d = state_q;
    issue_ready_o = 1'b0;
    dmem_req_valid_o = 1'b0;
    dmem_req_addr_o = 32'b0;
    dmem_req_write_o = 1'b0;
    dmem_req_wdata_o = 32'b0;
    dmem_req_wstrb_o = 4'b0;

    // IDLE accepts one uop; REQUEST and RESPONSE hold the memory transaction;
    // COMPLETE retains its result and metadata until the completion is accepted.
    case (state_q)
      MEM_STATE_IDLE: begin
        issue_ready_o = !rst_i && !flush_i;
        if (issue_valid_i && issue_ready_o) begin
          state_d = MEM_STATE_REQUEST;
        end
      end
      MEM_STATE_REQUEST: begin
        if (!rst_i && !flush_i) begin
          if (lsu_misaligned) begin
            state_d = MEM_STATE_COMPLETE;
          end else begin
            dmem_req_valid_o = 1'b1;
            dmem_req_addr_o = lsu_aligned_addr;
            dmem_req_write_o = (uop_q.mem_op == rv32_pkg::MEM_STORE);
            dmem_req_wdata_o = lsu_store_word;
            dmem_req_wstrb_o = lsu_store_mask;
            if (dmem_req_valid_o && dmem_req_ready_i) begin
              state_d = MEM_STATE_RESPONSE;
            end
          end
        end
      end
      MEM_STATE_RESPONSE: begin
        if (!rst_i && !flush_i && dmem_resp_valid_i) begin
          if (discard_response_q) begin
            state_d = MEM_STATE_IDLE;
          end else begin
            state_d = MEM_STATE_COMPLETE;
          end
        end
      end
      MEM_STATE_COMPLETE: begin
        if (completion_valid_o && completion_ready_i) state_d = MEM_STATE_IDLE;
      end
      default: state_d = MEM_STATE_IDLE;
    endcase
  end

  // Completion data depends only on retained state. CDB ready changes the next
  // state, but must not feed back into this producer's valid or payload.
  always_comb begin
    completion_payload_o = '0;
    if (completion_valid_o) begin
      completion_payload_o.rob_tag = uop_q.rob_tag;
      completion_payload_o.phys_rd = uop_q.phys_rd;
      completion_payload_o.rd_write = uop_q.rd_write && (uop_q.mem_op == rv32_pkg::MEM_LOAD) && !trap_q;
      completion_payload_o.result = result_q;
      completion_payload_o.actual_next_pc = uop_q.pc + 32'd4;
      completion_payload_o.trap = trap_q;
      if (trap_q) completion_payload_o.trap_cause = trap_cause_q;

      if (!trap_q && (uop_q.mem_op != rv32_pkg::MEM_NONE)) begin
        completion_payload_o.mem_valid = 1'b1;
        completion_payload_o.mem_addr = lsu_aligned_addr;
        if (uop_q.mem_op == rv32_pkg::MEM_LOAD) begin
          completion_payload_o.mem_rdata = response_word_q;
          case (uop_q.mem_size)
            rv32_pkg::MEM_BYTE: completion_payload_o.mem_rmask = 4'b0001 << effective_addr_q[1:0];
            rv32_pkg::MEM_HALF: completion_payload_o.mem_rmask = effective_addr_q[1] ? 4'b1100 : 4'b0011;
            rv32_pkg::MEM_WORD: completion_payload_o.mem_rmask = 4'b1111;
            default: completion_payload_o.mem_rmask = 4'b0000;
          endcase
        end else begin
          completion_payload_o.mem_write = 1'b1;
          completion_payload_o.mem_wmask = lsu_store_mask;
          completion_payload_o.mem_wdata = lsu_store_word;
        end
      end
    end
  end

  assign completion_trap_o = completion_valid_o && trap_q;
  assign completion_trap_cause_o = rv32_core_pkg::trap_cause_e'(completion_valid_o ? trap_cause_q : rv32_core_pkg::CORE_TRAP_NONE);
  assign completion_mem_valid_o = completion_payload_o.mem_valid;
  assign completion_mem_write_o = completion_payload_o.mem_write;
  assign completion_mem_addr_o = completion_payload_o.mem_addr;
  assign completion_mem_rmask_o = completion_payload_o.mem_rmask;
  assign completion_mem_wmask_o = completion_payload_o.mem_wmask;
  assign completion_mem_rdata_o = completion_payload_o.mem_rdata;
  assign completion_mem_wdata_o = completion_payload_o.mem_wdata;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= MEM_STATE_IDLE;
      uop_q <= '0;
      effective_addr_q <= '0;
      store_value_q <= '0;
      result_q <= '0;
      response_word_q <= '0;
      trap_q <= 1'b0;
      trap_cause_q <= rv32_core_pkg::CORE_TRAP_NONE;
      discard_response_q <= 1'b0;
    end else if (flush_i) begin
      if (state_q == MEM_STATE_RESPONSE && !dmem_resp_valid_i) begin
        state_q <= MEM_STATE_RESPONSE;
        discard_response_q <= 1'b1;
      end else begin
        state_q <= MEM_STATE_IDLE;
        discard_response_q <= 1'b0;
      end

      uop_q <= '0;
      effective_addr_q <= '0;
      store_value_q <= '0;
      result_q <= '0;
      response_word_q <= '0;
      trap_q <= 1'b0;
      trap_cause_q <= rv32_core_pkg::CORE_TRAP_NONE;
    end else begin
      state_q <= state_d;

      if (issue_valid_i && issue_ready_o) begin
        uop_q <= issue_uop_i;
        effective_addr_q <= issue_base_i + issue_uop_i.imm;
        store_value_q <= issue_store_value_i;
        result_q <= '0;
        response_word_q <= '0;
        trap_q <= 1'b0;
        trap_cause_q <= rv32_core_pkg::CORE_TRAP_NONE;
        discard_response_q <= 1'b0;
      end else if (state_q == MEM_STATE_REQUEST && lsu_misaligned) begin
        trap_q <= 1'b1;
        if (uop_q.mem_op == rv32_pkg::MEM_LOAD) begin
          trap_cause_q <= rv32_core_pkg::CORE_TRAP_LOAD_ADDRESS_MISALIGNED;
        end else begin
          trap_cause_q <= rv32_core_pkg::CORE_TRAP_STORE_ADDRESS_MISALIGNED;
        end
      end else if (state_q == MEM_STATE_RESPONSE && dmem_resp_valid_i) begin
        discard_response_q <= 1'b0;

        if (!discard_response_q) begin
          trap_q <= dmem_resp_error_i;

          if (dmem_resp_error_i) begin
            result_q <= '0;
            response_word_q <= '0;
            if (uop_q.mem_op == rv32_pkg::MEM_LOAD) begin
              trap_cause_q <= rv32_core_pkg::CORE_TRAP_LOAD_ACCESS_FAULT;
            end else begin
              trap_cause_q <= rv32_core_pkg::CORE_TRAP_STORE_ACCESS_FAULT;
            end
          end else begin
            trap_cause_q <= rv32_core_pkg::CORE_TRAP_NONE;
            result_q <= (uop_q.mem_op == rv32_pkg::MEM_LOAD) ? lsu_load_value : 32'b0;
            response_word_q <= (uop_q.mem_op == rv32_pkg::MEM_LOAD) ? dmem_resp_rdata_i : 32'b0;
          end
        end
      end
    end
  end

endmodule
