// SPDX-License-Identifier: Apache-2.0
//
// Multi-cycle RV32M integer divider.
//
// The datapath uses 32 iterations of Radix-2 restoring division and accepts
// one request at a time. Signed operations are converted to unsigned
// magnitudes before iteration, then the quotient or remainder sign is restored
// on the final cycle. Divide-by-zero and signed-overflow requests bypass the
// iterative datapath and return the results required by the RISC-V ISA.
//
// A request is accepted when req_valid_i && req_ready_o are high at a rising
// edge. The response has no ready input: the future core must always capture a
// result when resp_valid_o is high. Reset is synchronous and active high.
// Detailed derivation and implementation notes are documented in
// docs/radix2-iterative-divider.md.

`timescale 1ns/1ps

module rv32_divider (
    input  logic                   clk_i,
    input  logic                   rst_i,

    input  logic                   req_valid_i,
    output logic                   req_ready_o,
    input  rv32_pkg::muldiv_op_e   op_i,
    input  logic [31:0]            lhs_i,
    input  logic [31:0]            rhs_i,

    output logic                   resp_valid_o,
    output logic [31:0]            result_o
);

  // IDLE accepts a request, RUN performs one quotient-bit iteration per cycle,
  // and RESPOND exposes the registered result for one cycle.
  typedef enum logic [1:0] {
    DIV_STATE_IDLE,
    DIV_STATE_RUN,
    DIV_STATE_RESPOND
  } divider_state_e;

  divider_state_e state_q;
  logic [5:0] iteration_q;
  logic accept;

  logic signed_operation_comb;
  logic return_remainder_comb;
  logic quotient_negative_comb;
  logic remainder_negative_comb;
  logic [31:0] dividend_magnitude_comb;
  logic [31:0] divisor_magnitude_comb;

  logic quotient_negative_q;
  logic remainder_negative_q;
  logic return_remainder_q;

  logic divide_by_zero_comb;
  logic signed_overflow_comb;
  logic special_case_comb;
  logic [31:0] special_result_comb;
  logic [31:0] result_q;

  logic [32:0] remainder_q;
  logic [31:0] quotient_q;
  logic [31:0] divisor_q;

  logic [32:0] shifted_remainder_comb;
  logic [31:0] shifted_quotient_comb;
  logic [32:0] remainder_next_comb;
  logic [31:0] quotient_next_comb;

  // RISC-V defines architectural results for divide by zero and signed
  // INT_MIN/-1 overflow. These cases complete without entering RUN.
  always_comb begin
    special_result_comb = 32'd0;
    if (divide_by_zero_comb) begin
      special_result_comb = return_remainder_comb ? lhs_i : 32'hffff_ffff;
    end else if (signed_overflow_comb) begin
      special_result_comb = return_remainder_comb ? 32'd0 : 32'h8000_0000;
    end
  end

  // Each restoring iteration shifts the next dividend bit into the partial
  // remainder. If the divisor fits, subtract it and emit a one quotient bit;
  // otherwise preserve the shifted remainder and emit zero.
  always_comb begin
    shifted_remainder_comb = {remainder_q[31:0], quotient_q[31]};
    shifted_quotient_comb = {quotient_q[30:0], 1'b0};

    if (shifted_remainder_comb >= {1'b0, divisor_q}) begin
      remainder_next_comb = shifted_remainder_comb - {1'b0, divisor_q};
      quotient_next_comb = {shifted_quotient_comb[31:1], 1'b1};
    end else begin
      remainder_next_comb = shifted_remainder_comb;
      quotient_next_comb = shifted_quotient_comb;
    end
  end

  // Only IDLE accepts a request. RESPOND is a one-cycle valid pulse because
  // the interface has no response backpressure.
  assign req_ready_o  = !rst_i && (state_q == DIV_STATE_IDLE);
  assign resp_valid_o = !rst_i && (state_q == DIV_STATE_RESPOND);
  assign accept       = req_valid_i && req_ready_o;
  assign result_o     = result_q;

  // Normalize signed operations into unsigned magnitudes and retain the sign
  // information needed to reconstruct the architectural result.
  assign signed_operation_comb = (op_i == rv32_pkg::MD_DIV) || (op_i == rv32_pkg::MD_REM);
  assign return_remainder_comb = (op_i == rv32_pkg::MD_REM) || (op_i == rv32_pkg::MD_REMU);
  assign quotient_negative_comb = signed_operation_comb && (lhs_i[31] ^ rhs_i[31]);
  assign remainder_negative_comb = signed_operation_comb && lhs_i[31];
  assign dividend_magnitude_comb = signed_operation_comb && lhs_i[31] ? (~lhs_i + 32'd1) : lhs_i;
  assign divisor_magnitude_comb = signed_operation_comb && rhs_i[31] ? (~rhs_i + 32'd1) : rhs_i;

  assign divide_by_zero_comb = (rhs_i == 32'd0);
  assign signed_overflow_comb = signed_operation_comb && (lhs_i == 32'h80000000) && (rhs_i == 32'hFFFFFFFF);
  assign special_case_comb = divide_by_zero_comb || signed_overflow_comb;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= DIV_STATE_IDLE;
      iteration_q <= 6'd0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      return_remainder_q <= 1'b0;
      result_q <= 32'd0;
      remainder_q <= 33'd0;
      quotient_q <= 32'd0;
      divisor_q <= 32'd0;
    end else begin
      case (state_q)
        DIV_STATE_IDLE: begin
          iteration_q <= 6'd0;
          if (accept) begin
            quotient_negative_q <= quotient_negative_comb;
            remainder_negative_q <= remainder_negative_comb;
            return_remainder_q <= return_remainder_comb;
            if (special_case_comb) begin
              state_q <= DIV_STATE_RESPOND;
              result_q <= special_result_comb;
            end else begin
              remainder_q <= 33'd0;
              quotient_q <= dividend_magnitude_comb;
              divisor_q <= divisor_magnitude_comb;
              result_q <= 32'd0;
              state_q <= DIV_STATE_RUN;
            end
          end
        end
        DIV_STATE_RUN: begin
          remainder_q <= remainder_next_comb;
          quotient_q <= quotient_next_comb;
          // The cycle with iteration_q==31 still performs the 32nd update.
          // Select from the combinational next values to avoid losing it.
          if (iteration_q == 6'd31) begin
            if (return_remainder_q) begin
              result_q <= remainder_negative_q ? (~remainder_next_comb[31:0] + 32'd1) : remainder_next_comb[31:0];
            end else begin
              result_q <= quotient_negative_q ? (~quotient_next_comb + 32'd1) : quotient_next_comb;
            end
            state_q <= DIV_STATE_RESPOND;
          end else begin
            iteration_q <= iteration_q + 6'd1;
          end
        end
        DIV_STATE_RESPOND: begin
          state_q <= DIV_STATE_IDLE;
        end
        default: begin
          state_q <= DIV_STATE_IDLE;
          iteration_q <= 6'd0;
        end
      endcase
    end
  end

endmodule
