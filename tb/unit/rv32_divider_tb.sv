// SPDX-License-Identifier: Apache-2.0
//
// Self-checking testbench for the multi-cycle RV32M divider. Directed tests
// cover DIV, DIVU, REM, REMU, all signed operand combinations, RISC-V corner
// cases, fixed iteration latency, response pulse width, and reset while busy.

`timescale 1ns/1ps

module rv32_divider_tb;

  import rv32_pkg::*;

  logic       clk;
  logic       rst;
  logic       req_valid;
  logic       req_ready;
  muldiv_op_e op;
  logic [31:0] lhs;
  logic [31:0] rhs;
  logic       resp_valid;
  logic [31:0] result;
  int unsigned errors;

  rv32_divider dut (
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
  task automatic reset_dut;
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

  // Drive on falling edges to avoid races with the DUT's always_ff block.
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

  // A normal request performs 32 RUN updates, pulses resp_valid for one cycle,
  // and returns to IDLE on the following edge.
  task automatic expect_normal_response(
    input string test_name,
    input logic [31:0] expected_result
  );
    begin
      for (int cycle = 1; cycle <= 31; cycle++) begin
        @(posedge clk);
        #1;
        if (resp_valid !== 1'b0) begin
          $error("%s failed: resp_valid should be 0 on cycle %0d", test_name, cycle);
          errors++;
        end
        if (req_ready !== 1'b0) begin
          $error("%s failed: req_ready should be 0 on cycle %0d", test_name, cycle);
          errors++;
        end
      end
      @(posedge clk);
      #1;
      if (resp_valid !== 1'b1) begin
        $error("%s failed: resp_valid should be 1 on cycle 32", test_name);
        errors++;
      end
      if (req_ready !== 1'b0) begin
        $error("%s failed: req_ready should be 0 on cycle 32", test_name);
        errors++;
      end
      if (result !== expected_result) begin
        $error("%s failed: expected result=%h, got=%h", test_name, expected_result, result);
        errors++;
      end
      @(posedge clk);
      #1;
      if (resp_valid !== 1'b0) begin
        $error("%s failed: resp_valid should be 0 on cycle 33", test_name);
        errors++;
      end
      if (req_ready !== 1'b1) begin
        $error("%s failed: req_ready should be 1 on cycle 33", test_name);
        errors++;
      end
    end
  endtask

  // Architectural corner cases bypass RUN and enter RESPOND on acceptance.
  task automatic expect_special_response(
    input string test_name,
    input logic [31:0] expected_result
  );
    begin
      if (resp_valid !== 1'b1) begin
        $error("%s failed: resp_valid should be 1 on cycle 1", test_name);
        errors++;
      end
      if (req_ready !== 1'b0) begin
        $error("%s failed: req_ready should be 0 on cycle 1", test_name);
        errors++;
      end
      if (result !== expected_result) begin
        $error("%s failed: expected result=%h, got=%h", test_name, expected_result, result);
        errors++;
      end
      @(posedge clk);
      #1;
      if (resp_valid !== 1'b0) begin
        $error("%s failed: resp_valid should be 0 on cycle 2", test_name);
        errors++;
      end
      if (req_ready !== 1'b1) begin
        $error("%s failed: req_ready should be 1 on cycle 2", test_name);
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

    // Raw corner-case inputs must not affect an idle unit without a handshake.
    repeat (2) begin
      @(posedge clk);
      #1;
      if (req_ready !== 1'b1 || resp_valid !== 1'b0) begin
        $error("divider should remain IDLE without an accepted request");
        errors++;
      end
    end

    // Signed quotient truncates toward zero; remainder follows lhs sign.
    send_request(MD_DIV, 32'd13, 32'd3);
    expect_normal_response("DIV 13 / 3", 32'd4);
    send_request(MD_REM, 32'd13, 32'd3);
    expect_normal_response("REM 13 % 3", 32'd1);

    send_request(MD_DIV, 32'hffff_fff3, 32'd3);
    expect_normal_response("DIV -13 / 3", 32'hffff_fffc);
    send_request(MD_REM, 32'hffff_fff3, 32'd3);
    expect_normal_response("REM -13 % 3", 32'hffff_ffff);

    send_request(MD_DIV, 32'd13, 32'hffff_fffd);
    expect_normal_response("DIV 13 / -3", 32'hffff_fffc);
    send_request(MD_REM, 32'd13, 32'hffff_fffd);
    expect_normal_response("REM 13 % -3", 32'd1);

    send_request(MD_DIV, 32'hffff_fff3, 32'hffff_fffd);
    expect_normal_response("DIV -13 / -3", 32'd4);
    send_request(MD_REM, 32'hffff_fff3, 32'hffff_fffd);
    expect_normal_response("REM -13 % -3", 32'hffff_ffff);

    // Unsigned cases cover dividend<divisor, zero, and the 32-bit boundary.
    send_request(MD_DIVU, 32'd7, 32'd9);
    expect_normal_response("DIVU 7 / 9", 32'd0);
    send_request(MD_REMU, 32'd7, 32'd9);
    expect_normal_response("REMU 7 % 9", 32'd7);
    send_request(MD_DIVU, 32'd0, 32'd5);
    expect_normal_response("DIVU 0 / 5", 32'd0);
    send_request(MD_REMU, 32'd0, 32'd5);
    expect_normal_response("REMU 0 % 5", 32'd0);
    send_request(MD_DIVU, 32'hffff_ffff, 32'd2);
    expect_normal_response("DIVU UINT_MAX / 2", 32'h7fff_ffff);
    send_request(MD_REMU, 32'hffff_ffff, 32'd2);
    expect_normal_response("REMU UINT_MAX % 2", 32'd1);

    // The ISA defines results for divide by zero and signed overflow.
    send_request(MD_DIV, 32'hffff_fff3, 32'd0);
    expect_special_response("DIV by zero", 32'hffff_ffff);
    send_request(MD_DIVU, 32'h8000_0000, 32'd0);
    expect_special_response("DIVU by zero", 32'hffff_ffff);
    send_request(MD_REM, 32'hffff_fff3, 32'd0);
    expect_special_response("REM by zero", 32'hffff_fff3);
    send_request(MD_REMU, 32'hffff_ffff, 32'd0);
    expect_special_response("REMU by zero", 32'hffff_ffff);
    send_request(MD_DIV, 32'h8000_0000, 32'hffff_ffff);
    expect_special_response("DIV INT_MIN / -1", 32'h8000_0000);
    send_request(MD_REM, 32'h8000_0000, 32'hffff_ffff);
    expect_special_response("REM INT_MIN / -1", 32'd0);

    // Reset must cancel an in-flight request and restore acceptance cleanly.
    send_request(MD_DIVU, 32'd100, 32'd7);
    repeat (5) begin
      @(posedge clk);
      #1;
      if (req_ready !== 1'b0) begin
        $error("busy reset test: req_ready should remain 0 before reset");
        errors++;
      end
      if (resp_valid !== 1'b0) begin
        $error("busy reset test: response arrived before reset");
        errors++;
      end
    end
    reset_dut();
    send_request(MD_DIVU, 32'd20, 32'd3);
    expect_normal_response("request after busy reset", 32'd6);

    if(errors != 0) begin
      $fatal(1, "rv32_divider_tb: %0d errors detected", errors);
    end
    $display("rv32_divider_tb: PASS");
    $finish;
  end

endmodule
