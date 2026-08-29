// SPDX-License-Identifier: Apache-2.0
//
// Circular entry store for the first out-of-order ROB milestones.
//
// The module tracks allocation order and occupancy while storing each
// instruction's PC, encoding, architectural destination, and execution result.
// Results complete by tag and may arrive out of order; architectural retirement
// is added in the next milestone.

`timescale 1ns/1ps

module rv32_rob
  import rv32_ooo_pkg::*;
(
    input  logic                       clk_i,
    input  logic                       rst_i,

    input  logic                       alloc_valid_i,
    input  rob_alloc_payload_t         alloc_payload_i,
    output logic                       alloc_ready_o,
    output rob_tag_t                   alloc_tag_o,

    input  logic                       complete_valid_i,
    input  rob_tag_t                   complete_tag_i,
    input  logic [31:0]                complete_result_i,

    input  logic                       head_pop_i,
    output logic                       head_valid_o,
    output rob_tag_t                   head_tag_o,
    output rob_entry_t                 head_entry_o,

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
  logic complete_match;

  logic [ROB_ENTRIES-1:0] entry_valid_q;
  logic [ROB_ENTRIES-1:0] entry_completed_q;
  logic [ROB_ENTRIES-1:0] entry_generation_q;
  rob_alloc_payload_t entry_payload_q [0:ROB_ENTRIES-1];
  logic [31:0] entry_result_q [0:ROB_ENTRIES-1];

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

    // A completion may update only the current valid use of the indexed slot.
    complete_match = complete_valid_i && entry_valid_q[complete_tag_i.index] &&
                     (entry_generation_q[complete_tag_i.index] == complete_tag_i.generation);

    head_entry_o.valid = entry_valid_q[head_index_q];
    head_entry_o.completed = entry_completed_q[head_index_q];
    head_entry_o.generation = entry_generation_q[head_index_q];
    head_entry_o.payload = entry_payload_q[head_index_q];
    head_entry_o.result = entry_result_q[head_index_q];
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      head_index_q <= '0;
      tail_index_q <= '0;
      head_generation_q <= 1'b0;
      tail_generation_q <= 1'b0;
      count_q <= '0;
      entry_valid_q <= '0;
      entry_completed_q <= '0;
    end else begin
      // Completion precedes allocation so a new allocation wins if both target
      // the same physical slot on one edge.
      if (complete_match) begin
        entry_completed_q[complete_tag_i.index] <= 1'b1;
        entry_result_q[complete_tag_i.index] <= complete_result_i;
      end

      // Allocation advances the tail and changes generation on wraparound.
      if (alloc_fire) begin
        entry_valid_q[tail_index_q] <= 1'b1;
        entry_completed_q[tail_index_q] <= 1'b0;
        entry_generation_q[tail_index_q] <= tail_generation_q;
        entry_payload_q[tail_index_q] <= alloc_payload_i;
        entry_result_q[tail_index_q] <= '0;
        if (tail_index_q == ROB_INDEX_WIDTH'(ROB_ENTRIES - 1)) begin
          tail_index_q <= '0;
          tail_generation_q <= ~tail_generation_q;
        end else begin
          tail_index_q <= tail_index_q + 1;
        end
      end

      // Pop advances the head independently from the allocation pointer.
      if (pop_fire) begin
        entry_valid_q[head_index_q] <= 1'b0;
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
