// SPDX-License-Identifier: Apache-2.0
//
// Physical register file for the out-of-order backend. Each register carries
// a data value and a ready bit. Rename allocation clears readiness, while CDB
// writeback stores the completed value and restores readiness.

`timescale 1ns/1ps

module rv32_phys_regfile
  import rv32_ooo_pkg::*;
(
  input  logic            clk_i,
  input  logic            rst_i,

  // Two combinational source ports expose both value and availability.
  input  phys_reg_idx_t   raddr1_i,
  output logic [31:0]     rdata1_o,
  output logic            rready1_o,

  input  phys_reg_idx_t   raddr2_i,
  output logic [31:0]     rdata2_o,
  output logic            rready2_o,

  // Rename invalidates a newly allocated destination until execution completes.
  input  logic            alloc_valid_i,
  input  phys_reg_idx_t   alloc_addr_i,

  // Completion writes the destination value and marks it available.
  input  logic            wb_valid_i,
  input  phys_reg_idx_t   wb_addr_i,
  input  logic [31:0]     wb_data_i
);

  // Data storage is not reset because an allocated destination cannot be read
  // until its ready bit is restored by writeback.
  logic [31:0] data_q [0:PHYS_REGS-1];
  logic [PHYS_REGS-1:0] ready_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      ready_q <= '1;
    end else begin
      // Writeback publishes a completed value. Requests for p0 are ignored.
      if (wb_valid_i && wb_addr_i != '0) begin
        data_q[wb_addr_i] <= wb_data_i;
        ready_q[wb_addr_i] <= 1'b1;
      end

      // Allocation follows writeback so it wins a same-address collision and a
      // newly assigned destination cannot appear ready with an older value.
      if (alloc_valid_i && alloc_addr_i != '0) begin
        ready_q[alloc_addr_i] <= 1'b0;
      end
    end
  end

  // p0 is hardwired to zero and is always available, independent of the arrays.
  assign rdata1_o = (raddr1_i == '0) ? 32'b0 : data_q[raddr1_i];
  assign rready1_o = (raddr1_i == '0) ? 1'b1 : ready_q[raddr1_i];
  assign rdata2_o = (raddr2_i == '0) ? 32'b0 : data_q[raddr2_i];
  assign rready2_o = (raddr2_i == '0) ? 1'b1 : ready_q[raddr2_i];

endmodule
