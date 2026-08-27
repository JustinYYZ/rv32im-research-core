// SPDX-License-Identifier: Apache-2.0
//
// Circular allocation-order tracker for the first OoO ROB milestone.
//
// This file initially tracks only instruction identity and occupancy. It does
// not yet store PC, instruction, destination, result, exception, or memory
// information. Completion and architectural retirement are added in O1B after
// the queue mechanics have independent tests.

`timescale 1ns/1ps

module rv32_rob
  import rv32_ooo_pkg::*;
(
    input  logic                       clk_i,
    input  logic                       rst_i,

    input  logic                       alloc_valid_i,
    output logic                       alloc_ready_o,
    output rob_tag_t                   alloc_tag_o,

    input  logic                       head_pop_i,
    output logic                       head_valid_o,
    output rob_tag_t                   head_tag_o,

    output logic                       empty_o,
    output logic                       full_o,
    output logic [ROB_COUNT_WIDTH-1:0] count_o
);

  logic [ROB_INDEX_WIDTH-1:0] head_index_q;
  logic [ROB_INDEX_WIDTH-1:0] tail_index_q;
  logic                       head_generation_q;
  logic                       tail_generation_q;
  logic [ROB_COUNT_WIDTH-1:0] count_q;

  logic alloc_fire;
  logic pop_fire;

  // Explicit occupancy distinguishes full from empty when the circular head
  // and tail pointers have the same index.
  always_comb begin
    empty_o = count_q == 0;
    full_o = count_q == ROB_ENTRIES;
    count_o = count_q;

    // The generation bit distinguishes different uses of the same slot after
    // pointer wraparound.
    alloc_tag_o.generation = tail_generation_q;
    alloc_tag_o.index = tail_index_q;
    head_tag_o.generation = head_generation_q;
    head_tag_o.index = head_index_q;

    // A full ROB rejects allocation even when a pop is requested in the same
    // cycle. The freed slot becomes available on the following cycle.
    head_valid_o = !empty_o;
    alloc_ready_o = !full_o;

    // Only accepted requests may update queue state.
    alloc_fire = alloc_valid_i && alloc_ready_o;
    pop_fire = head_pop_i && head_valid_o;
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      head_index_q <= '0;
      tail_index_q <= '0;
      head_generation_q <= 1'b0;
      tail_generation_q <= 1'b0;
      count_q <= '0;
    end else begin
      // Allocation advances the tail and changes generation on wraparound.
      if (alloc_fire) begin
        if (tail_index_q == ROB_INDEX_WIDTH'(ROB_ENTRIES - 1)) begin
          tail_index_q <= '0;
          tail_generation_q <= ~tail_generation_q;
        end else begin
          tail_index_q <= tail_index_q + 1;
        end
      end

      // Pop advances the head independently from the allocation pointer.
      if (pop_fire) begin
        if (head_index_q == ROB_INDEX_WIDTH'(ROB_ENTRIES - 1)) begin
          head_index_q <= '0;
          head_generation_q <= ~head_generation_q;
        end else begin
          head_index_q <= head_index_q + 1;
        end
      end

      // Simultaneous allocation and pop leave occupancy unchanged.
      if (alloc_fire && !pop_fire) begin
        count_q <= count_q + 1;
      end else if (!alloc_fire && pop_fire) begin
        count_q <= count_q - 1;
      end
    end
  end

endmodule
