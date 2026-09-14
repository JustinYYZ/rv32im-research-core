// SPDX-License-Identifier: Apache-2.0
//
// Single-request instruction frontend for the out-of-order core. It tracks the
// request PC, converts I-cache responses into Fetch Queue entries, and discards
// wrong-path work after a recovery redirect.

`timescale 1ns/1ps

module rv32_ooo_frontend
  import rv32_ooo_pkg::*;
#(
  parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
  input  logic           clk_i,
  input  logic           rst_i,

  input  logic           redirect_valid_i,
  input  logic [31:0]    redirect_pc_i,

  output logic           icache_req_valid_o,
  input  logic           icache_req_ready_i,
  output logic [31:0]    icache_req_addr_o,
  input  logic           icache_resp_valid_i,
  input  logic [31:0]    icache_resp_data_i,
  input  logic           icache_resp_error_i,

  output logic           fetch_valid_o,
  input  logic           fetch_ready_i,
  output fetch_entry_t   fetch_entry_o
);

  logic [31:0] pc_q;
  logic [31:0] request_pc_q;
  logic outstanding_q;
  logic epoch_q;
  logic request_epoch_q;
  logic icache_req_fire;

  logic queue_enq_valid;
  logic queue_enq_ready;
  fetch_entry_t queue_enq_entry;
  logic queue_empty;
  logic queue_full;
  logic [FETCH_QUEUE_COUNT_WIDTH-1:0] queue_count;

  // A request reserves one Fetch Queue slot until its response returns. Epoch
  // comparison prevents responses from an earlier control-flow path entering the Queue.
  assign icache_req_valid_o = !rst_i && !redirect_valid_i && !outstanding_q && queue_enq_ready;
  assign icache_req_addr_o = pc_q;
  assign icache_req_fire = icache_req_valid_o && icache_req_ready_i;
  assign queue_enq_valid = !rst_i && !redirect_valid_i && icache_resp_valid_i && outstanding_q && (request_epoch_q == epoch_q);

  always_comb begin
    queue_enq_entry = '0;
    queue_enq_entry.pc = request_pc_q;
    queue_enq_entry.instr = icache_resp_data_i;
    queue_enq_entry.predicted_next_pc = request_pc_q + 32'd4;
    queue_enq_entry.access_fault = icache_resp_error_i;
  end

  rv32_fetch_queue fetch_queue (
    .clk_i(clk_i),
    .rst_i(rst_i),
    .flush_i(redirect_valid_i),
    .enq_valid_i(queue_enq_valid),
    .enq_ready_o(queue_enq_ready),
    .enq_entry_i(queue_enq_entry),
    .deq_valid_o(fetch_valid_o),
    .deq_ready_i(fetch_ready_i),
    .deq_entry_o(fetch_entry_o),
    .empty_o(queue_empty),
    .full_o(queue_full),
    .count_o(queue_count)
  );

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      pc_q <= RESET_PC;
      request_pc_q <= '0;
      outstanding_q <= 1'b0;
      epoch_q <= 1'b0;
      request_epoch_q <= 1'b0;
    end else begin
      if (redirect_valid_i) begin
        pc_q <= redirect_pc_i;
        epoch_q <= ~epoch_q;
      end else if (icache_req_fire) begin
        request_pc_q <= pc_q;
        pc_q <= pc_q + 32'd4;
        request_epoch_q <= epoch_q;
      end

      if (icache_resp_valid_i && outstanding_q) begin
        outstanding_q <= 1'b0;
      end else if (icache_req_fire) begin
        outstanding_q <= 1'b1;
      end
    end
  end

endmodule
