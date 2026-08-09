// SPDX-License-Identifier: Apache-2.0
//
// Architectural types shared by processor cores and core-level testbenches.
// Trap encodings follow the RISC-V synchronous exception cause numbers. The
// reference core reports a trap through its commit interface and then halts;
// privileged trap entry is outside the current project scope.

`timescale 1ns/1ps

package rv32_core_pkg;

  typedef enum logic [3:0] {
    CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED = 4'd0,
    CORE_TRAP_INSTRUCTION_ACCESS_FAULT       = 4'd1,
    CORE_TRAP_ILLEGAL_INSTRUCTION            = 4'd2,
    CORE_TRAP_BREAKPOINT                     = 4'd3,
    CORE_TRAP_LOAD_ADDRESS_MISALIGNED        = 4'd4,
    CORE_TRAP_LOAD_ACCESS_FAULT              = 4'd5,
    CORE_TRAP_STORE_ADDRESS_MISALIGNED       = 4'd6,
    CORE_TRAP_STORE_ACCESS_FAULT             = 4'd7,
    CORE_TRAP_ECALL                          = 4'd8,
    CORE_TRAP_NONE                           = 4'd15
  } trap_cause_e;

endpackage
