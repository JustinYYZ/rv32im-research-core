// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for rv32_branch_unit.
//
// Cover true and false equality, signed negative values, unsigned high-bit
// values, and equality boundaries for both less-than and greater-or-equal.

`timescale 1ns/1ps

module rv32_branch_unit_tb;

  import rv32_pkg::*;

  branch_op_e op;
  logic [31:0] lhs, rhs;
  logic taken;
  int unsigned checks, errors;

  rv32_branch_unit dut (
    .op_i    (op),
    .lhs_i   (lhs),
    .rhs_i   (rhs),
    .taken_o (taken)
  );

  task automatic check_branch(
    input string test_name,
    input branch_op_e op_i,
    input logic [31:0] lhs_i, rhs_i,
    input logic expected_i
  );
    op = op_i;
    lhs = lhs_i;
    rhs = rhs_i;
    #1;
    checks++;

    if (taken !== expected_i) begin
      $error("Test %s failed: op=%0d lhs=%h rhs=%h expected=%b got=%b",
             test_name, op_i, lhs_i, rhs_i, expected_i, taken);
      errors++;
    end
  endtask

  initial begin
    checks = 0;
    errors = 0;

    check_branch("BR_EQ true", BR_EQ, 32'd1, 32'd1, 1'b1);
    check_branch("BR_EQ false", BR_EQ, 32'd1, 32'd2, 1'b0);
    check_branch("BR_NE true", BR_NE, 32'd1, 32'd2, 1'b1);
    check_branch("BR_NE false", BR_NE, 32'd1, 32'd1, 1'b0);
    check_branch("BR_LT true", BR_LT, 32'd1, 32'd2, 1'b1);
    check_branch("BR_LT signed true", BR_LT, 32'hffffffff, 32'd1, 1'b1);
    check_branch("BR_LT false", BR_LT, 32'd2, 32'd1, 1'b0);
    check_branch("BR_LT equal", BR_LT, 32'd5, 32'd5, 1'b0);
    check_branch("BR_GE true", BR_GE, 32'd2, 32'd1, 1'b1);
    check_branch("BR_GE signed true", BR_GE, 32'd1, 32'hffffffff, 1'b1);
    check_branch("BR_GE false", BR_GE, 32'd1, 32'd2, 1'b0);
    check_branch("BR_GE equal", BR_GE, 32'd5, 32'd5, 1'b1);
    check_branch("BR_LTU true", BR_LTU, 32'd1, 32'd2, 1'b1);
    check_branch("BR_LTU false", BR_LTU, 32'd2, 32'd1, 1'b0);
    check_branch("BR_LTU false high bit", BR_LTU, 32'hffffffff, 32'd1, 1'b0);
    check_branch("BR_LTU equal", BR_LTU, 32'hffffffff, 32'hffffffff, 1'b0);
    check_branch("BR_GEU true", BR_GEU, 32'd2, 32'd1, 1'b1);
    check_branch("BR_GEU false", BR_GEU, 32'd1, 32'd2, 1'b0);
    check_branch("BR_GEU false high bit", BR_GEU, 32'd1, 32'hffffffff, 1'b0);
    check_branch("BR_GEU equal", BR_GEU, 32'hffffffff, 32'hffffffff, 1'b1);

    if (checks == 0) begin
      $fatal(1, "rv32_branch_unit_tb: no test cases");
    end else if (errors == 0) begin
      $display("rv32_branch_unit_tb: PASS - %0d checks", checks);
      $finish;
    end else begin
      $fatal(1, "rv32_branch_unit_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
