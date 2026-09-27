// SPDX-License-Identifier: Apache-2.0
//
// Integration wrapper for the out-of-order core and separate blocking L1
// instruction/data caches. Core requests use the cache CPU-side ports, while
// this module exposes cache refill and writeback traffic to backing memory.

`timescale 1ns/1ps

module rv32_ooo_l1_top #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000,
    parameter int unsigned ICACHE_BYTES = rv32_cache_pkg::L1_DEFAULT_CACHE_BYTES,
    parameter int unsigned ICACHE_LINE_BYTES = rv32_cache_pkg::L1_DEFAULT_LINE_BYTES,
    parameter int unsigned DCACHE_BYTES = rv32_cache_pkg::L1_DEFAULT_CACHE_BYTES,
    parameter int unsigned DCACHE_LINE_BYTES = rv32_cache_pkg::L1_DEFAULT_LINE_BYTES
) (
    input  logic                            clk_i,
    input  logic                            rst_i,

    output logic                            imem_req_valid_o,
    input  logic                            imem_req_ready_i,
    output logic [31:0]                     imem_req_addr_o,
    input  logic                            imem_resp_valid_i,
    input  logic [31:0]                     imem_resp_data_i,
    input  logic                            imem_resp_error_i,

    output logic                            dmem_req_valid_o,
    input  logic                            dmem_req_ready_i,
    output logic [31:0]                     dmem_req_addr_o,
    output logic                            dmem_req_write_o,
    output logic [31:0]                     dmem_req_wdata_o,
    output logic [3:0]                      dmem_req_wstrb_o,
    input  logic                            dmem_resp_valid_i,
    input  logic [31:0]                     dmem_resp_rdata_i,
    input  logic                            dmem_resp_error_i,

    output logic                            commit_valid_o,
    output logic [31:0]                     commit_pc_o,
    output logic [31:0]                     commit_instr_o,
    output logic                            commit_rd_write_o,
    output logic [4:0]                      commit_rd_addr_o,
    output logic [31:0]                     commit_rd_wdata_o,
    output logic                            commit_mem_valid_o,
    output logic                            commit_mem_write_o,
    output logic [31:0]                     commit_mem_addr_o,
    output logic [3:0]                      commit_mem_rmask_o,
    output logic [3:0]                      commit_mem_wmask_o,
    output logic [31:0]                     commit_mem_rdata_o,
    output logic [31:0]                     commit_mem_wdata_o,
    output logic                            commit_trap_o,
    output rv32_core_pkg::trap_cause_e      commit_trap_cause_o,
    output logic                            halted_o
);

  // The core instruction-memory interface connects to the CPU side of I-Cache.
  logic        core_imem_req_valid;
  logic        core_imem_req_ready;
  logic [31:0] core_imem_req_addr;
  logic        core_imem_resp_valid;
  logic [31:0] core_imem_resp_data;
  logic        core_imem_resp_error;

  // The core data-memory interface connects to the CPU side of D-Cache.
  logic        core_dmem_req_valid;
  logic        core_dmem_req_ready;
  logic [31:0] core_dmem_req_addr;
  logic        core_dmem_req_write;
  logic [31:0] core_dmem_req_wdata;
  logic [3:0]  core_dmem_req_wstrb;
  logic        core_dmem_resp_valid;
  logic [31:0] core_dmem_resp_rdata;
  logic        core_dmem_resp_error;

  // Keep the core-facing memory channels internal to this wrapper while
  // forwarding architectural Commit state directly to the external observer.
  rv32_ooo_core #(
    .RESET_PC(RESET_PC)
  ) core (
    .clk_i(clk_i),
    .rst_i(rst_i),

    .imem_req_valid_o(core_imem_req_valid),
    .imem_req_ready_i(core_imem_req_ready),
    .imem_req_addr_o(core_imem_req_addr),
    .imem_resp_valid_i(core_imem_resp_valid),
    .imem_resp_data_i(core_imem_resp_data),
    .imem_resp_error_i(core_imem_resp_error),

    .dmem_req_valid_o(core_dmem_req_valid),
    .dmem_req_ready_i(core_dmem_req_ready),
    .dmem_req_addr_o(core_dmem_req_addr),
    .dmem_req_write_o(core_dmem_req_write),
    .dmem_req_wdata_o(core_dmem_req_wdata),
    .dmem_req_wstrb_o(core_dmem_req_wstrb),
    .dmem_resp_valid_i(core_dmem_resp_valid),
    .dmem_resp_rdata_i(core_dmem_resp_rdata),
    .dmem_resp_error_i(core_dmem_resp_error),

    .commit_valid_o(commit_valid_o),
    .commit_pc_o(commit_pc_o),
    .commit_instr_o(commit_instr_o),
    .commit_rd_write_o(commit_rd_write_o),
    .commit_rd_addr_o(commit_rd_addr_o),
    .commit_rd_wdata_o(commit_rd_wdata_o),
    .commit_mem_valid_o(commit_mem_valid_o),
    .commit_mem_write_o(commit_mem_write_o),
    .commit_mem_addr_o(commit_mem_addr_o),
    .commit_mem_rmask_o(commit_mem_rmask_o),
    .commit_mem_wmask_o(commit_mem_wmask_o),
    .commit_mem_rdata_o(commit_mem_rdata_o),
    .commit_mem_wdata_o(commit_mem_wdata_o),
    .commit_trap_o(commit_trap_o),
    .commit_trap_cause_o(commit_trap_cause_o),
    .halted_o(halted_o)
  );

  // I-cache misses become line-refill reads on the external instruction port.
  rv32_icache #(
    .ADDR_WIDTH(32),
    .CACHE_BYTES(ICACHE_BYTES),
    .LINE_BYTES(ICACHE_LINE_BYTES)
  ) icache (
    .clk_i(clk_i),
    .rst_i(rst_i),

    .cpu_req_valid_i(core_imem_req_valid),
    .cpu_req_ready_o(core_imem_req_ready),
    .cpu_req_addr_i(core_imem_req_addr),
    .cpu_resp_valid_o(core_imem_resp_valid),
    .cpu_resp_data_o(core_imem_resp_data),
    .cpu_resp_error_o(core_imem_resp_error),

    .mem_req_valid_o(imem_req_valid_o),
    .mem_req_ready_i(imem_req_ready_i),
    .mem_req_addr_o(imem_req_addr_o),
    .mem_resp_valid_i(imem_resp_valid_i),
    .mem_resp_data_i(imem_resp_data_i),
    .mem_resp_error_i(imem_resp_error_i)
  );

  // D-cache misses and dirty evictions become refill/writeback transactions
  // on the external data port.
  rv32_dcache #(
    .ADDR_WIDTH(32),
    .CACHE_BYTES(DCACHE_BYTES),
    .LINE_BYTES(DCACHE_LINE_BYTES)
  ) dcache (
    .clk_i(clk_i),
    .rst_i(rst_i),

    .cpu_req_valid_i(core_dmem_req_valid),
    .cpu_req_ready_o(core_dmem_req_ready),
    .cpu_req_addr_i(core_dmem_req_addr),
    .cpu_req_write_i(core_dmem_req_write),
    .cpu_req_wdata_i(core_dmem_req_wdata),
    .cpu_req_wstrb_i(core_dmem_req_wstrb),
    .cpu_resp_valid_o(core_dmem_resp_valid),
    .cpu_resp_rdata_o(core_dmem_resp_rdata),
    .cpu_resp_error_o(core_dmem_resp_error),

    .mem_req_valid_o(dmem_req_valid_o),
    .mem_req_ready_i(dmem_req_ready_i),
    .mem_req_addr_o(dmem_req_addr_o),
    .mem_req_write_o(dmem_req_write_o),
    .mem_req_wdata_o(dmem_req_wdata_o),
    .mem_req_wstrb_o(dmem_req_wstrb_o),
    .mem_resp_valid_i(dmem_resp_valid_i),
    .mem_resp_rdata_i(dmem_resp_rdata_i),
    .mem_resp_error_i(dmem_resp_error_i)
  );

endmodule
