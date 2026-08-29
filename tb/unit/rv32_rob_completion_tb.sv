// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for ROB completion writeback. The directed sequence
// completes a younger instruction before the head and verifies that results
// are stored by tag while architectural order remains unchanged.

`timescale 1ns/1ps

module rv32_rob_completion_tb;
  import rv32_ooo_pkg::*;

  localparam logic [31:0] RESULT_A = 32'h1234_5678;
  localparam logic [31:0] RESULT_B = 32'h89ab_cdef;

  logic                       clk;
  logic                       rst;
  logic                       alloc_valid;
  rob_alloc_payload_t         alloc_payload;
  logic                       alloc_ready;
  rob_tag_t                   alloc_tag;
  logic                       head_pop;
  logic                       head_valid;
  rob_tag_t                   head_tag;
  rob_entry_t                 head_entry;
  logic                       empty;
  logic                       full;
  logic [ROB_COUNT_WIDTH-1:0] count;

  logic                       complete_valid;
  rob_tag_t                   complete_tag;
  logic [31:0]                complete_result;

  rob_alloc_payload_t payload_a;
  rob_alloc_payload_t payload_b;
  rob_tag_t tag_a;
  rob_tag_t tag_b;
  rob_tag_t stale_tag;
  int unsigned errors;

  rv32_rob dut (
    .clk_i              (clk),
    .rst_i              (rst),
    .alloc_valid_i      (alloc_valid),
    .alloc_payload_i    (alloc_payload),
    .alloc_ready_o      (alloc_ready),
    .alloc_tag_o        (alloc_tag),
    .complete_valid_i   (complete_valid),
    .complete_tag_i     (complete_tag),
    .complete_result_i  (complete_result),
    .head_pop_i         (head_pop),
    .head_valid_o       (head_valid),
    .head_tag_o         (head_tag),
    .head_entry_o       (head_entry),
    .empty_o            (empty),
    .full_o             (full),
    .count_o            (count)
  );

  // Completion has no backpressure: a valid result is consumed on that edge.

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  task automatic reset_dut;
    begin
      @(negedge clk);
      rst = 1'b1;
      alloc_valid = 1'b0;
      head_pop = 1'b0;
      complete_valid = 1'b0;
      @(posedge clk);
      #1;
      rst = 1'b0;
    end
  endtask

  task automatic allocate_payload(
    input rob_alloc_payload_t payload,
    output rob_tag_t allocated_tag
  );
    begin
      @(negedge clk);
      head_pop = 1'b0;
      complete_valid = 1'b0;
      alloc_payload = payload;
      alloc_valid = 1'b1;
      #1;
      if (alloc_ready !== 1'b1) begin
        $display("allocate_payload: ERROR - ROB did not accept allocation");
        errors++;
        allocated_tag = 'x;
      end else begin
        allocated_tag = alloc_tag;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      alloc_valid = 1'b0;
      alloc_payload = '0;
    end
  endtask

  task automatic pop_head;
    begin
      @(negedge clk);
      alloc_valid = 1'b0;
      complete_valid = 1'b0;
      head_pop = 1'b1;
      #1;
      if (head_valid !== 1'b1) begin
        $display("pop_head: ERROR - ROB head is not valid");
        errors++;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      head_pop = 1'b0;
    end
  endtask

  // Hold tag, result, and valid stable across one accepting rising edge.
  task automatic send_completion(
    input rob_tag_t result_tag,
    input logic [31:0] result_value
  );
    begin
      @(negedge clk);
      alloc_valid = 1'b0;
      head_pop = 1'b0;
      complete_tag = result_tag;
      complete_result = result_value;
      complete_valid = 1'b1;
      @(posedge clk);
      #1;
      @(negedge clk);
      complete_valid = 1'b0;
      complete_tag = '0;
      complete_result = '0;
    end
  endtask

  // Case inequality makes unknown head-entry fields fail the check.
  task automatic check_head_entry(
    input string test_name,
    input rob_tag_t expected_tag,
    input rob_alloc_payload_t expected_payload,
    input logic expected_completed,
    input logic [31:0] expected_result
  );
    begin
      #1;
      if (head_valid !== 1'b1) begin
        $display("ERROR: %s: head_valid not high when expected", test_name);
        errors++;
      end
      if (head_tag !== expected_tag) begin
        $display("ERROR: %s: head_tag mismatch; got %p, expected %p", test_name, head_tag, expected_tag);
        errors++;
      end
      if (head_entry.valid !== 1'b1) begin
        $display("ERROR: %s: head_entry.valid not high when expected", test_name);
        errors++;
      end
      if (head_entry.completed !== expected_completed) begin
        $display("ERROR: %s: head_entry.completed mismatch; got %b, expected %b", test_name, head_entry.completed, expected_completed);
        errors++;
      end
      if (head_entry.generation !== expected_tag.generation) begin
        $display("ERROR: %s: head_entry.generation mismatch; got %b, expected %b", test_name, head_entry.generation, expected_tag.generation);
        errors++;
      end
      if (head_entry.payload !== expected_payload) begin
        $display("ERROR: %s: head_entry.payload mismatch; got %p, expected %p", test_name, head_entry.payload, expected_payload);
        errors++;
      end
      if (head_entry.result !== expected_result) begin
        $display("ERROR: %s: head_entry.result mismatch; got %p, expected %p", test_name, head_entry.result, expected_result);
        errors++;
      end
    end
  endtask

  initial begin
    rst = 1'b0;
    alloc_valid = 1'b0;
    alloc_payload = '0;
    head_pop = 1'b0;
    complete_valid = 1'b0;
    complete_tag = '0;
    complete_result = '0;
    errors = 0;

    payload_a.pc = 32'h0000_2000;
    payload_a.instr = 32'h0030_0193;
    payload_a.rd = 5'd3;
    payload_a.reg_write = 1'b1;

    payload_b.pc = 32'h0000_2004;
    payload_b.instr = 32'h0040_0213;
    payload_b.rd = 5'd4;
    payload_b.reg_write = 1'b1;

    reset_dut();

    // Establish two valid, incomplete entries with payload_a at the head.
    #1;
    if (head_valid !== 1'b0 || head_entry.valid !== 1'b0 ||
    count !== 0) begin
      $display("completion reset: ERROR - ROB should be empty");
      errors++;
    end
    allocate_payload(payload_a, tag_a);
    if (tag_a.generation !== 1'b0 || tag_a.index !== 0) begin
      $display("completion setup: ERROR - tag_a=%0b, expected 0:0", tag_a);
      errors++;
    end
    allocate_payload(payload_b, tag_b);
    if (tag_b.generation !== 1'b0 || tag_b.index !== 1) begin
      $display("completion setup: ERROR - tag_b=%0b, expected 0:1", tag_b);
      errors++;
    end
    check_head_entry("A before completion", tag_a, payload_a, 1'b0, 32'd0);
    if (count !== 2) begin
      $display("completion setup: ERROR - count=%0d, expected 2", count);
      errors++;
    end

    // Complete younger payload_b first without changing the visible head.
    send_completion(tag_b, RESULT_B);
    check_head_entry("A after B completion", tag_a, payload_a, 1'b0, 32'd0);
    if (count !== 2) begin
      $display("completion B: ERROR - count=%0d, expected 2", count);
      errors++;
    end

    // Completing payload_a updates its result without moving queue pointers.
    send_completion(tag_a, RESULT_A);
    check_head_entry("A after its completion", tag_a, payload_a, 1'b1, RESULT_A);
    if (count !== 2) begin
      $display("complete A: ERROR - count=%0d, expected 2", count);
      errors++;
    end
    if (alloc_tag.generation !== 1'b0 || alloc_tag.index !== 2) begin
      $display("complete A: ERROR - alloc_tag=%0b, expected 0:2", alloc_tag);
      errors++;
    end

    // After popping payload_a, payload_b exposes its earlier completion result.
    pop_head();
    check_head_entry("B after A pop", tag_b, payload_b, 1'b1, RESULT_B);
    if (count !== 1) begin
      $display("pop A: ERROR - count=%0d, expected 1", count);
      errors++;
    end
    if (alloc_tag.generation !== 1'b0 || alloc_tag.index !== 2) begin
      $display("pop A: ERROR - alloc_tag=%0b, expected 0:2", alloc_tag);
      errors++;
    end

    // A wrong-generation tag with B's index must not overwrite B's result.
    stale_tag.index = tag_b.index;
    stale_tag.generation = ~tag_b.generation;
    send_completion(stale_tag, 32'hdead_beef);
    check_head_entry("B after stale completion", tag_b, payload_b, 1'b1, RESULT_B);
    if (count !== 1) begin
      $display("stale completion: ERROR - count=%0d, expected 1", count);
      errors++;
    end

    if (errors != 0) begin
      $fatal(1, "rv32_rob_completion_tb: FAIL - %0d errors", errors);
    end
    $display("rv32_rob_completion_tb: out-of-order and stale-tag completion checks passed");
    $finish;
  end

endmodule
