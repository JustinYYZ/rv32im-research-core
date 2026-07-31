// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for rv32_imm_gen.
//
// Minimum cases:
//   IMM_I  0x001xxxxx -> 0x00000001
//   IMM_I  0xfffxxxxx -> 0xffffffff
//   IMM_I  0x800xxxxx -> 0xfffff800
//   IMM_U  0x12345xxx -> 0x12345000
//   IMM_U  0xfffffxxx -> 0xfffff000
//   IMM_NONE          -> 0x00000000
//
// Use explicit expected constants. In particular, do not calculate the
// expected value by copying the DUT's concatenation into the testbench.

`timescale 1ns/1ps

module rv32_imm_gen_tb;

  import rv32_pkg::*;

  logic [31:0] instr;
  imm_kind_e   kind;
  logic [31:0] imm;
  int unsigned errors;

  rv32_imm_gen dut (
    .instr_i (instr),
    .kind_i  (kind),
    .imm_o   (imm)
  );

  task automatic check_imm_gen(
    input string test_name,
    input imm_kind_e kind_i,
    input logic [31:0] instr_i, expected_i
  );
    kind = kind_i;
    instr = instr_i;
    #1;

    if (imm !== expected_i) begin
      $error("Test %s failed: kind=%0d, instr=%h, expected=%h, got=%h",
              test_name, kind_i, instr_i, expected_i, imm);
      errors++;
    end
  endtask

  initial begin
    errors = 0;
    
    check_imm_gen("IMM_I 0x001xxxxx", IMM_I, 32'h00100000, 32'h00000001);
    check_imm_gen("IMM_I 0x012xxxxx", IMM_I, 32'h01200000, 32'h00000012);
    check_imm_gen("IMM_I 0xfffxxxxx", IMM_I, 32'hfff00000, 32'hffffffff);
    check_imm_gen("IMM_I 0x800xxxxx", IMM_I, 32'h80000000, 32'hfffff800);
    check_imm_gen("IMM_U 0x12345xxx", IMM_U, 32'h12345000, 32'h12345000);
    check_imm_gen("IMM_U 0xfffffxxx", IMM_U, 32'hfffff000, 32'hfffff000);
    check_imm_gen("IMM_NONE", IMM_NONE, 32'h00000000, 32'h00000000);
    check_imm_gen("IMM_NONE ignores bits", IMM_NONE, 32'hfff00000, 32'h00000000);

    if (errors == 0) begin
      $display("rv32_imm_gen_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_imm_gen_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
