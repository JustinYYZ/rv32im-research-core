// SPDX-License-Identifier: Apache-2.0
//
// Combinational integer ALU for RV32I register and immediate operations.
//
// Shift operations use rhs_i[4:0], as required for RV32. SLT and SRA cast
// their operands to signed values; the other operations use the raw bit
// patterns. Addition and subtraction wrap to 32 bits.

`timescale 1ns/1ps

module rv32_alu
    import rv32_pkg::*;
    (
        input  alu_op_e     op_i,
        input  logic [31:0] lhs_i,
        input  logic [31:0] rhs_i,
        output logic [31:0] result_o
    );
    
    always_comb begin
        case (op_i)
        ALU_ADD:  result_o = lhs_i + rhs_i;
        ALU_SUB:  result_o = lhs_i - rhs_i;
        ALU_SLL:  result_o = lhs_i << rhs_i[4:0];
        ALU_SLT:  result_o = ($signed(lhs_i) < $signed(rhs_i)) ? 32'd1 : 32'd0;
        ALU_SLTU: result_o = (lhs_i < rhs_i) ? 32'd1 : 32'd0;
        ALU_XOR:  result_o = lhs_i ^ rhs_i;
        ALU_SRL:  result_o = lhs_i >> rhs_i[4:0];
        ALU_SRA:  result_o = $signed(lhs_i) >>> rhs_i[4:0];
        ALU_OR:   result_o = lhs_i | rhs_i;
        ALU_AND:  result_o = lhs_i & rhs_i;
        default:  result_o = 32'd0;
        endcase
    end
endmodule
