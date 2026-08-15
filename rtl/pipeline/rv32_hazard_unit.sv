// SPDX-License-Identifier: Apache-2.0
//
// RAW hazard detector for the in-order pipeline.
//
// The instruction in IF/ID is the consumer. Instructions in ID/EX, EX/MEM,
// and MEM/WB are older producers that may not have written their destination
// register yet. A matching producer stalls the consumer only when its result is
// not available through the configured bypass paths.

`timescale 1ns/1ps

module rv32_hazard_unit (
    input  logic       consumer_valid_i,
    input  logic       consumer_rs1_used_i,
    input  logic       consumer_rs2_used_i,
    input  logic [4:0] consumer_rs1_addr_i,
    input  logic [4:0] consumer_rs2_addr_i,

    input  logic       id_ex_valid_i,
    input  logic       id_ex_rd_write_i,
    input  logic [4:0] id_ex_rd_addr_i,

    input  logic       ex_mem_valid_i,
    input  logic       ex_mem_rd_write_i,
    input  logic [4:0] ex_mem_rd_addr_i,

    input  logic       mem_wb_valid_i,
    input  logic       mem_wb_rd_write_i,
    input  logic [4:0] mem_wb_rd_addr_i,

    input  logic       id_ex_data_ready_i,
    input  logic       ex_mem_data_ready_i,
    input  logic       mem_wb_data_ready_i,

    output logic       stall_o
);
  logic id_ex_rs1_match;
  logic ex_mem_rs1_match;
  logic mem_wb_rs1_match;
  logic rs1_hazard;

  logic id_ex_rs2_match;
  logic ex_mem_rs2_match;
  logic mem_wb_rs2_match;
  logic rs2_hazard;

  always_comb begin

    // A RAW dependency exists only for a valid, used, nonzero source and a
    // valid older producer that writes the same architectural register. The
    // data-ready inputs suppress stalls when a bypass path can satisfy it.
    id_ex_rs1_match = id_ex_valid_i && id_ex_rd_write_i && (id_ex_rd_addr_i == consumer_rs1_addr_i);
    ex_mem_rs1_match = ex_mem_valid_i && ex_mem_rd_write_i && (ex_mem_rd_addr_i == consumer_rs1_addr_i);
    mem_wb_rs1_match = mem_wb_valid_i && mem_wb_rd_write_i && (mem_wb_rd_addr_i == consumer_rs1_addr_i);
    rs1_hazard = consumer_valid_i && consumer_rs1_used_i && (consumer_rs1_addr_i != 5'd0) && ((id_ex_rs1_match && !id_ex_data_ready_i) || (ex_mem_rs1_match && !ex_mem_data_ready_i) || (mem_wb_rs1_match && !mem_wb_data_ready_i));
    id_ex_rs2_match = id_ex_valid_i && id_ex_rd_write_i && (id_ex_rd_addr_i == consumer_rs2_addr_i);
    ex_mem_rs2_match = ex_mem_valid_i && ex_mem_rd_write_i && (ex_mem_rd_addr_i == consumer_rs2_addr_i);
    mem_wb_rs2_match = mem_wb_valid_i && mem_wb_rd_write_i && (mem_wb_rd_addr_i == consumer_rs2_addr_i);
    rs2_hazard = consumer_valid_i && consumer_rs2_used_i && (consumer_rs2_addr_i != 5'd0) && ((id_ex_rs2_match && !id_ex_data_ready_i) || (ex_mem_rs2_match && !ex_mem_data_ready_i) || (mem_wb_rs2_match && !mem_wb_data_ready_i));
    stall_o = rs1_hazard || rs2_hazard;

    // Either unresolved source dependency holds IF/ID and inserts an ID/EX bubble.
  end

endmodule
