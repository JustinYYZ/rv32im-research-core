// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for Fetch Queue ordering, occupancy, simultaneous
// handshakes, pointer wrap-around, backpressure, and recovery Flush.

`timescale 1ns/1ps

module rv32_fetch_queue_tb;
  import rv32_ooo_pkg::*;

  logic                               clk;
  logic                               rst;
  logic                               flush;
  logic                               enq_valid;
  logic                               enq_ready;
  fetch_entry_t                       enq_entry;
  logic                               deq_valid;
  logic                               deq_ready;
  fetch_entry_t                       deq_entry;
  logic                               empty;
  logic                               full;
  logic [FETCH_QUEUE_COUNT_WIDTH-1:0] count;
  int unsigned                        errors;

  rv32_fetch_queue dut (
    .clk_i(clk),
    .rst_i(rst),
    .flush_i(flush),
    .enq_valid_i(enq_valid),
    .enq_ready_o(enq_ready),
    .enq_entry_i(enq_entry),
    .deq_valid_o(deq_valid),
    .deq_ready_i(deq_ready),
    .deq_entry_o(deq_entry),
    .empty_o(empty),
    .full_o(full),
    .count_o(count)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Common stimulus and status helpers keep every directed scenario independent.
  task automatic drive_idle;
    begin
      flush = 1'b0;
      enq_valid = 1'b0;
      enq_entry = '0;
      deq_ready = 1'b0;
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

  task automatic check_status(
    input string test_name,
    input logic expected_empty,
    input logic expected_full,
    input logic [FETCH_QUEUE_COUNT_WIDTH-1:0] expected_count,
    input logic expected_enq_ready,
    input logic expected_deq_valid
  );
    begin
      #1;
      if (empty !== expected_empty) begin
        $display("ERROR: %s: empty=%b, expected %b", test_name, empty, expected_empty);
        errors++;
      end
      if (full !== expected_full) begin
        $display("ERROR: %s: full=%b, expected %b", test_name, full, expected_full);
        errors++;
      end
      if (count !== expected_count) begin
        $display("ERROR: %s: count=%b, expected %b", test_name, count, expected_count);
        errors++;
      end
      if (enq_ready !== expected_enq_ready) begin
        $display("ERROR: %s: enq_ready=%b, expected %b", test_name, enq_ready, expected_enq_ready);
        errors++;
      end
      if (deq_valid !== expected_deq_valid) begin
        $display("ERROR: %s: deq_valid=%b, expected %b", test_name, deq_valid, expected_deq_valid);
        errors++;
      end
      if (!expected_deq_valid && deq_entry !== '0) begin
        $display("ERROR: %s: deq_entry=%h, expected 0", test_name, deq_entry);
        errors++;
      end
    end
  endtask

  // Single-operation helpers hold ready/valid inputs across the accepting edge.
  task automatic enqueue_one(
    input fetch_entry_t entry
  );
    begin
      @(negedge clk);
      flush = 1'b0;
      enq_valid = 1'b1;
      enq_entry = entry;
      deq_ready = 1'b0;
      #1;
      if (!enq_ready) begin
        $display("ERROR: enqueue_one: enq_ready=0, expected 1");
        errors++;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      enq_valid = 1'b0;
      enq_entry = '0;
    end
  endtask

  task automatic check_head(
    input string test_name,
    input fetch_entry_t expected_entry
  );
    begin
      #1;
      if (!deq_valid) begin
        $display("ERROR: %s: deq_valid=0, expected 1", test_name);
        errors++;
      end else if (deq_entry !== expected_entry) begin
        $display("ERROR: %s: deq_entry=%h, expected %h", test_name, deq_entry, expected_entry);
        errors++;
      end
    end
  endtask

  task automatic dequeue_one(
    input fetch_entry_t expected_entry
  );
    begin
      @(negedge clk);
      enq_valid = 1'b0;
      enq_entry = '0;
      deq_ready = 1'b1;
      #1;
      if (!deq_valid) begin
        $display("ERROR: dequeue_one: deq_valid=0, expected 1");
        errors++;
      end else if (deq_entry !== expected_entry) begin
        $display("ERROR: dequeue_one: deq_entry=%h, expected %h", deq_entry, expected_entry);
        errors++;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      deq_ready = 1'b0;
    end
  endtask

  // Distinct payloads expose ordering errors across physical pointer wraparound.
  function automatic fetch_entry_t make_entry(
    input int unsigned entry_number
  );
    fetch_entry_t entry;
    begin
      entry = '0;
      entry.pc = 32'h0000_1000 + (entry_number << 2);
      entry.instr = 32'h1000_0013 + entry_number;
      entry.predicted_next_pc = entry.pc + 32'h4;
      entry.access_fault = entry_number[0];
      make_entry = entry;
    end
  endfunction

  // Directed scenarios cover FIFO order, full backpressure, pointer wraparound,
  // full-Queue replacement, and recovery Flush priority.

  task automatic test_reset_state;
    begin
      reset_dut();
      check_status("test_reset_state", 1'b1, 1'b0, '0, 1'b1, 1'b0);
    end
  endtask

  task automatic test_single_enqueue;
    fetch_entry_t test_entry;
    begin
      reset_dut();

      test_entry = '0;
      test_entry.pc = 32'h0000_0100;
      test_entry.instr = 32'h0010_0093;
      test_entry.predicted_next_pc = 32'h0000_0104;
      test_entry.access_fault = 1'b0;

      enqueue_one(test_entry);
      check_status("test_single_enqueue", 1'b0, 1'b0, FETCH_QUEUE_COUNT_WIDTH'(1), 1'b1, 1'b1);
      check_head("test_single_enqueue", test_entry);
      dequeue_one(test_entry);
      check_status("test_single_enqueue", 1'b1, 1'b0, '0, 1'b1, 1'b0);
    end
  endtask

  task automatic test_full_backpressure;
    fetch_entry_t blocked_entry;
    int unsigned entry_number;
    begin
      reset_dut();
      for (entry_number = 0; entry_number < FETCH_QUEUE_ENTRIES; entry_number++) begin
        enqueue_one(make_entry(entry_number));
      end
      check_status("full queue", 1'b0, 1'b1, FETCH_QUEUE_COUNT_WIDTH'(FETCH_QUEUE_ENTRIES), 1'b0, 1'b1);
      check_head("full queue oldest entry", make_entry(0));
      blocked_entry = make_entry(FETCH_QUEUE_ENTRIES);
      @(negedge clk);
      enq_valid = 1'b1;
      enq_entry = blocked_entry;
      deq_ready = 1'b0;
      #1;
      if (enq_ready) begin
        $display("ERROR: full queue accepted a ninth entry");
        errors++;
      end
      @(posedge clk);
      #1;
      check_status("blocked ninth enqueue", 1'b0, 1'b1, FETCH_QUEUE_COUNT_WIDTH'(FETCH_QUEUE_ENTRIES), 1'b0, 1'b1);
      check_head("blocked enqueue preserves oldest entry", make_entry(0));

      @(negedge clk);
      enq_valid = 1'b0;
      enq_entry = '0;
    end
  endtask

  task automatic test_pointer_wraparound;
    int unsigned entry_number;
    begin
      reset_dut();
      for (entry_number = 0; entry_number < 6; entry_number++) begin
        enqueue_one(make_entry(entry_number));
      end
      check_status("before head advance", 1'b0, 1'b0, FETCH_QUEUE_COUNT_WIDTH'(6), 1'b1, 1'b1);

      for (entry_number = 0; entry_number < 4; entry_number++) begin
        dequeue_one(make_entry(entry_number));
      end
      check_status("before tail wraparound", 1'b0, 1'b0, FETCH_QUEUE_COUNT_WIDTH'(2), 1'b1, 1'b1);
      check_head("oldest entry before wraparound", make_entry(4));

      for (entry_number = 6; entry_number < 12; entry_number++) begin
        enqueue_one(make_entry(entry_number));
      end
      check_status("full after tail wraparound", 1'b0, 1'b1, FETCH_QUEUE_COUNT_WIDTH'(FETCH_QUEUE_ENTRIES), 1'b0, 1'b1);
      check_head("oldest entry after tail wraparound", make_entry(4));

      for (entry_number = 4; entry_number < 12; entry_number++) begin
        dequeue_one(make_entry(entry_number));
      end
      check_status("empty after head wraparound", 1'b1, 1'b0, '0, 1'b1, 1'b0);
    end
  endtask

  task automatic test_simultaneous_full_replace;
    fetch_entry_t replacement_entry;
    int unsigned entry_number;
    begin
      reset_dut();

      for (entry_number = 0; entry_number < FETCH_QUEUE_ENTRIES; entry_number++) begin
        enqueue_one(make_entry(entry_number));
      end
      replacement_entry = make_entry(FETCH_QUEUE_ENTRIES);

      @(negedge clk);
      enq_valid = 1'b1;
      enq_entry = replacement_entry;
      deq_ready = 1'b1;
      #1;
      check_status("full simultaneous handshakes", 1'b0, 1'b1, FETCH_QUEUE_COUNT_WIDTH'(FETCH_QUEUE_ENTRIES), 1'b1, 1'b1);
      check_head("entry removed during replacement", make_entry(0));

      @(posedge clk);
      #1;
      check_status("after full replacement", 1'b0, 1'b1, FETCH_QUEUE_COUNT_WIDTH'(FETCH_QUEUE_ENTRIES), 1'b1, 1'b1);
      check_head("head after full replacement", make_entry(1));

      @(negedge clk);
      enq_valid = 1'b0;
      enq_entry = '0;
      deq_ready = 1'b0;
      check_status("full after controls removed", 1'b0, 1'b1, FETCH_QUEUE_COUNT_WIDTH'(FETCH_QUEUE_ENTRIES), 1'b0, 1'b1);

      for (entry_number = 1; entry_number < FETCH_QUEUE_ENTRIES; entry_number++) begin
        dequeue_one(make_entry(entry_number));
      end
      dequeue_one(replacement_entry);

      check_status("empty after replacement drain", 1'b1, 1'b0, '0, 1'b1, 1'b0);
    end
  endtask

  task automatic test_flush_priority;
    fetch_entry_t incoming_entry;
    begin
      reset_dut();

      enqueue_one(make_entry(0));
      enqueue_one(make_entry(1));
      check_status("before flush", 1'b0, 1'b0, FETCH_QUEUE_COUNT_WIDTH'(2), 1'b1, 1'b1);
      check_head("oldest entry before flush", make_entry(0));
      incoming_entry = make_entry(2);

      @(negedge clk);
      flush = 1'b1;
      enq_valid = 1'b1;
      enq_entry = incoming_entry;
      deq_ready = 1'b1;
      #1;

      check_status("flush blocks handshakes", 1'b0, 1'b0, FETCH_QUEUE_COUNT_WIDTH'(2), 1'b0, 1'b0);

      @(posedge clk);
      #1;

      check_status("flush clears queue", 1'b1, 1'b0, '0, 1'b0, 1'b0);

      @(negedge clk);
      drive_idle();
      check_status("after flush deassertion", 1'b1, 1'b0, '0, 1'b1, 1'b0);

      enqueue_one(make_entry(3));
      check_head("first entry after flush", make_entry(3));
      dequeue_one(make_entry(3));
      check_status("empty after flush traffic", 1'b1, 1'b0, '0, 1'b1, 1'b0);
    end
  endtask

  initial begin
    rst = 1'b0;
    flush = 1'b0;
    enq_valid = 1'b0;
    enq_entry = '0;
    deq_ready = 1'b0;
    errors = 0;

    test_reset_state();
    test_single_enqueue();
    test_full_backpressure();
    test_pointer_wraparound();
    test_simultaneous_full_replace();
    test_flush_priority();

    if (errors !== 0) begin
      $fatal(1, "rv32_fetch_queue_tb: %0d errors detected", errors);
    end
    $display("rv32_fetch_queue_tb: All tests passed");
    $finish;
  end

endmodule
