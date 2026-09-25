// SPDX-License-Identifier: Apache-2.0
//
// Directed checks for CDB selection, downstream backpressure, and round-robin
// progress. Arithmetic correctness belongs to the individual functional units.

`timescale 1ns/1ps

module rv32_cdb_arbiter_tb;
  import rv32_ooo_pkg::*;

  logic                clk;
  logic                rst;
  logic                flush;
  logic                alu_valid;
  logic                alu_ready;
  completion_payload_t alu_payload;
  logic                mul_valid;
  logic                mul_ready;
  completion_payload_t mul_payload;
  logic                div_valid;
  logic                div_ready;
  completion_payload_t div_payload;
  logic                mem_valid;
  logic                mem_ready;
  completion_payload_t mem_payload;
  logic                cdb_valid;
  logic                cdb_ready;
  completion_payload_t cdb_payload;
  int unsigned         errors;

  rv32_cdb_arbiter dut (
    .clk_i(clk),
    .rst_i(rst),
    .flush_i(flush),
    .alu_valid_i(alu_valid),
    .alu_ready_o(alu_ready),
    .alu_payload_i(alu_payload),
    .mul_valid_i(mul_valid),
    .mul_ready_o(mul_ready),
    .mul_payload_i(mul_payload),
    .div_valid_i(div_valid),
    .div_ready_o(div_ready),
    .div_payload_i(div_payload),
    .mem_valid_i(mem_valid),
    .mem_ready_o(mem_ready),
    .mem_payload_i(mem_payload),
    .cdb_valid_o(cdb_valid),
    .cdb_ready_i(cdb_ready),
    .cdb_payload_o(cdb_payload)
  );

  always #5 clk = ~clk;

  task automatic drive_idle;
    begin
      rst = 1'b0;
      flush = 1'b0;
      alu_valid = 1'b0;
      alu_payload = '0;
      mul_valid = 1'b0;
      mul_payload = '0;
      div_valid = 1'b0;
      div_payload = '0;
      mem_valid = 1'b0;
      mem_payload = '0;
      cdb_ready = 1'b0;
    end
  endtask

  task automatic reset_dut;
    begin
      @(negedge clk);
      drive_idle();
      rst = 1'b1;

      @(posedge clk);
      #1;
      rst = 1'b0;
    end
  endtask

  // A single producer must reach the CDB without changing its identity.
  task automatic test_single_producer;
    completion_payload_t expected_payload;
    begin
      expected_payload = '0;
      expected_payload.rob_tag.generation = 1'b1;
      expected_payload.rob_tag.index = ROB_INDEX_WIDTH'(3);
      expected_payload.phys_rd = phys_reg_idx_t'(40);
      expected_payload.rd_write = 1'b1;
      expected_payload.result = 32'h1234_5678;
      expected_payload.actual_next_pc = 32'h8000_0004;

      @(negedge clk);
      alu_valid = 1'b1;
      alu_payload = expected_payload;
      cdb_ready = 1'b1;
      #1;

      if (cdb_valid !== 1'b1 ||
          alu_ready !== 1'b1 ||
          mul_ready !== 1'b0 ||
          div_ready !== 1'b0 ||
          mem_ready !== 1'b0) begin
        $error("test_single_producer: handshake mismatch");
        errors++;
      end
      if (cdb_payload !== expected_payload) begin
        $error("test_single_producer: payload mismatch");
        errors++;
      end

      @(posedge clk);
      @(negedge clk);
      alu_valid = 1'b0;
      cdb_ready = 1'b0;
    end
  endtask

  // Reusable grant check for consecutive round-robin transfers.
  task automatic check_grant(
    input string test_name,
    input completion_payload_t expected_payload,
    input logic expected_alu_ready,
    input logic expected_mul_ready,
    input logic expected_div_ready,
    input logic expected_mem_ready
  );
    begin
      #1;
      if (cdb_valid !== 1'b1 ||
          cdb_payload !== expected_payload ||
          alu_ready !== expected_alu_ready ||
          mul_ready !== expected_mul_ready ||
          div_ready !== expected_div_ready ||
          mem_ready !== expected_mem_ready) begin
        $error("%s: handshake mismatch", test_name);
        errors++;
      end

      @(posedge clk);
      #1;
    end
  endtask

  task automatic test_round_robin;
    begin
      reset_dut();

      @(negedge clk);

      alu_payload = '0;
      alu_payload.result = 32'haaaa_aaaa;
      mul_payload = '0;
      mul_payload.result = 32'hbbbb_bbbb;
      div_payload = '0;
      div_payload.result = 32'hcccc_cccc;
      mem_payload = '0;
      mem_payload.mem_valid = 1'b1;
      mem_payload.mem_write = 1'b1;
      mem_payload.mem_addr = 32'h0000_2000;
      mem_payload.mem_wmask = 4'b1111;
      mem_payload.mem_wdata = 32'hdddd_dddd;

      alu_valid = 1'b1;
      mul_valid = 1'b1;
      div_valid = 1'b1;
      mem_valid = 1'b1;
      cdb_ready = 1'b1;

      check_grant("test_round_robin: ALU grant", alu_payload, 1'b1, 1'b0, 1'b0, 1'b0);
      check_grant("test_round_robin: MUL grant", mul_payload, 1'b0, 1'b1, 1'b0, 1'b0);
      check_grant("test_round_robin: DIV grant", div_payload, 1'b0, 1'b0, 1'b1, 1'b0);
      check_grant("test_round_robin: MEM grant", mem_payload, 1'b0, 1'b0, 1'b0, 1'b1);

      @(negedge clk);
      drive_idle();
    end
  endtask

  // Backpressure must preserve the selected payload and prevent priority from
  // advancing until a transfer occurs.
  task automatic check_stall(
    input string test_name,
    input completion_payload_t expected_payload
  );
    begin
      #1;
      if (cdb_valid !== 1'b1 ||
          cdb_payload !== expected_payload ||
          alu_ready !== 1'b0 ||
          mul_ready !== 1'b0 ||
          div_ready !== 1'b0 ||
          mem_ready !== 1'b0) begin
        $error("%s: handshake mismatch", test_name);
        errors++;
      end
    end
  endtask

  task automatic test_backpressure;
    begin
      reset_dut();

      @(negedge clk);

      alu_payload = '0;
      alu_payload.result = 32'haaaa_aaaa;
      mul_payload = '0;
      mul_payload.result = 32'hbbbb_bbbb;
      div_payload = '0;
      div_payload.result = 32'hcccc_cccc;

      alu_valid = 1'b1;
      mul_valid = 1'b1;
      div_valid = 1'b1;
      cdb_ready = 1'b0;

      check_stall("test_backpressure: initial stall", alu_payload);
      @(posedge clk);
      check_stall("test_backpressure: held across edge", alu_payload);
      @(negedge clk);

      cdb_ready = 1'b1;
      check_grant("test_backpressure: ALU grant after stall", alu_payload, 1'b1, 1'b0, 1'b0, 1'b0);
      check_grant("test_backpressure: MUL grant after stall", mul_payload, 1'b0, 1'b1, 1'b0, 1'b0);

      @(negedge clk);
      drive_idle();
    end
  endtask

  initial begin
    clk = 1'b0;
    errors = 0;
    drive_idle();

    reset_dut();
    test_single_producer();
    test_round_robin();
    test_backpressure();

    if (errors !== 0) begin
      $fatal(1, "rv32_cdb_arbiter_tb: %0d errors", errors);
    end
    $display("rv32_cdb_arbiter_tb: all directed checks passed");
    $finish;
  end

endmodule
