// SPDX-License-Identifier: Apache-2.0
//
// OoO wrapper for the single-request iterative RV32M divider. It retains the
// instruction identity across variable execution latency and holds the result
// until the shared CDB accepts it. Recovery cancels both active and held work.

`timescale 1ns/1ps

module rv32_ooo_divider
  import rv32_ooo_pkg::*;
(
  input  logic                clk_i,
  input  logic                rst_i,
  input  logic                flush_i,

  input  logic                issue_valid_i,
  output logic                issue_ready_o,
  input  issue_uop_t          issue_uop_i,
  input  logic [31:0]         issue_lhs_i,
  input  logic [31:0]         issue_rhs_i,

  output logic                completion_valid_o,
  input  logic                completion_ready_i,
  output completion_payload_t completion_payload_o
);

  logic unit_reset;
  logic issue_fire;
  logic completion_fire;

  logic        divider_req_valid;
  logic        divider_req_ready;
  logic        divider_resp_valid;
  logic [31:0] divider_result;

  logic          request_active_q;
  rob_tag_t      request_rob_tag_q;
  phys_reg_idx_t request_phys_rd_q;
  logic          request_rd_write_q;
  logic [31:0]   request_actual_next_pc_q;

  logic                completion_valid_q;
  completion_payload_t completion_payload_q;

  assign unit_reset = rst_i || flush_i;

  // One request owns the wrapper until its completion is consumed. Both active
  // execution and a held result block new requests, reserving space for the
  // divider response, which cannot be backpressured.
  assign issue_ready_o = !unit_reset && !request_active_q && !completion_valid_q && divider_req_ready;
  assign issue_fire = issue_valid_i && issue_ready_o;
  assign divider_req_valid = !unit_reset && !request_active_q && !completion_valid_q && issue_valid_i;

  rv32_divider divider (
    .clk_i(clk_i),
    .rst_i(unit_reset),
    .req_valid_i(divider_req_valid),
    .req_ready_o(divider_req_ready),
    .op_i(issue_uop_i.muldiv_op),
    .lhs_i(issue_lhs_i),
    .rhs_i(issue_rhs_i),
    .resp_valid_o(divider_resp_valid),
    .result_o(divider_result)
  );

  // A held completion stays valid until the CDB handshake. Reset and Flush
  // suppress the interface immediately; invalid output payloads are zero.
  assign completion_valid_o = !unit_reset && completion_valid_q;
  assign completion_payload_o = completion_valid_o ? completion_payload_q : '0;
  assign completion_fire = completion_valid_o && completion_ready_i;

  // Valid bits qualify the saved identity and completion payload, so only the
  // flags need reset. unit_reset also resets the divider to cancel iteration.
  always_ff @(posedge clk_i) begin
    if (unit_reset) begin
      request_active_q <= 1'b0;
      completion_valid_q <= 1'b0;
    end else begin
      // Retain identity at acceptance because Issue inputs may change later.
      if (issue_fire) begin
        request_active_q <= 1'b1;
        request_rob_tag_q <= issue_uop_i.rob_tag;
        request_phys_rd_q <= issue_uop_i.phys_rd;
        request_rd_write_q <= issue_uop_i.rd_write;
        request_actual_next_pc_q <= issue_uop_i.pc + 32'd4;
      end

      // Capture the one-cycle response before the divider returns to idle.
      if (divider_resp_valid) begin
        completion_valid_q <= 1'b1;
        completion_payload_q.rob_tag <= request_rob_tag_q;
        completion_payload_q.phys_rd <= request_phys_rd_q;
        completion_payload_q.rd_write <= request_rd_write_q;
        completion_payload_q.result <= divider_result;
        completion_payload_q.actual_next_pc <= request_actual_next_pc_q;
        request_active_q <= 1'b0;
      end

      // With one outstanding request, response capture and dequeue are separate
      // events. No state update is needed while the completion is stalled.
      if (completion_fire) begin
        completion_valid_q <= 1'b0;
      end
    end
  end

endmodule
