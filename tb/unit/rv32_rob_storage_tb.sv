// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for ROB entry storage. This testbench focuses on payload
// ordering and head-entry visibility; queue capacity and pointer mechanics are
// covered independently by rv32_rob_tb.sv.

`timescale 1ns/1ps

module rv32_rob_storage_tb;
  import rv32_ooo_pkg::*;

  logic                       clk;
  logic                       rst;
  logic                       alloc_valid;
  rob_alloc_payload_t         alloc_payload;
  logic                       alloc_ready;
  rob_tag_t                   alloc_tag;
  logic                       complete_valid;
  rob_tag_t                   complete_tag;
  logic [31:0]                complete_result;
  logic                       head_pop;
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
    .head_pop_i         (head_pop),
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
      @(negedge clk);
      rst = 1'b1;
      alloc_valid = 1'b0;
      head_pop = 1'b0;
      @(posedge clk);
      #1;
      rst = 1'b0;
    end
  endtask

  // Capture alloc_tag before the accepting edge because the tail advances at
  // that edge and immediately exposes the next free tag.
  task automatic allocate_payload(
    input rob_alloc_payload_t payload,
    output rob_tag_t allocated_tag
  );
    begin
      @(negedge clk);
      head_pop = 1'b0;
      alloc_payload = payload;
      alloc_valid = 1'b1;
      #1;

      if (alloc_ready !== 1'b1) begin
        $display("ERROR: allocate_payload: alloc_ready not high when expected");
        errors++;
        allocated_tag = 'x;
      end else begin
        allocated_tag = alloc_tag;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      alloc_payload = '0;
      alloc_valid = 1'b0;
    end
  endtask

  // Drive one pop request across an accepting rising edge.
  task automatic pop_head;
    begin
      @(negedge clk);
      alloc_valid = 1'b0;
      head_pop = 1'b1;
      #1;

      if (head_valid !== 1'b1) begin
        $display("ERROR: pop_head: head_valid not high when expected");
        errors++;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      head_pop = 1'b0;
    end
  endtask

  // Case inequality makes unknown entry fields fail the check.
  task automatic check_head_entry(
    input string test_name,
    input rob_tag_t expected_tag,
    input rob_alloc_payload_t expected_payload
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
      if (head_entry.completed !== 1'b0) begin
        $display("ERROR: %s: head_entry.completed not low when expected", test_name);
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
      if (head_entry.result !== 32'h0000_0000) begin
        $display("ERROR: %s: head_entry.result not zero when expected", test_name);
        errors++;
      end
    end
  endtask

  initial begin
    rst = 1'b0;
    alloc_valid = 1'b0;
    alloc_payload = '0;
    complete_valid = 1'b0;
    complete_tag = '0;
    complete_result = '0;
    head_pop = 1'b0;
    errors = 0;

    payload_a.pc = 32'h0000_1000;
    payload_a.instr = 32'h0010_0093;
    payload_a.rd = 5'd1;
    payload_a.reg_write = 1'b1;

    payload_b.pc = 32'h0000_1004;
    payload_b.instr = 32'h0020_0113;
    payload_b.rd = 5'd2;
    payload_b.reg_write = 1'b1;

    reset_dut();

    // Payload and result are intentionally unchecked while the reset head is
    // invalid because those data fields have no reset hardware.
    #1;
    if (empty !== 1'b1) begin
      $display("ERROR: reset: empty not high when expected");
      errors++;
    end
    if (full !== 1'b0) begin
      $display("ERROR: reset: full not low when expected");
      errors++;
    end
    if (count !== 0) begin
      $display("ERROR: reset: count not zero when expected");
      errors++;
    end
    if (head_valid !== 1'b0) begin
      $display("ERROR: reset: head_valid not low when expected");
      errors++;
    end
    if (head_entry.valid !== 1'b0) begin
      $display("ERROR: reset: head_entry.valid not low when expected");
      errors++;
    end

    // The first allocation becomes the visible, incomplete head entry.
    allocate_payload(payload_a, tag_a);
    if (tag_a.generation !== 1'b0 || tag_a.index !== 0) begin
      $display("ERROR: allocate_payload: tag_a mismatch; got %p, expected generation=0 index=0", tag_a);
      errors++;
    end
    check_head_entry("allocate_payload", tag_a, payload_a);
    if (count !== 1) begin
      $display("ERROR: allocate_payload: count not 1 when expected");
      errors++;
    end

    // A younger allocation must not replace the oldest visible head payload.
    allocate_payload(payload_b, tag_b);
    if (tag_b.generation !== 1'b0 || tag_b.index !== 1) begin
      $display("ERROR: allocate_payload: tag_b mismatch; got %p, expected generation=0 index=1", tag_b);
      errors++;
    end
    check_head_entry("allocate_payload", tag_a, payload_a);
    if (count !== 2) begin
      $display("ERROR: allocate_payload: count not 2 when expected");
      errors++;
    end

    // Removing payload_a exposes payload_b as the next in-order entry.
    pop_head();
    check_head_entry("pop_head", tag_b, payload_b);
    if (count !== 1) begin
      $display("ERROR: pop_head: count not 1 when expected");
      errors++;
    end

    // Removing the final entry clears both queue validity and head-entry validity.
    pop_head();
    if (empty !== 1'b1) begin
      $display("ERROR: pop_head: empty not high when expected");
      errors++;
    end
    if (count !== 0) begin
      $display("ERROR: pop_head: count not 0 when expected");
      errors++;
    end
    if (head_valid !== 1'b0) begin
      $display("ERROR: pop_head: head_valid not low when expected");
      errors++;
    end
    if (head_entry.valid !== 1'b0) begin
      $display("ERROR: pop_head: head_entry.valid not low when expected");
      errors++;
    end
    if (errors != 0) begin
      $fatal(1, "rv32_rob_storage_tb: FAIL - %0d errors", errors);
    end
    $display("rv32_rob_storage_tb: payload storage and head-order checks passed");
    $finish;
  end

endmodule
