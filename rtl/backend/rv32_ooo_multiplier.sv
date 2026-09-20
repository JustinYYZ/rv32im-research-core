// SPDX-License-Identifier: Apache-2.0
//
// OoO wrapper for the three-cycle pipelined RV32M multiplier. It keeps ROB and
// physical-register metadata aligned with each result and queues completions
// until the shared CDB accepts them. Outstanding credits prevent the
// multiplier's non-stallable response from overflowing the completion queue.

`timescale 1ns/1ps

module rv32_ooo_multiplier
  import rv32_ooo_pkg::*;
(
  input  logic                clk_i,
  input  logic                rst_i,
  input  logic                flush_i,

  input  logic                issue_valid_i,
  output logic                issue_ready_o,
  input  issue_uop_t          issue_uop_i,
  input  logic [31:0]         issue_lhs_i,
  input  logic [31:0]         issue_rhs_i,

  output logic                completion_valid_o,
  input  logic                completion_ready_i,
  output completion_payload_t completion_payload_o
);

  localparam int unsigned COMPLETION_ENTRIES = 4;
  localparam int unsigned COMPLETION_INDEX_WIDTH = $clog2(COMPLETION_ENTRIES);
  localparam int unsigned COMPLETION_COUNT_WIDTH = $clog2(COMPLETION_ENTRIES + 1);
  localparam int unsigned METADATA_STAGES = 4;

  typedef struct packed {
    rob_tag_t      rob_tag;
    phys_reg_idx_t phys_rd;
    logic          rd_write;
    logic [31:0]   actual_next_pc;
  } mul_metadata_t;

  logic unit_reset;
  logic issue_fire;
  logic credit_available;

  logic        mul_req_valid;
  logic        mul_req_ready;
  logic        mul_resp_valid;
  logic [31:0] mul_result;

  logic [METADATA_STAGES-1:0] metadata_valid_q;
  mul_metadata_t metadata_q [0:METADATA_STAGES-1];
  completion_payload_t response_payload;

  completion_payload_t completion_q [0:COMPLETION_ENTRIES-1];
  logic [COMPLETION_INDEX_WIDTH-1:0] head_q;
  logic [COMPLETION_INDEX_WIDTH-1:0] tail_q;
  logic [COMPLETION_COUNT_WIDTH-1:0] count_q;
  logic [COMPLETION_COUNT_WIDTH-1:0] outstanding_q;
  logic queue_enq;
  logic queue_deq;

  mul_metadata_t issue_metadata;
  mul_metadata_t response_metadata;

  assign unit_reset = rst_i || flush_i;

  // A request is accepted only when the multiplier is ready and one completion
  // credit is available. Reserving that credit at Issue prevents the
  // non-stallable multiplier response from overflowing the completion queue.
  assign credit_available = outstanding_q < COMPLETION_COUNT_WIDTH'(COMPLETION_ENTRIES);
  assign issue_ready_o = !unit_reset && credit_available && mul_req_ready;
  assign issue_fire = issue_valid_i && issue_ready_o;
  assign mul_req_valid = !unit_reset && credit_available && issue_valid_i;

  rv32_multiplier multiplier (
    .clk_i(clk_i),
    .rst_i(unit_reset),
    .req_valid_i(mul_req_valid),
    .req_ready_o(mul_req_ready),
    .op_i(issue_uop_i.muldiv_op),
    .lhs_i(issue_lhs_i),
    .rhs_i(issue_rhs_i),
    .resp_valid_o(mul_resp_valid),
    .result_o(mul_result)
  );

  // Four metadata registers align an acceptance-edge identity with the
  // multiplier's registered response signal and data. Only valid stages copy
  // payload state; the validity pipeline identifies which entries matter.
  always_comb begin
    issue_metadata = '0;
    issue_metadata.rob_tag = issue_uop_i.rob_tag;
    issue_metadata.phys_rd = issue_uop_i.phys_rd;
    issue_metadata.rd_write = issue_uop_i.rd_write;
    issue_metadata.actual_next_pc = issue_uop_i.pc + 32'd4;
  end

  // Reattach the delayed instruction identity to the arithmetic result before
  // placing the unified completion payload into the queue.
  always_comb begin
    response_metadata = metadata_q[METADATA_STAGES-1];
    response_payload = '0;
    response_payload.rob_tag = response_metadata.rob_tag;
    response_payload.phys_rd = response_metadata.phys_rd;
    response_payload.rd_write = response_metadata.rd_write;
    response_payload.result = mul_result;
    response_payload.actual_next_pc = response_metadata.actual_next_pc;
    queue_enq = !unit_reset && mul_resp_valid && metadata_valid_q[METADATA_STAGES-1];
  end

  assign completion_valid_o = !unit_reset && (count_q != '0);
  assign completion_payload_o = completion_valid_o ? completion_q[head_q] : '0;
  assign queue_deq = completion_valid_o && completion_ready_i;

  // The completion queue absorbs CDB backpressure. Its occupancy counts only
  // completed results, while outstanding_q also includes requests still in the
  // multiplier pipeline. Simultaneous enqueue/dequeue or Issue/dequeue events
  // leave the corresponding count unchanged.
  always_ff @(posedge clk_i) begin
    if (unit_reset) begin
      metadata_valid_q <= '0;
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      outstanding_q <= '0;
    end else begin
      metadata_valid_q[0] <= issue_fire;
      for (int unsigned stage = 1; stage < METADATA_STAGES; stage++) begin
        metadata_valid_q[stage] <= metadata_valid_q[stage-1];
      end
      if (issue_fire) begin
        metadata_q[0] <= issue_metadata;
      end
      for (int unsigned stage = 1; stage < METADATA_STAGES; stage++) begin
        if (metadata_valid_q[stage-1]) begin
          metadata_q[stage] <= metadata_q[stage-1];
        end
      end
      if (queue_enq) begin
        completion_q[tail_q] <= response_payload;
        if (tail_q == COMPLETION_INDEX_WIDTH'(COMPLETION_ENTRIES-1)) begin
          tail_q <= '0;
        end else begin
          tail_q <= tail_q + 1'b1;
        end
      end
      if (queue_deq) begin
        if (head_q == COMPLETION_INDEX_WIDTH'(COMPLETION_ENTRIES-1)) begin
          head_q <= '0;
        end else begin
          head_q <= head_q + 1'b1;
        end
      end
      if (queue_enq && !queue_deq) begin
        count_q <= count_q + 1'b1;
      end else if (!queue_enq && queue_deq) begin
        count_q <= count_q - 1'b1;
      end
      if (issue_fire && !queue_deq) begin
        outstanding_q <= outstanding_q + 1'b1;
      end else if (!issue_fire && queue_deq) begin
        outstanding_q <= outstanding_q - 1'b1;
      end
    end
  end

endmodule
