// SPDX-License-Identifier: Apache-2.0
//
// Shared defaults and control types for the RV32 cache hierarchy.
// Individual cache modules remain parameterized so capacity and line size can
// be varied for PPA and miss-rate experiments without changing their protocol.

`timescale 1ns/1ps

package rv32_cache_pkg;

  localparam int unsigned L1_DEFAULT_CACHE_BYTES = 32 * 1024;
  localparam int unsigned L1_DEFAULT_LINE_BYTES = 32;
  localparam int unsigned CACHE_WORD_BYTES = 4;

  typedef enum logic [2:0] {
    ICACHE_STATE_IDLE,
    ICACHE_STATE_LOOKUP,
    ICACHE_STATE_REFILL_REQUEST,
    ICACHE_STATE_REFILL_WAIT,
    ICACHE_STATE_REFILL_INSTALL,
    ICACHE_STATE_RESPONSE
  } icache_state_e;

  typedef enum logic [2:0] {
    DCACHE_STATE_IDLE,
    DCACHE_STATE_LOOKUP,
    DCACHE_STATE_WRITEBACK_REQUEST,
    DCACHE_STATE_WRITEBACK_WAIT,
    DCACHE_STATE_REFILL_REQUEST,
    DCACHE_STATE_REFILL_WAIT,
    DCACHE_STATE_REFILL_INSTALL,
    DCACHE_STATE_RESPONSE
  } dcache_state_e;

endpackage
