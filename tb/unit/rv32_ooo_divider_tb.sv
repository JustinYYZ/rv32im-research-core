// SPDX-License-Identifier: Apache-2.0
//
// Directed checks for divider identity retention, completion backpressure, and
// recovery. Arithmetic corner cases remain covered by rv32_divider_tb.sv.

`timescale 1ns/1ps

module rv32_ooo_divider_tb;
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

  rv32_ooo_divider dut (
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

  task automatic test_single_div;
    completion_payload_t expected_result;
    int unsigned wait_cycles;
    begin
      // Check a complete DIV request, including its saved identity. The bounded
      // wait allows normal iterative execution without assuming an exact cycle.
      reset_dut();

      expected_result = '0;
      expected_result.rob_tag.generation = 1'b1;
      expected_result.rob_tag.index = ROB_INDEX_WIDTH'(3);
      expected_result.phys_rd = phys_reg_idx_t'(40);
      expected_result.rd_write = 1'b1;
      expected_result.result = 32'h0000_000e;
      expected_result.actual_next_pc = 32'h0000_0104;

      @(negedge clk);
      issue_uop = '0;
      issue_uop.pc = 32'h0000_0100;
      issue_uop.muldiv_op = rv32_pkg::MD_DIV;
      issue_uop.rob_tag = expected_result.rob_tag;
      issue_uop.phys_rd = expected_result.phys_rd;
      issue_uop.rd_write = expected_result.rd_write;
      issue_lhs = 32'd100;
      issue_rhs = 32'd7;
      issue_valid = 1'b1;
      completion_ready = 1'b0;
      #1;
      if (issue_ready !== 1'b1) begin
        $error("rv32_ooo_divider_tb: issue_ready should be high when issuing a request");
        errors++;
      end

      @(negedge clk);
      issue_valid = 1'b0;

      wait_cycles = 0;
      while (completion_valid !== 1'b1 && wait_cycles < 50) begin
        @(posedge clk);
        #1;
        wait_cycles++;
        if (issue_ready !== 1'b0) begin
          $error("rv32_ooo_divider_tb: issue_ready should be low while request is active");
          errors++;
        end
      end

      if (completion_valid !== 1'b1) begin
        $error("rv32_ooo_divider_tb: completion_valid should be high after request completes");
        errors++;
      end
      if (completion_payload !== expected_result) begin
        $error("rv32_ooo_divider_tb: completion_payload mismatch");
        $error("rv32_ooo_divider_tb: expected payload 0x%h", expected_result);
        $error("rv32_ooo_divider_tb: received payload 0x%h", completion_payload);
        errors++;
      end

      @(negedge clk);
      completion_ready = 1'b1;
      @(posedge clk);
      #1;
      if (completion_valid !== 1'b0 || issue_ready !== 1'b1) begin
        $error("rv32_ooo_divider_tb: completion_valid should be low and issue_ready should be high after consuming a completion");
        errors++;
      end
      @(negedge clk);
      drive_idle();
    end
  endtask

  task automatic test_completion_backpressure;
    completion_payload_t expected_result;
    int unsigned wait_cycles;
    begin
      // Hold a completed result for three cycles and check its full payload.
      // New requests remain blocked until the CDB consumes the held result.
      reset_dut();
      expected_result = '0;
      expected_result.rob_tag.generation = 1'b1;
      expected_result.rob_tag.index = ROB_INDEX_WIDTH'(4);
      expected_result.phys_rd = phys_reg_idx_t'(41);
      expected_result.rd_write = 1'b1;
      expected_result.result = 32'h0000_000e;
      expected_result.actual_next_pc = 32'h0000_0204;

      @(negedge clk);
      issue_uop = '0;
      issue_uop.pc = 32'h0000_0200;
      issue_uop.muldiv_op = rv32_pkg::MD_DIV;
      issue_uop.rob_tag = expected_result.rob_tag;
      issue_uop.phys_rd = expected_result.phys_rd;
      issue_uop.rd_write = expected_result.rd_write;
      issue_lhs = 32'd100;
      issue_rhs = 32'd7;
      issue_valid = 1'b1;
      completion_ready = 1'b0;
      #1;

      if (issue_ready !== 1'b1) begin
        $error("rv32_ooo_divider_tb: issue_ready should be high when issuing a request");
        errors++;
      end
      @(negedge clk);
      issue_valid = 1'b0;

      wait_cycles = 0;
      while (completion_valid !== 1'b1 && wait_cycles < 50) begin
        @(posedge clk);
        #1;
        wait_cycles++;
      end

      if (completion_valid !== 1'b1) begin
        $error("rv32_ooo_divider_tb: completion_valid should be high after request completes");
        errors++;
      end
      if (completion_payload !== expected_result) begin
        $error("rv32_ooo_divider_tb: completion_payload mismatch");
        errors++;
      end

      repeat (3) begin
        @(posedge clk);
        #1;
        if (completion_valid !== 1'b1 || completion_payload !== expected_result || issue_ready !== 1'b0) begin
          $error("rv32_ooo_divider_tb: completion_valid and payload should remain stable while backpressured, and issue_ready should be low");
          errors++;
        end
      end

      @(negedge clk);
      completion_ready = 1'b1;
      @(posedge clk);
      #1;

      if (completion_valid !== 1'b0 || issue_ready !== 1'b1) begin
        $error("rv32_ooo_divider_tb: completion_valid should be low and issue_ready should be high after consuming a completion");
        errors++;
      end

      @(negedge clk);
      drive_idle();
    end
  endtask

  task automatic test_flush;
    int unsigned wait_cycles;
    begin
      // Cancel an active divide, then a held completion without an intervening
      // reset. The second request also checks acceptance after recovery.
      reset_dut();

      for (int scenario = 0; scenario < 2; scenario++) begin
        @(negedge clk);
        issue_uop = '0;
        issue_uop.pc = 32'h0000_0300;
        issue_uop.muldiv_op = rv32_pkg::MD_DIV;
        issue_uop.rob_tag.generation = 1'b1;
        issue_uop.rob_tag.index = ROB_INDEX_WIDTH'(5 + scenario);
        issue_uop.phys_rd = phys_reg_idx_t'(42 + scenario);
        issue_uop.rd_write = 1'b1;
        issue_lhs = 32'd100;
        issue_rhs = 32'd7;
        issue_valid = 1'b1;
        completion_ready = 1'b0;
        #1;

        if (issue_ready !== 1'b1) begin
          $error("rv32_ooo_divider_tb: issue_ready should be high when issuing a request");
          errors++;
        end
        @(negedge clk);
        issue_valid = 1'b0;

        if (scenario == 0) begin
          repeat (3) begin
            @(posedge clk);
            #1;
          end

          if (completion_valid !== 1'b0 || issue_ready !== 1'b0) begin
            $error("rv32_ooo_divider_tb: expected an active division before flush");
            errors++;
          end
        end else begin
          wait_cycles = 0;
          while (completion_valid !== 1'b1 && wait_cycles < 50) begin
            @(posedge clk);
            #1;
            wait_cycles++;
          end

          if (completion_valid !== 1'b1) begin
            $error("rv32_ooo_divider_tb: expected a completed division before flush");
            errors++;
          end
        end

        @(negedge clk);
        flush = 1'b1;
        @(posedge clk);
        #1;

        if (completion_valid !== 1'b0 || issue_ready !== 1'b0) begin
          $error("rv32_ooo_divider_tb: completion_valid and issue_ready should be low during flush");
          errors++;
        end

        @(negedge clk);
        flush = 1'b0;
        #1;

        if (completion_valid !== 1'b0 || issue_ready !== 1'b1) begin
          $error("rv32_ooo_divider_tb: completion_valid should be low and issue_ready should be high after flush recovery");
          errors++;
        end

        // An active divide must not reappear even after its normal completion
        // time. A held result must remain cleared after Flush is released.
        repeat (scenario == 0 ? 40 : 3) begin
          @(posedge clk);
          #1;
          if (completion_valid !== 1'b0 || issue_ready !== 1'b1) begin
            $error("rv32_ooo_divider_tb: completion_valid should remain low and issue_ready should remain high after flush recovery");
            errors++;
          end
        end

        @(negedge clk);
        drive_idle();
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    errors = 0;
    drive_idle();
    test_single_div();
    test_completion_backpressure();
    test_flush();
    if (errors !== 0) begin
      $fatal(1, "rv32_ooo_divider_tb: %0d errors found", errors);
    end
    $display("rv32_ooo_divider_tb: single DIV, backpressure, and flush tests passed");
    $finish;
  end

endmodule
