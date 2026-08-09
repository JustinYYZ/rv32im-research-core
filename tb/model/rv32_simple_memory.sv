// SPDX-License-Identifier: Apache-2.0
//
// Simple dual-port word memory model for core-level simulation.
//
// The model provides independent instruction-read and data-read/write
// request channels backed by one little-endian byte-addressed array. It is a
// testbench component, not synthesizable cache or main-memory RTL.

`timescale 1ns/1ps

module rv32_simple_memory #(
    parameter int unsigned WORDS = 4096
) (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic        imem_req_valid_i,
    output logic        imem_req_ready_o,
    input  logic [31:0] imem_req_addr_i,
    output logic        imem_resp_valid_o,
    output logic [31:0] imem_resp_data_o,
    output logic        imem_resp_error_o,

    input  logic        dmem_req_valid_i,
    output logic        dmem_req_ready_o,
    input  logic [31:0] dmem_req_addr_i,
    input  logic        dmem_req_write_i,
    input  logic [31:0] dmem_req_wdata_i,
    input  logic [3:0]  dmem_req_wstrb_i,
    output logic        dmem_resp_valid_o,
    output logic [31:0] dmem_resp_rdata_o,
    output logic        dmem_resp_error_o
);

  logic [31:0] memory [0:WORDS-1];
  int index;
  logic imem_pending_q;
  logic [31:0] imem_addr_q;
  logic dmem_pending_q;
  logic [31:0] dmem_addr_q;
  logic dmem_write_q;
  logic [31:0] dmem_wdata_q;
  logic [3:0] dmem_wstrb_q;

  // Core-level tests use these helpers to construct directed programs and
  // inspect final memory state without a separate software image loader.
  task automatic clear_memory;
    begin
      for (index = 0; index < WORDS; index++) begin
        memory[index] = 32'd0;
      end
    end
  endtask

  task automatic write_word(input logic [31:0] byte_addr, input logic [31:0] data);
    begin
      if (byte_addr[1:0] != 2'b00 || (byte_addr >> 2) >= WORDS) begin
        $fatal(1, "write_word address is invalid: %h", byte_addr);
      end
      memory[byte_addr >> 2] = data;
    end
  endtask

  function automatic logic [31:0] read_word(input logic [31:0] byte_addr);
    begin
      if (byte_addr[1:0] != 2'b00 || (byte_addr >> 2) >= WORDS) begin
        read_word = 32'd0;
      end else begin
        read_word = memory[byte_addr >> 2];
      end
    end
  endfunction

  // Each port accepts at most one request, returns a one-cycle response, and
  // reports misaligned or out-of-range accesses without indexing outside the
  // array. Data writes update only the byte lanes selected by dmem_req_wstrb_i.
  assign imem_req_ready_o = !imem_pending_q;
  assign dmem_req_ready_o = !dmem_pending_q;

  always_ff @(posedge clk_i) begin
    imem_resp_valid_o <= 1'b0;
    imem_resp_data_o <= 32'd0;
    imem_resp_error_o <= 1'b0;
    dmem_resp_valid_o <= 1'b0;
    dmem_resp_rdata_o <= 32'd0;
    dmem_resp_error_o <= 1'b0;
    if (rst_i) begin
      imem_pending_q <= 1'b0;
      imem_addr_q <= 32'd0;
      dmem_pending_q <= 1'b0;
      dmem_addr_q <= 32'd0;
      dmem_write_q <= 1'b0;
      dmem_wdata_q <= 32'd0;
      dmem_wstrb_q <= 4'd0;
    end else begin
      if (imem_pending_q) begin
        imem_resp_valid_o <= 1'b1;
        imem_pending_q <= 1'b0;
        if (imem_addr_q[1:0] != 2'b00 || (imem_addr_q >> 2) >= WORDS) begin
          imem_resp_data_o <= 32'd0;
          imem_resp_error_o <= 1'b1;
        end else begin
          imem_resp_data_o <= memory[imem_addr_q >> 2];
          imem_resp_error_o <= 1'b0;
        end
      end else if (imem_req_valid_i && imem_req_ready_o) begin
        imem_pending_q <= 1'b1;
        imem_addr_q <= imem_req_addr_i;
      end
      if (dmem_pending_q) begin
        dmem_resp_valid_o <= 1'b1;
        dmem_pending_q <= 1'b0;
        if (dmem_addr_q[1:0] != 2'b00 || (dmem_addr_q >> 2) >= WORDS) begin
          dmem_resp_rdata_o <= 32'd0;
          dmem_resp_error_o <= 1'b1;
        end else begin
          dmem_resp_error_o <= 1'b0;
          if (dmem_write_q) begin
            dmem_resp_rdata_o <= 32'd0;
            if (dmem_wstrb_q[0]) memory[dmem_addr_q >> 2][7:0]   <= dmem_wdata_q[7:0];
            if (dmem_wstrb_q[1]) memory[dmem_addr_q >> 2][15:8]  <= dmem_wdata_q[15:8];
            if (dmem_wstrb_q[2]) memory[dmem_addr_q >> 2][23:16] <= dmem_wdata_q[23:16];
            if (dmem_wstrb_q[3]) memory[dmem_addr_q >> 2][31:24] <= dmem_wdata_q[31:24];
          end else begin
            dmem_resp_rdata_o <= memory[dmem_addr_q >> 2];
          end
        end
      end else if (dmem_req_valid_i && dmem_req_ready_o) begin
        dmem_pending_q <= 1'b1;
        dmem_addr_q <= dmem_req_addr_i;
        dmem_write_q <= dmem_req_write_i;
        dmem_wdata_q <= dmem_req_wdata_i;
        dmem_wstrb_q <= dmem_req_wstrb_i;
      end
    end
  end

endmodule
