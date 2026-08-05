// SPDX-License-Identifier: Apache-2.0
//
// Self-checking testbench for the three-stage RV32M multiplier. Directed tests
// cover all four multiply operations, signedness boundaries, back-to-back
// throughput, bubbles, and reset behavior.

`timescale 1ns/1ps

module rv32_multiplier_tb;

  import rv32_pkg::*;

  logic        clk;
  logic        rst;
  logic        req_valid;
  logic        req_ready;
  muldiv_op_e  op;
  logic [31:0] lhs;
  logic [31:0] rhs;
  logic        resp_valid;
  logic [31:0] result;
  int unsigned errors;

  rv32_multiplier dut (
    .clk_i       (clk),
    .rst_i       (rst),
    .req_valid_i (req_valid),
    .req_ready_o (req_ready),
    .op_i        (op),
    .lhs_i       (lhs),
    .rhs_i       (rhs),
    .resp_valid_o(resp_valid),
    .result_o    (result)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Hold synchronous reset across a rising edge and check interface behavior.
  task automatic reset_dut();
    @(negedge clk);
    #1;
    rst = 1'b1;
    req_valid = 1'b0;
    @(posedge clk);
    #1;
    if (resp_valid !== 1'b0) begin
      $fatal(1, "reset failed: resp_valid should be 0");
    end
    if (req_ready !== 1'b0) begin
      $fatal(1, "reset failed: req_ready should be 0");
    end
    @(negedge clk);
    rst = 1'b0;
    #1;
    if (req_ready !== 1'b1) begin
      $fatal(1, "reset release failed: req_ready should be 1");
    end

    $display("reset_dut: PASS");
  endtask

  // Drive on falling edges to avoid races with the DUT's always_ff blocks.
  task automatic send_request(
    input muldiv_op_e request_op,
    input logic [31:0] request_lhs,
    input logic [31:0] request_rhs
  );
    begin
      @(negedge clk);
      #1;
      if (req_ready !== 1'b1) begin
        $fatal(1, "send_request failed: req_ready should be 1");
      end
      op = request_op;
      lhs = request_lhs;
      rhs = request_rhs;
      req_valid = 1'b1;
      @(posedge clk);
      #1;
      @(negedge clk);
      #1;
      req_valid = 1'b0;
      op = MD_NONE;
      lhs = 32'd0;
      rhs = 32'd0;
    end
  endtask
  // Check an isolated request's fixed three-cycle response latency and value.
  task automatic expect_response(
    input string test_name,
    input logic [31:0] expected_result
  );
    begin
      @(posedge clk);
      #1;
      if (resp_valid !== 1'b0) begin
        $error("%s failed: resp_valid should be 0 on cycle 1", test_name);
        errors++;
      end
      @(posedge clk);
      #1;
      if (resp_valid !== 1'b0) begin
        $error("%s failed: resp_valid should be 0 on cycle 2", test_name);
        errors++;
      end
      @(posedge clk);
      #1;
      if (resp_valid !== 1'b1) begin
        $error("%s failed: resp_valid should be 1 on cycle 3", test_name);
        errors++;
      end else if (result !== expected_result) begin
        $error("%s failed: expected result=%h, got=%h", test_name, expected_result, result);
        errors++;
      end
      @(posedge clk);
      #1;
      if (resp_valid !== 1'b0) begin
        $error("%s failed: resp_valid should be 0 on cycle 4", test_name);
        errors++;
      end
    end
  endtask

  task automatic pipeline_cycle(
    input string test_name,
    input logic send_valid,
    input muldiv_op_e request_op,
    input logic [31:0] request_lhs,
    input logic [31:0] request_rhs,
    input logic expected_valid,
    input logic [31:0] expected_result
  );
    begin
      @(negedge clk);
      #1;
      if (send_valid && req_ready !== 1'b1) begin
        $error("%s failed: req_ready should be 1", test_name);
        errors++;
      end
      req_valid = send_valid;
      if (send_valid) begin
        op = request_op;
        lhs = request_lhs;
        rhs = request_rhs;
      end else begin
        op = MD_NONE;
        lhs = 32'd0;
        rhs = 32'd0;
      end
      @(posedge clk);
      #1;
      if (resp_valid !== expected_valid) begin
        $error("%s failed: expected resp_valid=%b, got=%b", test_name, expected_valid, resp_valid);
        errors++;
      end else if (expected_valid && result !== expected_result) begin
        $error("%s failed: expected result=%h, got=%h", test_name, expected_result, result);
        errors++;
      end
    end
  endtask

  initial begin
    rst       = 1'b0;
    req_valid = 1'b0;
    op        = MD_NONE;
    lhs       = 32'd0;
    rhs       = 32'd0;
    errors    = 0;

    #1;
    reset_dut();

    // Directed arithmetic and signedness cases.
    send_request(MD_MUL, 32'd3, 32'd7);
    expect_response("MUL 3 * 7", 32'h0000_0015);
    send_request(MD_MUL, 32'hffff_ffff, 32'h0000_0002);
    expect_response("MUL -1 * 2", 32'hffff_fffe);
    send_request(MD_MUL, 32'h8000_0000, 32'h0000_0002);
    expect_response("MUL INT_MIN * 2", 32'h0000_0000);
    send_request(MD_MULH, 32'hffff_fffe, 32'h0000_0003);
    expect_response("MULH -2 * 3", 32'hffff_ffff);
    send_request(MD_MULH, 32'h8000_0000, 32'h8000_0000);
    expect_response("MULH INT_MIN * INT_MIN", 32'h4000_0000);
    send_request(MD_MULHSU, 32'hffff_fffe, 32'h0000_0003);
    expect_response("MULHSU -2 * 3", 32'hffff_ffff);
    send_request(MD_MULHSU, 32'hffff_ffff, 32'hffff_ffff);
    expect_response("MULHSU -1 * UINT_MAX", 32'hffff_ffff);
    send_request(MD_MULHU, 32'hffff_ffff, 32'hffff_ffff);
    expect_response("MULHU UINT_MAX * UINT_MAX", 32'hffff_fffe);

    // Four consecutive requests prove an initiation interval of one cycle.
    pipeline_cycle("Send A: MUL 3 * 7", 1'b1, MD_MUL, 32'd3, 32'd7, 1'b0, 32'd0);
    pipeline_cycle("Send B: MULH -2 * 3", 1'b1, MD_MULH, 32'hffff_fffe, 32'd3, 1'b0, 32'd0);
    pipeline_cycle("Send C: MULHSU -1 * UINT_MAX", 1'b1, MD_MULHSU, 32'hffff_ffff, 32'hffff_ffff, 1'b0, 32'd0);
    pipeline_cycle("Send D: MULHU UINT_MAX * UINT_MAX, Receive A", 1'b1, MD_MULHU, 32'hffff_ffff, 32'hffff_ffff, 1'b1, 32'h0000_0015);
    pipeline_cycle("Receive B", 1'b0, MD_NONE, 32'd0, 32'd0, 1'b1, 32'hffff_ffff);
    pipeline_cycle("Receive C", 1'b0, MD_NONE, 32'd0, 32'd0, 1'b1, 32'hffff_ffff);
    pipeline_cycle("Receive D", 1'b0, MD_NONE, 32'd0, 32'd0, 1'b1, 32'hffff_fffe);
    pipeline_cycle("Pipeline empty", 1'b0, MD_NONE, 32'd0, 32'd0, 1'b0, 32'd0);

    // Internal bubbles must emerge from resp_valid exactly three cycles later.
    pipeline_cycle("Bubble test: Send A", 1'b1, MD_MUL, 32'd9, 32'd9, 1'b0, 32'd0);
    pipeline_cycle("Bubble test: Bubble", 1'b0, MD_NONE, 32'd0, 32'd0, 1'b0, 32'd0);
    pipeline_cycle("Bubble test: Send B", 1'b1, MD_MULH, 32'h8000_0000, 32'h8000_0000, 1'b0, 32'd0);
    pipeline_cycle("Bubble test: Receive A", 1'b0, MD_NONE, 32'd0, 32'd0, 1'b1, 32'h0000_0051);
    pipeline_cycle("Bubble test: Send C, output bubble", 1'b1, MD_MULHU, 32'hffff_ffff, 32'h0000_0002, 1'b0, 32'd0);
    pipeline_cycle("Bubble test: Receive B", 1'b0, MD_NONE, 32'd0, 32'd0, 1'b1, 32'h4000_0000);
    pipeline_cycle("Bubble test: Bubble before C", 1'b0, MD_NONE, 32'd0, 32'd0, 1'b0, 32'd0);
    pipeline_cycle("Bubble test: Receive C", 1'b0, MD_NONE, 32'd0, 32'd0, 1'b1, 32'h0000_0001);
    pipeline_cycle("Bubble test: Pipeline empty", 1'b0, MD_NONE, 32'd0, 32'd0, 1'b0, 32'd0);
    if (errors != 0) begin
      $fatal(1, "rv32_multiplier_tb: %0d errors detected", errors);
    end
    $display("rv32_multiplier_tb: PASS");
    $finish;
  end

endmodule
