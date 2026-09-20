// SPDX-License-Identifier: Apache-2.0
//
// Directed unit test for the one-entry registered ALU completion buffer.

`timescale 1ns/1ps

module rv32_completion_buffer_tb;
  import rv32_ooo_pkg::*;

  logic                         clk;
  logic                         rst;
  logic                         flush;
  logic                         execute_valid;
  logic                         execute_ready;
  rob_tag_t                     execute_rob_tag;
  phys_reg_idx_t                execute_phys_rd;
  logic                         execute_rd_write;
  logic [31:0]                  execute_result;
  logic                         cdb_valid;
  logic                         cdb_ready;
  rob_tag_t                     cdb_rob_tag;
  phys_reg_idx_t                cdb_phys_rd;
  logic                         cdb_rd_write;
  logic [31:0]                  cdb_result;
  int unsigned                  errors;

  rv32_completion_buffer dut (
    .clk_i(clk),
    .rst_i(rst),
    .flush_i(flush),
    .execute_valid_i(execute_valid),
    .execute_ready_o(execute_ready),
    .execute_rob_tag_i(execute_rob_tag),
    .execute_phys_rd_i(execute_phys_rd),
    .execute_rd_write_i(execute_rd_write),
    .execute_result_i(execute_result),
    .execute_actual_next_pc_i(32'b0),
    .cdb_valid_o(cdb_valid),
    .cdb_ready_i(cdb_ready),
    .cdb_rob_tag_o(cdb_rob_tag),
    .cdb_phys_rd_o(cdb_phys_rd),
    .cdb_rd_write_o(cdb_rd_write),
    .cdb_result_o(cdb_result),
    .cdb_actual_next_pc_o()
  );

  // Reset and empty-buffer behavior.
  task automatic drive_idle;
    begin
      rst = 1'b0;
      flush = 1'b0;
      execute_valid = 1'b0;
      execute_rob_tag = '0;
      execute_phys_rd = '0;
      execute_rd_write = 1'b0;
      execute_result = '0;
      cdb_ready = 1'b0;
    end
  endtask

  task automatic drive_completion(
    input logic test_generation,
    input logic [ROB_INDEX_WIDTH-1:0] test_rob_index,
    input phys_reg_idx_t test_phys_rd,
    input logic test_rd_write,
    input logic [31:0] test_result
  );
    begin
      execute_valid = 1'b1;
      execute_rob_tag.generation = test_generation;
      execute_rob_tag.index = test_rob_index;
      execute_phys_rd = test_phys_rd;
      execute_rd_write = test_rd_write;
      execute_result = test_result;
    end
  endtask

  task automatic test_reset_empty;
    begin
      drive_idle();
      rst = 1'b1;
      #1;
      if (execute_ready !== 1'b0 || cdb_valid !== 1'b0) begin
        $display("rv32_completion_buffer_tb: ERROR: reset did not empty the buffer");
        errors++;
      end

      @(posedge clk);
      #1;
      rst = 1'b0;
      #1;

      if (execute_ready !== 1'b1 || cdb_valid !== 1'b0) begin
        $display("rv32_completion_buffer_tb: ERROR: buffer not empty after reset release");
        errors++;
      end
    end
  endtask
  // A new completion becomes visible only after its accepting edge.
  task automatic test_single_completion;
    rob_tag_t expected_tag;
    begin
      expected_tag.generation = 1'b1;
      expected_tag.index = ROB_INDEX_WIDTH'(4);

      execute_valid = 1'b1;
      execute_rob_tag = expected_tag;
      execute_phys_rd = phys_reg_idx_t'(20);
      execute_rd_write = 1'b1;
      execute_result = 32'haaaa_bbbb;
      cdb_ready = 1'b0;

      #1;

      if (execute_ready !== 1'b1 || cdb_valid !== 1'b0) begin
        $display("rv32_completion_buffer_tb: ERROR: buffer did not accept the completion");
        errors++;
      end

      @(posedge clk);
      #1;
      execute_valid = 1'b0;

      if (cdb_valid !== 1'b1 || cdb_rob_tag !== expected_tag || cdb_phys_rd !== phys_reg_idx_t'(20) || cdb_rd_write !== 1'b1 || cdb_result !== 32'haaaa_bbbb) begin
        $display("rv32_completion_buffer_tb: ERROR: buffer did not present the completion on the CDB");
        errors++;
      end

      if (execute_ready !== 1'b0) begin
        $display("rv32_completion_buffer_tb: ERROR: buffer did not deassert ready after accepting a completion");
        errors++;
      end
    end
  endtask
  // CDB backpressure must preserve the complete registered payload.
  task automatic test_cdb_stall;
    rob_tag_t held_rob_tag;
    phys_reg_idx_t held_phys_rd;
    logic held_rd_write;
    logic [31:0] held_result;
    begin
      held_rob_tag = cdb_rob_tag;
      held_phys_rd = cdb_phys_rd;
      held_rd_write = cdb_rd_write;
      held_result = cdb_result;

      execute_valid = 1'b1;
      execute_rob_tag.generation = 1'b0;
      execute_rob_tag.index = ROB_INDEX_WIDTH'(7);
      execute_phys_rd = phys_reg_idx_t'(31);
      execute_rd_write = 1'b1;
      execute_result = 32'hdead_beef;
      cdb_ready = 1'b0;

      repeat (3) begin
        @(posedge clk);
        #1;
        if (execute_ready !== 1'b0 ||
            cdb_valid !== 1'b1 ||
            cdb_rob_tag !== held_rob_tag ||
            cdb_phys_rd !== held_phys_rd ||
            cdb_rd_write !== held_rd_write ||
            cdb_result !== held_result) begin
          $error("CDB stall: buffered completion changed");
          errors++;
        end
      end

      execute_valid = 1'b0;
    end
  endtask
  // Ordinary consumption and bubble-free consume-and-replace behavior.
  task automatic test_consume_and_replace;
    rob_tag_t tag_b;
    rob_tag_t tag_c;
    begin
      tag_b.generation = 1'b0;
      tag_b.index = ROB_INDEX_WIDTH'(2);
      tag_c.generation = 1'b1;
      tag_c.index = ROB_INDEX_WIDTH'(3);

      execute_valid = 1'b0;
      cdb_ready = 1'b1;
      #1;
      if (execute_ready !== 1'b1 || cdb_valid !== 1'b1) begin
        $error("consume: ready/valid mismatch");
        errors++;
      end

      @(posedge clk);
      #1;

      if (execute_ready !== 1'b1 || cdb_valid !== 1'b0) begin
        $error("consume: valid not deasserted after CDB consume");
        errors++;
      end

      cdb_ready = 1'b0;
      drive_completion(1'b0, ROB_INDEX_WIDTH'(2), phys_reg_idx_t'(10), 1'b1, 32'h1111_1111);

      @(posedge clk);
      #1;
      execute_valid = 1'b0;

      if (cdb_valid !== 1'b1 || cdb_rob_tag !== tag_b || cdb_phys_rd !== phys_reg_idx_t'(10) || cdb_result !== 32'h1111_1111) begin
        $error("replace: buffered completion mismatch");
        errors++;
      end

      drive_completion(1'b1, ROB_INDEX_WIDTH'(3), phys_reg_idx_t'(20), 1'b1, 32'h2222_2222);
      cdb_ready = 1'b1;
      #1;

      if (execute_ready !== 1'b1 || cdb_valid !== 1'b1 || cdb_rob_tag !== tag_b || cdb_phys_rd !== phys_reg_idx_t'(10) || cdb_result !== 32'h1111_1111) begin
        $error("consume-and-replace: buffered completion mismatch");
        errors++;
      end

      @(posedge clk);
      #1;
      execute_valid = 1'b0;
      cdb_ready = 1'b0;

      if (cdb_valid !== 1'b1 || cdb_rob_tag !== tag_c || cdb_phys_rd !== phys_reg_idx_t'(20) || cdb_result !== 32'h2222_2222) begin
        $error("consume-and-replace: buffered completion mismatch after clock edge");
        errors++;
      end
    end
  endtask
  // Flush invalidation and a ROB-only completion without physical writeback.
  task automatic test_flush_and_no_destination;
    rob_tag_t expected_tag;

    begin
      flush = 1'b1;
      #1;

      if (execute_ready !== 1'b0 || cdb_valid !== 1'b0) begin
        $error("Flush did not suppress Completion Buffer interfaces");
        errors++;
      end

      @(posedge clk);
      #1;
      flush = 1'b0;
      #1;

      if (execute_ready !== 1'b1 || cdb_valid !== 1'b0) begin
        $error("Flush did not empty Completion Buffer");
        errors++;
      end

      expected_tag.generation = 1'b0;
      expected_tag.index = ROB_INDEX_WIDTH'(9);

      drive_completion(
        expected_tag.generation,
        expected_tag.index,
        '0,
        1'b0,
        32'h1234_5678
      );
      cdb_ready = 1'b0;

      @(posedge clk);
      #1;
      execute_valid = 1'b0;

      if (cdb_valid !== 1'b1 ||
          cdb_rob_tag !== expected_tag ||
          cdb_phys_rd !== '0 ||
          cdb_rd_write !== 1'b0 ||
          cdb_result !== 32'h1234_5678) begin
        $error("no-destination completion payload mismatch");
        errors++;
      end

      cdb_ready = 1'b1;
      @(posedge clk);
      #1;

      if (cdb_valid !== 1'b0 || execute_ready !== 1'b1) begin
        $error("final completion was not consumed");
        errors++;
      end
    end
  endtask

  initial clk = 1'b0;
  always #5 clk = ~clk;

  initial begin
    errors = 0;
    drive_idle();
    test_reset_empty();
    test_single_completion();
    test_cdb_stall();
    test_consume_and_replace();
    test_flush_and_no_destination();

    if (errors !== 0) begin
      $fatal(1, "rv32_completion_buffer_tb: %0d errors detected", errors);
    end
    $display("rv32_completion_buffer_tb: all tests passed");
    $finish;
  end

endmodule
