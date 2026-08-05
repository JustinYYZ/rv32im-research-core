// SPDX-License-Identifier: Apache-2.0
//
// Three-stage pipelined RV32M integer multiplier.
//
// The datapath uses Radix-4 modified Booth recoding followed by a carry-save
// Wallace reduction tree and one final carry-propagate addition. It accepts
// one request per cycle and returns the selected 32-bit RV32M result exactly
// three cycles after acceptance.
// Detailed derivation and implementation order are documented in
// docs/radix4-booth-multiplier.md.
//
// A request is accepted when req_valid_i && req_ready_o are high at a rising
// edge. The response has no ready input: the future core must always capture a
// result when resp_valid_o is high. Reset is synchronous and active high.

`timescale 1ns/1ps

module rv32_multiplier (
    input  logic                    clk_i,
    input  logic                    rst_i,

    input  logic                    req_valid_i,
    output logic                    req_ready_o,
    input  rv32_pkg::muldiv_op_e    op_i,
    input  logic [31:0]             lhs_i,
    input  logic [31:0]             rhs_i,

    output logic                    resp_valid_o,
    output logic [31:0]             result_o
);

  localparam int unsigned PRODUCT_WIDTH = 66;
  localparam int unsigned BOOTH_GROUPS  = 17;

  logic valid_stage0;
  logic valid_stage1;
  logic valid_stage2;
  logic accept;

  logic signed [32:0] lhs_ext;
  logic signed [32:0] rhs_ext;

  rv32_pkg::muldiv_op_e op_stage0;
  logic signed [PRODUCT_WIDTH-1:0] sum_row_stage1;
  logic signed [PRODUCT_WIDTH-1:0] carry_row_stage1;
  logic signed [PRODUCT_WIDTH-1:0] final_product_comb;
  rv32_pkg::muldiv_op_e op_stage1;
  logic [31:0] selected_result;
  logic [31:0] result_stage2;

  logic [34:0] booth_bits;
  logic signed [PRODUCT_WIDTH-1:0] multiplicand_width;
  logic signed [PRODUCT_WIDTH-1:0] partial_product_comb [0:BOOTH_GROUPS-1];
  logic signed [PRODUCT_WIDTH-1:0] partial_product_stage0 [0:BOOTH_GROUPS-1];

  logic signed [PRODUCT_WIDTH-1:0] wallace_level1 [0:11];
  logic signed [PRODUCT_WIDTH-1:0] wallace_level2 [0:7];
  logic signed [PRODUCT_WIDTH-1:0] wallace_level3 [0:5];
  logic signed [PRODUCT_WIDTH-1:0] wallace_level4 [0:3];
  logic signed [PRODUCT_WIDTH-1:0] wallace_level5 [0:2];
  logic signed [PRODUCT_WIDTH-1:0] wallace_level6 [0:1];

  // Normalize all four RV32M multiply operations into signed 33-bit operands.
  //
  // MD_MUL:    low 32 bits; signedness does not change those bits.
  // MD_MULH:   signed lhs   x signed rhs,   select product[63:32].
  // MD_MULHSU: signed lhs   x unsigned rhs, select product[63:32].
  // MD_MULHU:  unsigned lhs x unsigned rhs, select product[63:32].
  //
  // A convenient common representation is a 33-bit operand: prepend the sign
  // bit for a signed input and prepend zero for an unsigned input. A generic
  // signed 33x33 product needs PRODUCT_WIDTH bits. Keep that width through the
  // reduction tree and discard extension bits only after result selection.

  function automatic logic signed [PRODUCT_WIDTH-1:0] booth_multiple(
    input logic [2:0] code,
    input logic signed [PRODUCT_WIDTH-1:0] multiplicand
  );
    begin
      case (code)
        3'b000, 3'b111: booth_multiple = '0;
        3'b001, 3'b010: booth_multiple = multiplicand;
        3'b011:         booth_multiple = multiplicand <<< 1;
        3'b100:         booth_multiple = -(multiplicand <<< 1);
        3'b101, 3'b110: booth_multiple = -multiplicand;
        default:        booth_multiple = '0;
      endcase
    end
  endfunction

  function automatic logic signed [PRODUCT_WIDTH-1:0] csa_sum(
    input logic signed [PRODUCT_WIDTH-1:0] a,
    input logic signed [PRODUCT_WIDTH-1:0] b,
    input logic signed [PRODUCT_WIDTH-1:0] c
  );
    begin
      csa_sum = a ^ b ^ c;
    end
  endfunction

  function automatic logic signed [PRODUCT_WIDTH-1:0] csa_carry(
    input logic signed [PRODUCT_WIDTH-1:0] a,
    input logic signed [PRODUCT_WIDTH-1:0] b,
    input logic signed [PRODUCT_WIDTH-1:0] c
  );
    begin
      csa_carry = ((a & b) | (b & c) | (c & a)) <<< 1;
    end
  endfunction

  always_comb begin
    lhs_ext = 33'sd0;
    rhs_ext = 33'sd0;
    case (op_i)
      rv32_pkg::MD_MUL, rv32_pkg::MD_MULHU: begin
        lhs_ext = $signed({1'b0, lhs_i});
        rhs_ext = $signed({1'b0, rhs_i});
      end
      rv32_pkg::MD_MULH: begin
        lhs_ext = $signed({lhs_i[31], lhs_i});
        rhs_ext = $signed({rhs_i[31], rhs_i});
      end
      rv32_pkg::MD_MULHSU: begin
        lhs_ext = $signed({lhs_i[31], lhs_i});
        rhs_ext = $signed({1'b0, rhs_i});
      end
      default: begin
        lhs_ext = 33'sd0;
        rhs_ext = 33'sd0;
      end
    endcase
  end


  // Stage 0: operand preparation and Radix-4 Booth partial-product generation.
  //
  // Append a zero below the multiplier LSB, sign-extend it above bit 32, and
  // examine BOOTH_GROUPS overlapping 3-bit groups. Each group selects 0, +A,
  // +2A, -A, or -2A. Shift each selected partial product by two bit positions
  // per group. Carefully preserve the sign extension of negative products.
  //
  // Booth group -> multiple of A
  //   000, 111 ->  0
  //   001, 010 -> +A
  //   011      -> +2A
  //   100      -> -2A
  //   101, 110 -> -A
  //
  always_comb begin
    multiplicand_width = {{33{lhs_ext[32]}}, lhs_ext};
    booth_bits = {rhs_ext[32], rhs_ext, 1'b0};
    for (int unsigned i = 0; i < BOOTH_GROUPS; i++) begin
      partial_product_comb[i] = booth_multiple(booth_bits[i*2 +: 3], multiplicand_width) <<< (i*2);
    end
  end

  // Stage 1: greedily reduce 17 partial-product rows to two carry-save rows.
  // Each 3:2 compressor preserves a+b+c as sum+carry without propagating a
  // carry across the full word. The row counts are 17->12->8->6->4->3->2.
  always_comb begin
    for (int unsigned i = 0; i < 5; i++) begin
      wallace_level1[2*i] = csa_sum(partial_product_stage0[3*i], partial_product_stage0[3*i+1], partial_product_stage0[3*i+2]);
      wallace_level1[2*i+1] = csa_carry(partial_product_stage0[3*i], partial_product_stage0[3*i+1], partial_product_stage0[3*i+2]);
    end
    wallace_level1[10] = partial_product_stage0[15];
    wallace_level1[11] = partial_product_stage0[16];

    for (int unsigned i = 0; i < 4; i++) begin
      wallace_level2[2*i] = csa_sum(wallace_level1[3*i], wallace_level1[3*i+1], wallace_level1[3*i+2]);
      wallace_level2[2*i+1] = csa_carry(wallace_level1[3*i], wallace_level1[3*i+1], wallace_level1[3*i+2]);
    end

    for (int unsigned i = 0; i < 2; i++) begin
      wallace_level3[2*i] = csa_sum(wallace_level2[3*i], wallace_level2[3*i+1], wallace_level2[3*i+2]);
      wallace_level3[2*i+1] = csa_carry(wallace_level2[3*i], wallace_level2[3*i+1], wallace_level2[3*i+2]);
    end
    wallace_level3[4] = wallace_level2[6];
    wallace_level3[5] = wallace_level2[7];

    for (int unsigned i = 0; i < 2; i++) begin
      wallace_level4[2*i] = csa_sum(wallace_level3[3*i], wallace_level3[3*i+1], wallace_level3[3*i+2]);
      wallace_level4[2*i+1] = csa_carry(wallace_level3[3*i], wallace_level3[3*i+1], wallace_level3[3*i+2]);
    end

    wallace_level5[0] = csa_sum(wallace_level4[0], wallace_level4[1], wallace_level4[2]);
    wallace_level5[1] = csa_carry(wallace_level4[0], wallace_level4[1], wallace_level4[2]);
    wallace_level5[2] = wallace_level4[3];

    wallace_level6[0] = csa_sum(wallace_level5[0], wallace_level5[1], wallace_level5[2]);
    wallace_level6[1] = csa_carry(wallace_level5[0], wallace_level5[1], wallace_level5[2]);
  end

  // Stage 2: perform the only full carry-propagate addition, then select the
  // architectural low or high 32-bit result.
  assign final_product_comb = sum_row_stage1 + carry_row_stage1;
  always_comb begin
    selected_result = 32'd0;
    case (op_stage1)
      rv32_pkg::MD_MUL:    selected_result = final_product_comb[31:0];
      rv32_pkg::MD_MULH,
      rv32_pkg::MD_MULHSU,
      rv32_pkg::MD_MULHU:  selected_result = final_product_comb[63:32];
      default:             selected_result = 32'd0;
    endcase
  end

  // Control pipeline. With no response backpressure, every stage advances on
  // every cycle and the unit remains ready whenever reset is inactive.
  assign req_ready_o = !rst_i;
  assign accept      = req_valid_i && req_ready_o;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      valid_stage0 <= 1'b0;
      valid_stage1 <= 1'b0;
      valid_stage2 <= 1'b0;
      resp_valid_o <= 1'b0;
      op_stage0 <= rv32_pkg::MD_NONE;
      sum_row_stage1   <= '0;
      carry_row_stage1 <= '0;
      op_stage1 <= rv32_pkg::MD_NONE;
      result_stage2 <= 32'd0;
      result_o <= 32'd0;
      for (int unsigned i = 0; i < BOOTH_GROUPS; i++) begin
        partial_product_stage0[i] <= '0;
      end
    end else begin
      valid_stage0 <= accept;
      valid_stage1 <= valid_stage0;
      valid_stage2 <= valid_stage1;
      resp_valid_o <= valid_stage2;
      if (accept) begin
        op_stage0 <= op_i;
        for (int unsigned i = 0; i < BOOTH_GROUPS; i++) begin
          partial_product_stage0[i] <= partial_product_comb[i];
        end
      end
      if (valid_stage0) begin
        sum_row_stage1   <= wallace_level6[0];
        carry_row_stage1 <= wallace_level6[1];
        op_stage1        <= op_stage0;
      end
      if (valid_stage1) begin
        result_stage2 <= selected_result;
      end
      if (valid_stage2) begin
        result_o <= result_stage2;
      end
    end
  end

endmodule
