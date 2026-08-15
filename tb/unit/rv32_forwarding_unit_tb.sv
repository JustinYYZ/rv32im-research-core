// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for rv32_forwarding_unit.
//
// The test covers default regfile operands, forwarding from each producer
// stage, EX/MEM priority over MEM/WB, independent rs1/rs2 selection, unused
// sources, x0, invalid producers, and producers that do not write rd.

`timescale 1ns/1ps

module rv32_forwarding_unit_tb;

  logic        consumer_valid;
  logic        consumer_rs1_used;
  logic        consumer_rs2_used;
  logic [4:0]  consumer_rs1_addr;
  logic [4:0]  consumer_rs2_addr;
  logic [31:0] consumer_rs1_data;
  logic [31:0] consumer_rs2_data;
  logic        ex_mem_valid;
  logic        ex_mem_rd_write;
  logic [4:0]  ex_mem_rd_addr;
  logic [31:0] ex_mem_rd_data;
  logic        mem_wb_valid;
  logic        mem_wb_rd_write;
  logic [4:0]  mem_wb_rd_addr;
  logic [31:0] mem_wb_rd_data;
  logic [31:0] rs1_data;
  logic [31:0] rs2_data;

  int unsigned checks;
  int unsigned errors;

  rv32_forwarding_unit dut (
    .consumer_valid_i(consumer_valid),
    .consumer_rs1_used_i(consumer_rs1_used),
    .consumer_rs2_used_i(consumer_rs2_used),
    .consumer_rs1_addr_i(consumer_rs1_addr),
    .consumer_rs2_addr_i(consumer_rs2_addr),
    .consumer_rs1_data_i(consumer_rs1_data),
    .consumer_rs2_data_i(consumer_rs2_data),
    .ex_mem_valid_i(ex_mem_valid),
    .ex_mem_rd_write_i(ex_mem_rd_write),
    .ex_mem_rd_addr_i(ex_mem_rd_addr),
    .ex_mem_rd_data_i(ex_mem_rd_data),
    .mem_wb_valid_i(mem_wb_valid),
    .mem_wb_rd_write_i(mem_wb_rd_write),
    .mem_wb_rd_addr_i(mem_wb_rd_addr),
    .mem_wb_rd_data_i(mem_wb_rd_data),
    .rs1_data_o(rs1_data),
    .rs2_data_o(rs2_data)
  );

  task automatic clear_inputs;
    begin
      consumer_valid = 1'b0;
      consumer_rs1_used = 1'b0;
      consumer_rs2_used = 1'b0;
      consumer_rs1_addr = 5'd0;
      consumer_rs2_addr = 5'd0;
      consumer_rs1_data = 32'h1111_1111;
      consumer_rs2_data = 32'h2222_2222;
      ex_mem_valid = 1'b0;
      ex_mem_rd_write = 1'b0;
      ex_mem_rd_addr = 5'd0;
      ex_mem_rd_data = 32'haaaa_aaaa;
      mem_wb_valid = 1'b0;
      mem_wb_rd_write = 1'b0;
      mem_wb_rd_addr = 5'd0;
      mem_wb_rd_data = 32'hbbbb_bbbb;
    end
  endtask

  task automatic check_data(
    input string test_name,
    input logic [31:0] expected_rs1,
    input logic [31:0] expected_rs2
  );
    begin
      #1;
      checks++;
      if (rs1_data !== expected_rs1 || rs2_data !== expected_rs2) begin
        $error("rv32_forwarding_unit_tb: %s expected rs1=%h rs2=%h got rs1=%h rs2=%h", test_name, expected_rs1, expected_rs2, rs1_data, rs2_data);
        errors++;
      end
    end
  endtask

  initial begin
    checks = 0;
    errors = 0;

    // Without a matching producer, both outputs preserve the saved operands.
    clear_inputs();
    check_data("all inputs inactive", 32'h1111_1111, 32'h2222_2222);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd1;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd2;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd3;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd4;
    check_data("no matching producers", 32'h1111_1111, 32'h2222_2222);

    // Exercise each rs1 producer and prove EX/MEM has priority over MEM/WB.
    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd5;
    check_data("rs1 from MEM/WB", 32'hbbbb_bbbb, 32'h2222_2222);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd5;
    check_data("rs1 from EX/MEM", 32'haaaa_aaaa, 32'h2222_2222);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd5;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd5;
    check_data("EX/MEM priority for rs1", 32'haaaa_aaaa, 32'h2222_2222);

    // rs1 and rs2 select producers independently.
    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd6;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd5;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd6;
    check_data("rs1 from EX/MEM and rs2 from MEM/WB", 32'haaaa_aaaa, 32'hbbbb_bbbb);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd6;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd5;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd6;
    check_data("rs1 from MEM/WB and rs2 from EX/MEM", 32'hbbbb_bbbb, 32'haaaa_aaaa);

    // Invalid consumers/producers, unused sources, x0, and disabled writes do
    // not activate forwarding.
    clear_inputs();
    consumer_valid = 1'b0;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd5;
    check_data("invalid consumer", 32'h1111_1111, 32'h2222_2222);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b0;
    consumer_rs1_addr = 5'd5;
    consumer_rs2_used = 1'b0;
    consumer_rs2_addr = 5'd6;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd5;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd6;
    check_data("unused sources", 32'h1111_1111, 32'h2222_2222);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd0;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd0;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd0;
    check_data("x0 is not forwarded", 32'h1111_1111, 32'h2222_2222);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd6;
    ex_mem_valid = 1'b0;
    ex_mem_rd_write = 1'b1;
    ex_mem_rd_addr = 5'd5;
    mem_wb_valid = 1'b0;
    mem_wb_rd_write = 1'b1;
    mem_wb_rd_addr = 5'd6;
    check_data("invalid producers", 32'h1111_1111, 32'h2222_2222);

    clear_inputs();
    consumer_valid = 1'b1;
    consumer_rs1_used = 1'b1;
    consumer_rs1_addr = 5'd5;
    consumer_rs2_used = 1'b1;
    consumer_rs2_addr = 5'd6;
    ex_mem_valid = 1'b1;
    ex_mem_rd_write = 1'b0;
    ex_mem_rd_addr = 5'd5;
    mem_wb_valid = 1'b1;
    mem_wb_rd_write = 1'b0;
    mem_wb_rd_addr = 5'd6;
    check_data("producers do not write rd", 32'h1111_1111, 32'h2222_2222);

    if (checks == 0) begin
      $fatal(1, "rv32_forwarding_unit_tb: no checks executed");
    end else if (errors == 0) begin
      $display("rv32_forwarding_unit_tb: PASS - %0d checks", checks);
      $finish;
    end else begin
      $fatal(1, "rv32_forwarding_unit_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
