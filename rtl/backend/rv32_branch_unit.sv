// SPDX-License-Identifier: Apache-2.0
//
// Combinational branch-condition unit for RV32I conditional branches.
// Equality operations compare raw bit patterns. BR_LT/BR_GE use signed
// comparison, while BR_LTU/BR_GEU use unsigned comparison.
//
// Assign taken_o on every path. A safe default before the case statement
// prevents unsupported control values from inferring a latch.

`timescale 1ns/1ps

module rv32_branch_unit (
    input  rv32_pkg::branch_op_e op_i,
    input  logic [31:0]          lhs_i,
    input  logic [31:0]          rhs_i,
    output logic                 taken_o
);

  always_comb begin
    taken_o = 1'b0;

    case (op_i)
      rv32_pkg::BR_EQ: taken_o = (lhs_i == rhs_i);
      rv32_pkg::BR_NE: taken_o = (lhs_i != rhs_i);
      rv32_pkg::BR_LT: taken_o = ($signed(lhs_i) < $signed(rhs_i));
      rv32_pkg::BR_GE: taken_o = ($signed(lhs_i) >= $signed(rhs_i));
      rv32_pkg::BR_LTU: taken_o = (lhs_i < rhs_i);
      rv32_pkg::BR_GEU: taken_o = (lhs_i >= rhs_i);
      default: taken_o = 1'b0;
    endcase
  end

endmodule
