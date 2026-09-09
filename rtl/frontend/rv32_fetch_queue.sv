// SPDX-License-Identifier: Apache-2.0
//
// Fetch buffer between the instruction-response path and Decode/Rename. The
// queue absorbs backend stalls while preserving program order and supports
// recovery Flush without retaining wrong-path instructions.

`timescale 1ns/1ps

module rv32_fetch_queue
  import rv32_ooo_pkg::*;
(
  input  logic                                 clk_i,
  input  logic                                 rst_i,
  input  logic                                 flush_i,

  input  logic                                 enq_valid_i,
  output logic                                 enq_ready_o,
  input  fetch_entry_t                         enq_entry_i,

  output logic                                 deq_valid_o,
  input  logic                                 deq_ready_i,
  output fetch_entry_t                         deq_entry_o,

  output logic                                 empty_o,
  output logic                                 full_o,
  output logic [FETCH_QUEUE_COUNT_WIDTH-1:0]   count_o
);

  fetch_entry_t entry_q [0:FETCH_QUEUE_ENTRIES-1];
  logic [FETCH_QUEUE_INDEX_WIDTH-1:0] head_q;
  logic [FETCH_QUEUE_INDEX_WIDTH-1:0] tail_q;
  logic [FETCH_QUEUE_COUNT_WIDTH-1:0] count_q;
  logic enq_fire;
  logic deq_fire;

  // A dequeue accepted from a full Queue frees space on the same edge, allowing
  // an enqueue without introducing a bubble. Invalid output carries zero payload.
  assign enq_ready_o = !rst_i && !flush_i && (!full_o || deq_fire);
  assign deq_valid_o = !rst_i && !flush_i && !empty_o;
  assign deq_entry_o = deq_valid_o ? entry_q[head_q] : '0;
  assign empty_o = count_q == '0;
  assign full_o = count_q == FETCH_QUEUE_COUNT_WIDTH'(FETCH_QUEUE_ENTRIES);
  assign count_o = count_q;
  assign enq_fire = enq_valid_i && enq_ready_o;
  assign deq_fire = deq_valid_o && deq_ready_i;

  // Reset and recovery Flush invalidate all entries through occupancy state;
  // payload storage itself does not need to be reset.
  always_ff @(posedge clk_i) begin
    if (rst_i || flush_i) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
    end else begin
      // Enqueue writes the current tail before advancing with explicit wraparound.
      if (enq_fire) begin
        entry_q[tail_q] <= enq_entry_i;
        if (tail_q == FETCH_QUEUE_INDEX_WIDTH'(FETCH_QUEUE_ENTRIES-1)) begin
          tail_q <= '0;
        end else begin
          tail_q <= tail_q + 1'b1;
        end
      end
      // Dequeue advances the current head with the same wraparound behavior.
      if (deq_fire) begin
        if (head_q == FETCH_QUEUE_INDEX_WIDTH'(FETCH_QUEUE_ENTRIES-1)) begin
          head_q <= '0;
        end else begin
          head_q <= head_q + 1'b1;
        end
      end
      // Simultaneous enqueue and dequeue preserve occupancy.
      if (enq_fire && !deq_fire) begin
        count_q <= count_q + 1'b1;
      end else if (!enq_fire && deq_fire) begin
        count_q <= count_q - 1'b1;
      end
    end
  end

endmodule
