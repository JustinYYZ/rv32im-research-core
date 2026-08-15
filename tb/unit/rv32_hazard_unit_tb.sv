// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for the RAW hazard detector.
//
// Each case first clears every input, changes only the fields relevant to that
// case, waits for combinational logic to settle, and compares stall against the
// expected value. Cases cover both source operands, stage readiness, invalid
// producers, unused sources, and architectural x0.

`timescale 1ns/1ps

module rv32_hazard_unit_tb;

  logic       consumer_valid;
  logic       consumer_rs1_used;
  logic       consumer_rs2_used;
  logic [4:0] consumer_rs1_addr;
  logic [4:0] consumer_rs2_addr;
  logic       id_ex_valid;
  logic       id_ex_rd_write;
  logic [4:0] id_ex_rd_addr;
  logic       ex_mem_valid;
  logic       ex_mem_rd_write;
  logic [4:0] ex_mem_rd_addr;
  logic       mem_wb_valid;
  logic       mem_wb_rd_write;
  logic [4:0] mem_wb_rd_addr;
  logic       id_ex_data_ready;
  logic       ex_mem_data_ready;
  logic       mem_wb_data_ready;
  logic       stall;

  int unsigned checks;
  int unsigned errors;

  rv32_hazard_unit dut (
    .consumer_valid_i(consumer_valid),
    .consumer_rs1_used_i(consumer_rs1_used),
    .consumer_rs2_used_i(consumer_rs2_used),
    .consumer_rs1_addr_i(consumer_rs1_addr),
    .consumer_rs2_addr_i(consumer_rs2_addr),
    .id_ex_valid_i(id_ex_valid),
    .id_ex_rd_write_i(id_ex_rd_write),
    .id_ex_rd_addr_i(id_ex_rd_addr),
    .ex_mem_valid_i(ex_mem_valid),
    .ex_mem_rd_write_i(ex_mem_rd_write),
    .ex_mem_rd_addr_i(ex_mem_rd_addr),
    .mem_wb_valid_i(mem_wb_valid),
    .mem_wb_rd_write_i(mem_wb_rd_write),
    .mem_wb_rd_addr_i(mem_wb_rd_addr),
    .id_ex_data_ready_i(id_ex_data_ready),
    .ex_mem_data_ready_i(ex_mem_data_ready),
    .mem_wb_data_ready_i(mem_wb_data_ready),
    .stall_o(stall)
  );

  task automatic clear_inputs;
    begin
      consumer_valid = 1'b0;
      consumer_rs1_used = 1'b0;
      consumer_rs2_used = 1'b0;
      consumer_rs1_addr = 5'd0;
      consumer_rs2_addr = 5'd0;
      id_ex_valid = 1'b0;
      id_ex_rd_write = 1'b0;
      id_ex_rd_addr = 5'd0;
      ex_mem_valid = 1'b0;
      ex_mem_rd_write = 1'b0;
      ex_mem_rd_addr = 5'd0;
      mem_wb_valid = 1'b0;
      mem_wb_rd_write = 1'b0;
      mem_wb_rd_addr = 5'd0;
      id_ex_data_ready = 1'b0;
      ex_mem_data_ready = 1'b0;
      mem_wb_data_ready = 1'b0;
    end
  endtask

  task automatic check_stall(input string test_name, input logic expected_stall);
    begin
      #1;
      checks++;
      if (stall !== expected_stall) begin
        $error("rv32_hazard_unit_tb: %s expected stall=%b got=%b", test_name, expected_stall, stall);
        errors++;
      end
    end
  endtask

  initial begin
    checks = 0;
    errors = 0;
    clear_inputs();
    check_stall("all inputs inactive", 1'b0);

    // Inactive consumers, invalid producers, disabled writes, and nonmatching
    // destinations must not create a stall.
    clear_inputs();
    consumer_valid = 1'b0;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    id_ex_valid = 1'b1;
    id_ex_rd_write = 1'b1;
    id_ex_rd_addr = 5'd5;
    check_stall("invalid consumer", 1'b0);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    id_ex_valid = 1'b0;
    id_ex_rd_write = 1'b1;
    id_ex_rd_addr = 5'd5;
    check_stall("invalid producer", 1'b0);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    id_ex_valid = 1'b1;
    id_ex_rd_write = 1'b0;
    id_ex_rd_addr = 5'd5;
    check_stall("producer does not write rd", 1'b0);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    id_ex_valid = 1'b1;
    id_ex_rd_write = 1'b1;
    id_ex_rd_addr = 5'd6;
    check_stall("different register addresses", 1'b0);

    // Exercise rs1 dependencies against each older pipeline stage.
    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b0;
    consumer_rs1_addr = 5'd5;
    id_ex_valid = 1'b1;
    id_ex_rd_write = 1'b1;
    id_ex_rd_addr = 5'd5;
    check_stall("rs1 unused", 1'b0);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    id_ex_valid = 1'b1;
    id_ex_rd_write = 1'b1;
    id_ex_rd_addr = 5'd5;
    check_stall("rs1 depends on ID/EX", 1'b1);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd5;
    check_stall("rs1 depends on EX/MEM", 1'b1);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd5;
    check_stall("rs1 depends on MEM/WB", 1'b1);

    // Exercise rs2 dependencies and prove unused source fields are ignored.
    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs2_used = 1'b0;
    consumer_rs2_addr = 5'd5;
    id_ex_valid = 1'b1;
    id_ex_rd_write = 1'b1;
    id_ex_rd_addr = 5'd5;
    check_stall("rs2 unused", 1'b0);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd5;
    id_ex_valid = 1'b1;
    id_ex_rd_write = 1'b1;
    id_ex_rd_addr = 5'd5;
    check_stall("rs2 depends on ID/EX", 1'b1);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd5;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd5;
    check_stall("rs2 depends on EX/MEM", 1'b1);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd5;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd5;
    check_stall("rs2 depends on MEM/WB", 1'b1);

    // Architectural x0 never creates a dependency.

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd0;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd0;
    check_stall("rs1 x0 dependency ignored", 1'b0);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd0;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd0;
    check_stall("rs2 x0 dependency ignored", 1'b0);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    id_ex_valid = 1'b1;
    id_ex_rd_write = 1'b1;
    id_ex_rd_addr = 5'd5;
    id_ex_data_ready = 1'b1;
    check_stall("ID/EX dependency is forwardable", 1'b0);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd5;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd5;
    ex_mem_data_ready = 1'b1;
    check_stall("EX/MEM dependency is forwardable", 1'b0);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd5;
    mem_wb_data_ready = 1'b1;
    check_stall("MEM/WB dependency is bypassable", 1'b0);

    if (checks == 0) begin
      $fatal(1, "rv32_hazard_unit_tb: no checks executed");
    end else if (errors == 0) begin
      $display("rv32_hazard_unit_tb: PASS - %0d checks", checks);
      $finish;
    end else begin
      $fatal(1, "rv32_hazard_unit_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
