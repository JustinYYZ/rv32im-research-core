// SPDX-License-Identifier: Apache-2.0
//
// Integration checks for multiplier metadata alignment, completion buffering,
// CDB backpressure, and recovery Flush. Multiplier arithmetic corner cases are
// covered by rv32_multiplier_tb.sv and are not repeated here.

`timescale 1ns/1ps

module rv32_ooo_multiplier_tb;
  import rv32_ooo_pkg::*;

  logic                clk;
  logic                rst;
  logic                flush;
  logic                issue_valid;
  logic                issue_ready;
  issue_uop_t          issue_uop;
  logic [31:0]         issue_lhs;
  logic [31:0]         issue_rhs;
  logic                completion_valid;
  logic                completion_ready;
  completion_payload_t completion_payload;
  int unsigned         errors;

  rv32_ooo_multiplier dut (
    .clk_i(clk),
    .rst_i(rst),
    .flush_i(flush),
    .issue_valid_i(issue_valid),
    .issue_ready_o(issue_ready),
    .issue_uop_i(issue_uop),
    .issue_lhs_i(issue_lhs),
    .issue_rhs_i(issue_rhs),
    .completion_valid_o(completion_valid),
    .completion_ready_i(completion_ready),
    .completion_payload_o(completion_payload)
  );

  always #5 clk = ~clk;

  task automatic drive_idle;
    begin
      rst = 1'b0;
      flush = 1'b0;
      issue_valid = 1'b0;
      issue_uop = '0;
      issue_lhs = '0;
      issue_rhs = '0;
      completion_ready = 1'b0;
    end
  endtask

  // Apply reset away from the active clock edge so testbench assignments do not
  // race the DUT's sequential logic.
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

  // Check one request's fixed latency and complete identity payload.
  task automatic test_single_mul;
    completion_payload_t expected_result;
    begin
      reset_dut();
      expected_result = '0;
      expected_result.rob_tag.generation = 1'b1;
      expected_result.rob_tag.index = ROB_INDEX_WIDTH'(3);
      expected_result.phys_rd = phys_reg_idx_t'(40);
      expected_result.rd_write = 1'b1;
      expected_result.result = 32'd63;
      expected_result.actual_next_pc = 32'h0000_0004;

      @(negedge clk);
      issue_uop = '0;
      issue_uop.pc = 32'h0000_0000;
      issue_uop.rob_tag = expected_result.rob_tag;
      issue_uop.phys_rd = expected_result.phys_rd;
      issue_uop.rd_write = 1'b1;
      issue_uop.muldiv_op = rv32_pkg::MD_MUL;
      issue_lhs = 32'd7;
      issue_rhs = 32'd9;
      issue_valid = 1'b1;
      completion_ready = 1'b0;
      #1;
      if (issue_ready !== 1'b1) begin
        $display("ERROR: issue_ready not asserted when expected");
        errors++;
      end
      @(posedge clk);
      #1;

      @(negedge clk);
      issue_valid = 1'b0;

      repeat(3) begin
        @(posedge clk);
        #1;
        if (completion_valid !== 1'b0) begin
          $error("ERROR: completion_valid asserted before multiplier latency");
          errors++;
        end
      end

      @(posedge clk);
      #1;

      if (completion_valid !== 1'b1) begin
        $error("ERROR: completion_valid not asserted after multiplier latency");
        errors++;
      end else if (completion_payload !== expected_result) begin
        $error("ERROR: completion_payload mismatch, expected: %p, received: %p", expected_result, completion_payload);
        errors++;
      end

      @(negedge clk);
      completion_ready = 1'b1;
      @(posedge clk);
      #1;

      if (completion_valid !== 1'b0 || issue_ready !== 1'b1) begin
        $error("ERROR: completion_valid did not clear or issue_ready did not recover after dequeue");
        errors++;
      end

      @(negedge clk);
      drive_idle();
    end
  endtask

  // Present one request before an active edge and confirm that the wrapper can
  // accept it. Calls may be consecutive because the multiplier is pipelined.
  task automatic issue_mul(
    input logic [ROB_INDEX_WIDTH-1:0] rob_index_i,
    input phys_reg_idx_t phys_rd_i,
    input logic [31:0] pc_i,
    input logic [31:0] lhs_i,
    input logic [31:0] rhs_i
  );
    begin
      @(negedge clk);
      issue_uop = '0;
      issue_uop.pc = pc_i;
      issue_uop.rob_tag.generation = 1'b1;
      issue_uop.rob_tag.index = rob_index_i;
      issue_uop.phys_rd = phys_rd_i;
      issue_uop.rd_write = 1'b1;
      issue_uop.muldiv_op = rv32_pkg::MD_MUL;
      issue_lhs = lhs_i;
      issue_rhs = rhs_i;
      issue_valid = 1'b1;
      completion_ready = 1'b0;
      #1;
      if (issue_ready !== 1'b1) begin
        $error("ERROR: issue_ready not asserted when expected for request %0d", rob_index_i);
        errors++;
      end
      @(posedge clk);
      #1;
    end
  endtask

  // Compare the current queue head, then release exactly that completion.
  task automatic expect_and_pop(
    input logic [ROB_INDEX_WIDTH-1:0] rob_index_i,
    input phys_reg_idx_t phys_rd_i,
    input logic [31:0] result_i,
    input logic [31:0] next_pc_i
  );
    completion_payload_t expected_result;
    begin
      expected_result = '0;
      expected_result.rob_tag.generation = 1'b1;
      expected_result.rob_tag.index = rob_index_i;
      expected_result.phys_rd = phys_rd_i;
      expected_result.rd_write = 1'b1;
      expected_result.result = result_i;
      expected_result.actual_next_pc = next_pc_i;

      if (completion_valid !== 1'b1) begin
        $error("ERROR: completion_valid not asserted when expected for request %0d", rob_index_i);
        errors++;
      end else if (completion_payload !== expected_result) begin
        $error("ERROR: completion_payload mismatch for request %0d, expected: %p, received: %p", rob_index_i, expected_result, completion_payload);
        errors++;
      end

      @(negedge clk);
      completion_ready = 1'b1;
      @(posedge clk);
      #1;
      completion_ready = 1'b0;
    end
  endtask

  // Fill all outstanding credits under CDB backpressure, then verify that the
  // four result and identity payloads emerge in Issue order.
  task automatic test_multiple_mul;
    begin
      reset_dut();
      issue_mul(0, 40, 32'h0000_0000, 32'd2, 32'd3);
      issue_mul(1, 41, 32'h0000_0004, 32'd4, 32'd5);
      issue_mul(2, 42, 32'h0000_0008, 32'd6, 32'd7);
      issue_mul(3, 43, 32'h0000_000C, 32'd8, 32'd9);

      issue_valid = 1'b0;

      if (issue_ready !== 1'b0) begin
        $error("ERROR: issue_ready asserted when no completion slots available");
        errors++;
      end

      repeat(4) begin
        @(posedge clk);
        #1;
      end

      expect_and_pop(0, 40, 32'd6, 32'h0000_0004);
      expect_and_pop(1, 41, 32'd20, 32'h0000_0008);
      expect_and_pop(2, 42, 32'd42, 32'h0000_000C);
      expect_and_pop(3, 43, 32'd72, 32'h0000_0010);

      if (completion_valid !== 1'b0 || issue_ready !== 1'b1) begin
        $error("ERROR: completion_valid did not clear or issue_ready did not recover after draining completions");
        errors++;
      end

      @(negedge clk);
      drive_idle();
    end
  endtask

  // Flush one queued result and one following in-flight result together. Neither
  // old-path completion may reappear after the wrapper resumes accepting work.
  task automatic test_flush;
    begin
      reset_dut();
      issue_mul(4, 44, 32'h0000_0100, 32'd11, 32'd12);
      issue_mul(5, 45, 32'h0000_0104, 32'd13, 32'd14);
      issue_valid = 1'b0;

      repeat(3) begin
        @(posedge clk);
        #1;
      end

      if (completion_valid !== 1'b1) begin
        $error("ERROR: completion_valid not asserted before Flush");
        errors++;
      end

      @(negedge clk);
      flush = 1'b1;
      @(posedge clk);
      #1;

      if (completion_valid !== 1'b0) begin
        $error("ERROR: completion_valid asserted during Flush");
        errors++;
      end

      @(negedge clk);
      flush = 1'b0;
      #1;

      if (issue_ready !== 1'b1) begin
        $error("ERROR: issue_ready did not recover after Flush");
        errors++;
      end

      repeat(5) begin
        @(posedge clk);
        #1;
        if (completion_valid !== 1'b0) begin
          $error("ERROR: completion_valid asserted after Flush");
          errors++;
        end
      end

      if (issue_ready !== 1'b1) begin
        $error("ERROR: issue_ready not recovered after Flush");
        errors++;
      end

      @(negedge clk);
      drive_idle();
    end
  endtask

  initial begin
    clk = 1'b0;
    errors = 0;
    drive_idle();
    test_single_mul();
    test_multiple_mul();
    test_flush();

    if (errors !== 0) begin
      $fatal(1, "rv32_ooo_multiplier_tb: %0d errors detected", errors);
    end
    $display("rv32_ooo_multiplier_tb: all tests passed");
    $finish;
  end

endmodule
