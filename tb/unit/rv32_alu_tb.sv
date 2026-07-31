// SPDX-License-Identifier: Apache-2.0
//
// Directed, self-checking unit test for rv32_alu.
//
// The cases cover every ALU operation along with overflow, signed comparison,
// and shift-amount boundaries. Expected results are explicit constants rather
// than a second copy of the ALU implementation.

`timescale 1ns/1ps

module rv32_alu_tb;

  import rv32_pkg::*;
  alu_op_e op;
  logic [31:0] lhs, rhs, result;
  int unsigned errors;

  rv32_alu dut (
    .op_i     (op),
    .lhs_i    (lhs),
    .rhs_i    (rhs),
    .result_o (result)
  );

  task automatic check_alu(
    input string test_name,
    input alu_op_e op_i,
    input logic [31:0] lhs_i, rhs_i, expected_i
  );
    op  = op_i;
    lhs = lhs_i;
    rhs = rhs_i;
    #1;

    if (result !== expected_i) begin
      $error("Test %s failed: op=%0d, lhs=%h, rhs=%h, expected=%h, got=%h",
              test_name, op_i, lhs_i, rhs_i, expected_i, result);
      errors++;
    end
  endtask

  initial begin
    errors = 0;
    check_alu("ADD 0+0", ALU_ADD, 32'h00000000, 32'h00000000, 32'h00000000);
    check_alu("ADD 1+2", ALU_ADD, 32'h00000001, 32'h00000002, 32'h00000003);
    check_alu("ADD ffff+1", ALU_ADD, 32'hffffffff, 32'h00000001, 32'h00000000);
    check_alu("SUB 3-2", ALU_SUB, 32'h00000003, 32'h00000002, 32'h00000001);
    check_alu("SUB 0-1", ALU_SUB, 32'h00000000, 32'h00000001, 32'hffffffff);
    check_alu("SLL 1<<31", ALU_SLL, 32'h00000001, 32'h0000001f, 32'h80000000);
    check_alu("SLL 1<<32", ALU_SLL, 32'h00000001, 32'h00000020, 32'h00000001);
    check_alu("SLT -1<1", ALU_SLT, 32'hffffffff, 32'h00000001, 32'h00000001);
    check_alu("SLTU -1<1", ALU_SLTU, 32'hffffffff, 32'h00000001, 32'h00000000);
    check_alu("SRL 0x80000000>>1", ALU_SRL, 32'h80000000, 32'h00000001, 32'h40000000);
    check_alu("SRA 0x80000000>>1", ALU_SRA, 32'h80000000, 32'h00000001, 32'hc0000000);
    check_alu("XOR 0x0000aa55^0x0000ff00", ALU_XOR, 32'h0000aa55, 32'h0000ff00, 32'h00005555);
    check_alu("OR 0xf0000000|0x0f000000", ALU_OR, 32'hf0000000, 32'h0f000000, 32'hff000000);
    check_alu("AND 0xff00ff00&0x0f0f0f0f", ALU_AND, 32'hff00ff00, 32'h0f0f0f0f, 32'h0f000f00);
    
    check_alu("SLT equal",       ALU_SLT,  32'h80000000, 32'h80000000, 32'h0);
    check_alu("SLT min less",    ALU_SLT,  32'h80000000, 32'h00000000, 32'h1);
    check_alu("SLTU zero less",  ALU_SLTU, 32'h00000000, 32'hffffffff, 32'h1);
    check_alu("SRL shift 31",    ALU_SRL,  32'h80000000, 32'd31,       32'h1);
    check_alu("SRA shift 31",    ALU_SRA,  32'h80000000, 32'd31,       32'hffffffff);
    check_alu("SRA positive",    ALU_SRA,  32'h40000000, 32'd1,        32'h20000000);
    check_alu("SRL shift 32",    ALU_SRL,  32'h80000000, 32'd32,       32'h80000000);
    
    if (errors == 0) begin
      $display("rv32_alu_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_alu_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
