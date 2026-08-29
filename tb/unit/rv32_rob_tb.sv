// SPDX-License-Identifier: Apache-2.0
//
// Self-checking testbench for ROB allocation order and occupancy tracking.
// Drive requests on a falling edge, let the DUT sample them on the following
// rising edge, then wait #1 before checking state updated by nonblocking
// assignments. Directed tests cover full/empty behavior, pointer wraparound,
// ordered pop, and simultaneous allocation/pop requests.

`timescale 1ns/1ps

module rv32_rob_tb;
  import rv32_ooo_pkg::*;

  logic                       clk;
  logic                       rst;
  logic                       alloc_valid;
  logic                       alloc_ready;
  rob_tag_t                   alloc_tag;
  logic                       complete_valid;
  rob_tag_t                   complete_tag;
  logic [31:0]                complete_result;
  logic                       head_pop;
  logic                       head_valid;
  rob_tag_t                   head_tag;
  logic                       empty;
  logic                       full;
  logic [ROB_COUNT_WIDTH-1:0] count;

  int unsigned errors;

  rob_tag_t accepted_tag;
  rob_tag_t popped_tag;
  rob_alloc_payload_t alloc_payload;
  rob_entry_t head_entry;

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

  // Case inequality makes unknown output values fail the state check.
  task automatic check_state(
    input string test_name,
    input logic expected_empty,
    input logic expected_full,
    input logic [ROB_COUNT_WIDTH-1:0] expected_count,
    input logic expected_head_valid,
    input logic expected_head_generation,
    input logic [ROB_INDEX_WIDTH-1:0] expected_head_index,
    input logic expected_alloc_ready,
    input logic expected_alloc_generation,
    input logic [ROB_INDEX_WIDTH-1:0] expected_alloc_index
  );
    begin
      #1;
      if (empty !== expected_empty) begin
        $display("%s: ERROR - empty=%0b, expected %0b", test_name, empty, expected_empty);
        errors++;
      end
      if (full !== expected_full) begin
        $display("%s: ERROR - full=%0b, expected %0b", test_name, full, expected_full);
        errors++;
      end
      if (count !== expected_count) begin
        $display("%s: ERROR - count=%0b, expected %0b", test_name, count, expected_count);
        errors++;
      end
      if (head_valid !== expected_head_valid) begin
        $display("%s: ERROR - head_valid=%0b, expected %0b", test_name, head_valid, expected_head_valid);
        errors++;
      end
      if (head_tag.generation !== expected_head_generation) begin
        $display("%s: ERROR - head_tag.generation=%0b, expected %0b", test_name, head_tag.generation, expected_head_generation);
        errors++;
      end
      if (head_tag.index !== expected_head_index) begin
        $display("%s: ERROR - head_tag.index=%0b, expected %0b", test_name, head_tag.index, expected_head_index);
        errors++;
      end
      if (alloc_ready !== expected_alloc_ready) begin
        $display("%s: ERROR - alloc_ready=%0b, expected %0b", test_name, alloc_ready, expected_alloc_ready);
        errors++;
      end
      if (alloc_tag.generation !== expected_alloc_generation) begin
        $display("%s: ERROR - alloc_tag.generation=%0b, expected %0b", test_name, alloc_tag.generation, expected_alloc_generation);
        errors++;
      end
      if (alloc_tag.index !== expected_alloc_index) begin
        $display("%s: ERROR - alloc_tag.index=%0b, expected %0b", test_name, alloc_tag.index, expected_alloc_index);
        errors++;
      end
    end
  endtask

  // Capture alloc_tag before the accepting edge because the tail advances at
  // that edge and immediately exposes the next free tag.
  task automatic allocate_one(output rob_tag_t allocated_tag);
    begin
      @(negedge clk);
      head_pop = 1'b0;
      alloc_valid = 1'b1;
      #1;
      if (alloc_ready !== 1'b1) begin
        $display("allocate_one: ERROR - ROB did not accept allocation");
        errors++;
        allocated_tag = 'x;
      end else begin
        allocated_tag = alloc_tag;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      alloc_valid = 1'b0;
    end
  endtask

  // Capture head_tag before the accepting edge because a pop advances the
  // visible head at that edge.
  task automatic pop_one(output rob_tag_t removed_tag);
    begin
      @(negedge clk);
      alloc_valid = 1'b0;
      head_pop = 1'b1;
      #1;
      if (head_valid !== 1'b1) begin
        $display("pop_one: ERROR - ROB head is not valid");
        errors++;
        removed_tag = 'x;
      end else begin
        removed_tag = head_tag;
      end
      @(posedge clk);
      #1;
      @(negedge clk);
      head_pop = 1'b0;
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

    reset_dut();
    check_state("reset", 1'b1, 1'b0, 0, 1'b0, 1'b0, '0, 1'b1, 1'b0, 0);

    allocate_one(accepted_tag);
    if (accepted_tag.generation !== 1'b0 || accepted_tag.index !== '0) begin
      $display("allocate_one: ERROR - accepted_tag=%0b, expected generation=0 index=0", accepted_tag);
      errors++;
    end
    check_state("after first allocation", 1'b0, 1'b0, 1, 1'b1, 1'b0, '0, 1'b1, 1'b0, 1);
    for (int unsigned expected_index = 1; expected_index < 4; expected_index++) begin
      allocate_one(accepted_tag);
      if (accepted_tag.generation !== 1'b0 || accepted_tag.index !== expected_index[ROB_INDEX_WIDTH-1:0]) begin
        $display("allocate_one: ERROR - accepted_tag=%0b, expected generation=0 index=%0d", accepted_tag, expected_index);
        errors++;
      end
    end
    check_state("after four allocations", 1'b0, 1'b0, 4, 1'b1, 1'b0, 0, 1'b1, 1'b0, 4);
    for (int unsigned expected_index = 4; expected_index < ROB_ENTRIES; expected_index++) begin
      allocate_one(accepted_tag);
      if (accepted_tag.generation !== 1'b0 || accepted_tag.index !== expected_index[ROB_INDEX_WIDTH-1:0]) begin
        $display("fill ROB: ERROR - accepted tag=%0b:%0d, expected 0:%0d", accepted_tag.generation, accepted_tag.index, expected_index);
        errors++;
      end
    end
    check_state("full ROB", 1'b0, 1'b1, ROB_ENTRIES, 1'b1, 1'b0, 0, 1'b0, 1'b1, 0);
    @(negedge clk);
    alloc_valid = 1'b1;
    head_pop = 1'b0;
    #1;
    if (alloc_ready !== 1'b0) begin
      $display("full ROB: ERROR - alloc_ready=%0b, expected 0", alloc_ready);
      errors++;
    end
    @(posedge clk);
    #1;
    check_state("full ROB after unaccepted allocation", 1'b0, 1'b1, ROB_ENTRIES, 1'b1, 1'b0, 0, 1'b0, 1'b1, 0);
    @(negedge clk);
    alloc_valid = 1'b0;

    pop_one(popped_tag);
    if (popped_tag.generation !== 1'b0 || popped_tag.index !== '0) begin
      $display("pop_one: ERROR - popped_tag=%0b, expected generation=0 index=0", popped_tag);
      errors++;
    end
    check_state("after first pop", 1'b0, 1'b0, ROB_ENTRIES-1, 1'b1, 1'b0, 1, 1'b1, 1'b1, 0);
    for (int unsigned expected_index = 1; expected_index < ROB_ENTRIES; expected_index++) begin
      pop_one(popped_tag);
      if (popped_tag.generation !== 1'b0 || popped_tag.index !== expected_index[ROB_INDEX_WIDTH-1:0]) begin
        $display("pop_one: ERROR - popped_tag=%0b, expected generation=0 index=%0d", popped_tag, expected_index);
        errors++;
      end
    end
    check_state("empty ROB after pops", 1'b1, 1'b0, 0, 1'b0, 1'b1, '0, 1'b1, 1'b1, 0);

    allocate_one(accepted_tag);
    if (accepted_tag.generation !== 1'b1 || accepted_tag.index !== '0) begin
      $display("allocate_one: ERROR - accepted_tag=%0b, expected generation=1 index=0", accepted_tag);
      errors++;
    end
    check_state("after wraparound allocation", 1'b0, 1'b0, 1, 1'b1, 1'b1, '0, 1'b1, 1'b1, 1);
    @(negedge clk);
    alloc_valid = 1'b1;
    head_pop = 1'b1;
    #1;

    if (alloc_ready !== 1'b1 || head_valid !== 1'b1) begin
      $display("simultaneous alloc/pop: ERROR - alloc_ready=%0b, head_valid=%0b, expected 1/1", alloc_ready, head_valid);
      errors++;
    end
    accepted_tag = alloc_tag;
    popped_tag = head_tag;
    @(posedge clk);
    #1;
    if (accepted_tag.generation !== 1'b1 || accepted_tag.index !== 1) begin
      $display("simultaneous alloc/pop: ERROR - accepted_tag=%0b, expected generation=1 index=1", accepted_tag);
      errors++;
    end
    if (popped_tag.generation !== 1'b1 || popped_tag.index !== '0) begin
      $display("simultaneous alloc/pop: ERROR - popped_tag=%0b, expected generation=1 index=0", popped_tag);
      errors++;
    end
    check_state("after simultaneous alloc/pop", 1'b0, 1'b0, 1, 1'b1, 1'b1, 1, 1'b1, 1'b1, 2);
    @(negedge clk);
    alloc_valid = 1'b0;
    head_pop = 1'b0;

    for (int unsigned i = 0; i < ROB_ENTRIES-1; i++) begin
      allocate_one(accepted_tag);
    end
    check_state("full ROB after wraparound allocations", 1'b0, 1'b1, ROB_ENTRIES, 1'b1, 1'b1, 1, 1'b0, 1'b0, 1);
    @(negedge clk);
    alloc_valid = 1'b1;
    head_pop = 1'b1;
    #1;
    if (alloc_ready !== 1'b0 || head_valid !== 1'b1) begin
      $display("simultaneous alloc/pop at full ROB: ERROR - alloc_ready=%0b, head_valid=%0b, expected 0/1", alloc_ready, head_valid);
      errors++;
    end
    popped_tag = head_tag;
    @(posedge clk);
    #1;
    if (popped_tag.generation !== 1'b1 || popped_tag.index !== 1) begin
      $display("simultaneous alloc/pop at full ROB: ERROR - popped_tag=%0b, expected generation=1 index=1", popped_tag);
      errors++;
    end
    check_state("after simultaneous alloc/pop at full ROB", 1'b0, 1'b0, ROB_ENTRIES - 1, 1'b1, 1'b1, 2, 1'b1, 1'b0, 1);
    @(negedge clk);
    alloc_valid = 1'b0;
    head_pop = 1'b0;

    if (errors !== 0) begin
      $fatal(1, "rv32_rob_tb: Test failed with %0d errors", errors);
    end else begin
      $display("rv32_rob_tb: allocation, full, pop, wraparound, and simultaneous-operation checks passed");
    end
    $finish;
  end

endmodule
