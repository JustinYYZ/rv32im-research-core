// SPDX-License-Identifier: Apache-2.0
//
// Immediate generator for RV32 instruction formats.
//
// Current milestone:
//   - IMM_I: sign-extend instr_i[31:20] to 32 bits.
//   - IMM_U: copy instr_i[31:12] into bits [31:12] and clear bits [11:0].
//   - Return zero for IMM_NONE and formats not implemented in this milestone.
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
      default: begin
        imm_o = 32'd0;
      end
    endcase
  end
endmodule
