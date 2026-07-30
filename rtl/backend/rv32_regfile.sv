// SPDX-License-Identifier: Apache-2.0
//
// RV32 architectural integer register file with two combinational read ports
// and one synchronous write port. Writes to x0 are ignored and reads from x0
// always return zero. A synchronous active-high reset clears the storage.

`timescale 1ns/1ps

module rv32_regfile (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic [4:0]  raddr1_i,
    output logic [31:0] rdata1_o,
    input  logic [4:0]  raddr2_i,
    output logic [31:0] rdata2_o,

    input  logic        we_i,
    input  logic [4:0]  waddr_i,
    input  logic [31:0] wdata_i
);

  logic [31:0] registers [0:31];
  integer index;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      for (index = 0; index < 32; index++) begin
        registers[index] <= 32'd0;
      end
    end else if (we_i && waddr_i != 5'd0) begin
      registers[waddr_i] <= wdata_i;
    end
  end

  // Combinational read ports
  assign rdata1_o = (raddr1_i == 5'd0) ? 32'd0 : registers[raddr1_i];
  assign rdata2_o = (raddr2_i == 5'd0) ? 32'd0 : registers[raddr2_i];

endmodule
