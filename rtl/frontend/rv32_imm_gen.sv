// SPDX-License-Identifier: Apache-2.0
//
// Immediate generator for the RV32 I, S, B, U, and J instruction formats.
// I, S, B, and J immediates are sign-extended to 32 bits. B- and J-type
// offsets receive the implicit zero least-significant bit. IMM_NONE returns
// zero.
//
// This module only rearranges instruction bits. It does not decide which
// immediate format an instruction uses; that decision belongs to the decoder.

`timescale 1ns/1ps

module rv32_imm_gen (
    input  logic [31:0]          instr_i,
    input  rv32_pkg::imm_kind_e  kind_i,
    output logic [31:0]          imm_o
);

  always_comb begin
    imm_o = 32'd0;
    
    case (kind_i)
      rv32_pkg::IMM_I: begin
        imm_o = {{20{instr_i[31]}}, instr_i[31:20]};
      end
      rv32_pkg::IMM_U: begin
        imm_o = {instr_i[31:12], 12'd0};
      end
      rv32_pkg::IMM_S: begin
        imm_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
      end
      rv32_pkg::IMM_B: begin
        imm_o = {{19{instr_i[31]}}, instr_i[31], instr_i[7], instr_i[30:25], instr_i[11:8], 1'b0};
      end
      rv32_pkg::IMM_J: begin
        imm_o = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12], instr_i[20], instr_i[30:21], 1'b0};
      end
      default: begin
        imm_o = 32'd0;
      end
    endcase
  end
endmodule
