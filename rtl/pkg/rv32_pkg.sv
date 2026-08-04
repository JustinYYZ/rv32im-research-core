// SPDX-License-Identifier: Apache-2.0
//
// Shared types used across the RV32IM core.
//
// The decoder and execution units share these internal control encodings.

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

  // Selects the comparison used by a conditional branch.
  typedef enum logic [2:0] {
    BR_EQ,
    BR_NE,
    BR_LT,
    BR_GE,
    BR_LTU,
    BR_GEU
  } branch_op_e;

  // Classifies instructions that may redirect the PC.
  typedef enum logic [1:0] {
    CF_NONE,
    CF_BRANCH,
    CF_JAL,
    CF_JALR
  } control_flow_e;

  // Selects the value written to an architectural destination register.
  typedef enum logic [1:0] {
    WB_ALU,
    WB_PC_PLUS_4,
    WB_MEM
  } writeback_sel_e;

  // Describes the memory action carried by a decoded instruction. Using one
  // enum prevents an instruction from being marked as both a load and store.
  typedef enum logic [1:0] {
    MEM_NONE,
    MEM_LOAD,
    MEM_STORE
  } mem_op_e;

  // Access width used by both load extraction and store byte-mask generation.
  typedef enum logic [1:0] {
    MEM_BYTE,
    MEM_HALF,
    MEM_WORD
  } mem_size_e;

  // Selects the source connected to the ALU's left and right operands.
  // ZERO + immediate implements LUI without adding a separate datapath.
  typedef enum logic [1:0] {
    OP_A_RS1,
    OP_A_PC,
    OP_A_ZERO
  } operand_a_sel_e;

  typedef enum logic {
    OP_B_RS2,
    OP_B_IMM
  } operand_b_sel_e;

  // Immediate layouts encoded by the base RISC-V instruction formats.
  typedef enum logic [2:0] {
    IMM_NONE,
    IMM_I,
    IMM_S,
    IMM_B,
    IMM_U,
    IMM_J
  } imm_kind_e;

  // Environment and memory-ordering events are kept separate from ALU,
  // control-flow, and memory-access controls. The core handles their eventual
  // architectural behavior after decode.
  typedef enum logic [1:0] {
    SYS_NONE,
    SYS_ECALL,
    SYS_EBREAK,
    SYS_FENCE
  } system_op_e;

  localparam logic [6:0] OPCODE_OP       = 7'b0110011;
  localparam logic [6:0] OPCODE_OP_IMM   = 7'b0010011;
  localparam logic [6:0] OPCODE_LUI      = 7'b0110111;
  localparam logic [6:0] OPCODE_AUIPC    = 7'b0010111;
  localparam logic [6:0] OPCODE_SYSTEM   = 7'b1110011;
  localparam logic [6:0] OPCODE_LOAD     = 7'b0000011;
  localparam logic [6:0] OPCODE_MISC_MEM = 7'b0001111;
  localparam logic [6:0] OPCODE_STORE    = 7'b0100011;
  localparam logic [6:0] OPCODE_BRANCH   = 7'b1100011;
  localparam logic [6:0] OPCODE_JALR     = 7'b1100111;
  localparam logic [6:0] OPCODE_JAL      = 7'b1101111;

endpackage
