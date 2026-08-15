// SPDX-License-Identifier: Apache-2.0
//
// Combinational register-operand forwarding for the in-order pipeline.
//
// The consumer is the instruction currently in ID/EX. Its saved regfile data
// is the default operand value. A matching producer in MEM/WB can replace that
// value, while a matching producer in EX/MEM has higher priority because it is
// the younger and therefore architecturally newer instruction.

`timescale 1ns/1ps

module rv32_forwarding_unit (
    input  logic        consumer_valid_i,
    input  logic        consumer_rs1_used_i,
    input  logic        consumer_rs2_used_i,
    input  logic [4:0]  consumer_rs1_addr_i,
    input  logic [4:0]  consumer_rs2_addr_i,
    input  logic [31:0] consumer_rs1_data_i,
    input  logic [31:0] consumer_rs2_data_i,

    input  logic        ex_mem_valid_i,
    input  logic        ex_mem_rd_write_i,
    input  logic [4:0]  ex_mem_rd_addr_i,
    input  logic [31:0] ex_mem_rd_data_i,

    input  logic        mem_wb_valid_i,
    input  logic        mem_wb_rd_write_i,
    input  logic [4:0]  mem_wb_rd_addr_i,
    input  logic [31:0] mem_wb_rd_data_i,

    output logic [31:0] rs1_data_o,
    output logic [31:0] rs2_data_o
);

  always_comb begin
    rs1_data_o = consumer_rs1_data_i;
    rs2_data_o = consumer_rs2_data_i;

    // Start with the saved regfile operand, then apply MEM/WB and EX/MEM in
    // increasing priority order. An apparent x0 write is never forwarded.
    if (mem_wb_valid_i && mem_wb_rd_write_i && (mem_wb_rd_addr_i != 5'd0) && consumer_valid_i && consumer_rs1_used_i && (consumer_rs1_addr_i == mem_wb_rd_addr_i)) begin
      rs1_data_o = mem_wb_rd_data_i;
    end

    if (ex_mem_valid_i && ex_mem_rd_write_i && (ex_mem_rd_addr_i != 5'd0) && consumer_valid_i && consumer_rs1_used_i && (consumer_rs1_addr_i == ex_mem_rd_addr_i)) begin
      rs1_data_o = ex_mem_rd_data_i;
    end

    // rs2 uses the same validity, source-use, x0, match, and priority rules.
    if (mem_wb_valid_i && mem_wb_rd_write_i && (mem_wb_rd_addr_i != 5'd0) && consumer_valid_i && consumer_rs2_used_i && (consumer_rs2_addr_i == mem_wb_rd_addr_i)) begin
      rs2_data_o = mem_wb_rd_data_i;
    end

    if (ex_mem_valid_i && ex_mem_rd_write_i && (ex_mem_rd_addr_i != 5'd0) && consumer_valid_i && consumer_rs2_used_i && (consumer_rs2_addr_i == ex_mem_rd_addr_i)) begin
      rs2_data_o = ex_mem_rd_data_i;
    end
  end

endmodule
