// SPDX-License-Identifier: Apache-2.0
//
// Shared types used across the RV32IM core.
//
// ALU operation values are internal control encodings. The decoder and all
// execution units import this package so that they use the same definitions.

`timescale 1ns/1ps

package rv32_pkg;

  typedef enum logic [3:0] {
    ALU_ADD,
    ALU_SUB,
    ALU_SLL,
    ALU_SLT,
    ALU_SLTU,
    ALU_XOR,
    ALU_SRL,
    ALU_SRA,
    ALU_OR,
    ALU_AND
  } alu_op_e;

endpackage
