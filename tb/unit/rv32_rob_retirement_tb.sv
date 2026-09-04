// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for in-order ROB retirement. This testbench focuses
// on retirement eligibility and ready/valid backpressure rather than queue
// capacity, payload storage, or stale completion tags.

`timescale 1ns/1ps

module rv32_rob_retirement_tb;
  import rv32_ooo_pkg::*;

  localparam logic [31:0] RESULT_A = 32'h1111_1111;
  localparam logic [31:0] RESULT_B = 32'h2222_2222;

  logic                       clk;
  logic                       rst;
  logic                       alloc_valid;
  rob_alloc_payload_t         alloc_payload;
  logic                       alloc_ready;
  rob_tag_t                   alloc_tag;
  logic                       complete_valid;
  rob_tag_t                   complete_tag;
  logic [31:0]                complete_result;
  logic                       retire_ready;
  logic                       retire_valid;
  logic                       head_valid;
  rob_tag_t                   head_tag;
  rob_entry_t                 head_entry;
  logic                       empty;
  logic                       full;
  logic [ROB_COUNT_WIDTH-1:0] count;

  rob_alloc_payload_t payload_a;
  rob_alloc_payload_t payload_b;
  rob_tag_t tag_a;
  rob_tag_t tag_b;
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
    .retire_ready_i     (retire_ready),
    .retire_valid_o     (retire_valid),
    .head_valid_o       (head_valid),
    .head_tag_o         (head_tag),
    .head_entry_o       (head_entry),
    .empty_o            (empty),
    .full_o             (full),
    .count_o            (count)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  task automatic reset_dut;
    begin
      // Apply synchronous reset with every request interface inactive, then
      // verify that neither a Head entry nor a retirement candidate is visible.
      @(negedge clk);
      rst = 1'b1;
      alloc_valid = 1'b0;
      complete_valid = 1'b0;
      retire_ready = 1'b0;
      @(posedge clk);
      #1;
      rst = 1'b0;
      if (empty !== 1'b1 || count !== 0 || head_valid !== 1'b0 || retire_valid !== 1'b0) begin
        $display("reset: ERROR - empty=%0b count=%0d head_valid=%0b retire_valid=%0b", empty, count, head_valid, retire_valid);
        errors++;
      end
    end
  endtask

  task automatic allocate_payload(
    input rob_alloc_payload_t payload,
    output rob_tag_t allocated_tag
  );
    begin
      allocated_tag = '0;
      // Capture alloc_tag before the accepting edge advances the tail and
      // exposes the following free tag.
      @(negedge clk);
      complete_valid = 1'b0;
      retire_ready = 1'b0;
      alloc_payload = payload;
      alloc_valid = 1'b1;
      #1;
      if (alloc_ready !== 1'b1) begin
        $display("allocate_payload: ERROR - alloc_ready=%0b", alloc_ready);
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

  task automatic send_completion(
    input rob_tag_t result_tag,
    input logic [31:0] result_value
  );
    begin
      // Hold the completion payload across one accepting rising edge.
      @(negedge clk);
      alloc_valid = 1'b0;
      retire_ready = 1'b0;
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

  initial begin
    rst = 1'b0;
    alloc_valid = 1'b0;
    alloc_payload = '0;
    complete_valid = 1'b0;
    complete_tag = '0;
    complete_result = '0;
    retire_ready = 1'b0;
    errors = 0;

    payload_a.pc = 32'h0000_3000;
    payload_a.instr = 32'h0010_0093;
    payload_a.rd = 5'd1;
    payload_a.reg_write = 1'b1;
    payload_b.pc = 32'h0000_3004;
    payload_b.instr = 32'h0020_0113;
    payload_b.rd = 5'd2;
    payload_b.reg_write = 1'b1;

    reset_dut();
    // A younger completion cannot bypass an incomplete Head.
    allocate_payload(payload_a, tag_a);
    allocate_payload(payload_b, tag_b);

    if (tag_a.generation !== 1'b0 || tag_a.index !== 0 || tag_b.generation !== 1'b0 || tag_b.index !== 1) begin
      $display("allocation: ERROR - tag_a=%0b tag_b=%0b", tag_a, tag_b);
      errors++;
    end
    if (count !== 2 || head_valid !== 1'b1 || head_tag !== tag_a || head_entry.payload !== payload_a || head_entry.completed !== 1'b0 || retire_valid !== 1'b0) begin
      $display("before completion: ERROR - A should be the incomplete ROB Head");
      errors++;
    end
    send_completion(tag_b, RESULT_B);
    if (count !== 2 || head_tag !== tag_a || head_entry.completed !== 1'b0 || retire_valid !== 1'b0) begin
      $display("younger completion: ERROR - completed B must not make incomplete Head A retireable");
      errors++;
    end

    // Downstream readiness alone cannot retire an incomplete Head.
    @(negedge clk);
    alloc_valid = 1'b0;
    complete_valid = 1'b0;
    retire_ready = 1'b1;
    #1;
    if (retire_valid !== 1'b0) begin
      $display("retire_ready high: ERROR - retire_valid=%0b", retire_valid);
      errors++;
    end
    @(posedge clk);
    #1;
    if (count !== 2 || head_tag !== tag_a || head_entry.payload !== payload_a || head_entry.completed !== 1'b0) begin
      $display("retire_ready high: ERROR - A should remain the incomplete ROB Head");
      errors++;
    end
    @(negedge clk);
    retire_ready = 1'b0;

    // A completed Head remains stable while the retirement consumer applies
    // backpressure.
    send_completion(tag_a, RESULT_A);
    if (count !== 2 || head_tag !== tag_a || head_entry.payload !== payload_a || head_entry.completed !== 1'b1 || head_entry.result !== RESULT_A || retire_valid !== 1'b1) begin
      $display("completion of A: ERROR - A should be the completed ROB Head");
      errors++;
    end
    @(posedge clk);
    #1;
    if (count !== 2 || head_tag !== tag_a || head_entry.payload !== payload_a || head_entry.completed !== 1'b1 || head_entry.result !== RESULT_A || retire_valid !== 1'b1) begin
      $display("retire_ready low: ERROR - A should remain the completed ROB Head");
      errors++;
    end

    // Continuous readiness retires A and then B in program order.
    @(negedge clk);
    retire_ready = 1'b1;
    #1;
    if (retire_valid !== 1'b1 || head_tag !== tag_a) begin
      $display("retire A: ERROR - A should be the first retirement candidate");
      errors++;
    end
    @(posedge clk);
    #1;
    if (count !== 1 || head_tag !== tag_b || head_entry.payload !== payload_b || head_entry.completed !== 1'b1 || head_entry.result !== RESULT_B || retire_valid !== 1'b1) begin
      $display("retire A: ERROR - completed B should become the next ROB Head");
      errors++;
    end
    @(posedge clk);
    #1;
    if (empty !== 1'b1 || count !== 0 || head_valid !== 1'b0 || retire_valid !== 1'b0) begin
      $display("retire B: ERROR - ROB should be empty");
      errors++;
    end
    @(negedge clk);
    retire_ready = 1'b0;

    // A completion presented with retire_ready cannot retire until the
    // registered completed state makes retire_valid high on the following cycle.
    allocate_payload(payload_a, tag_a);
    @(negedge clk);
    alloc_valid = 1'b0;
    complete_tag = tag_a;
    complete_result = RESULT_A;
    complete_valid = 1'b1;
    retire_ready = 1'b1;
    #1;
    if (count !== 1 || head_tag !== tag_a || head_entry.completed !== 1'b0 || retire_valid !== 1'b0) begin
      $display("same-cycle completion: ERROR - incomplete entry should not retire before the completion edge");
      errors++;
    end
    @(posedge clk);
    #1;
    if (count !== 1 || head_tag !== tag_a || head_entry.completed !== 1'b1 || head_entry.result !== RESULT_A || retire_valid !== 1'b1) begin
      $display("same-cycle completion: ERROR - entry should complete without retiring on the same edge");
      errors++;
    end
    @(negedge clk);
    complete_valid = 1'b0;
    complete_tag = '0;
    complete_result = '0;
    @(posedge clk);
    #1;
    if (empty !== 1'b1 || count !== 0 || head_valid !== 1'b0 || retire_valid !== 1'b0) begin
      $display("same-cycle completion: ERROR - completed entry should retire on the following edge");
      errors++;
    end
    @(negedge clk);
    retire_ready = 1'b0;

    if (errors != 0) begin
      $fatal(1, "rv32_rob_retirement_tb: FAIL - %0d errors", errors);
    end
    $display("rv32_rob_retirement_tb: in-order retirement and backpressure checks passed");
    $finish;
  end

endmodule
