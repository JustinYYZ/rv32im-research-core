// SPDX-License-Identifier: Apache-2.0
//
// Blocking direct-mapped L1 instruction cache.
//
// The CPU side uses a single-outstanding request/response protocol. On a miss,
// the memory side reads one 32-bit word at a time and installs the complete
// cache line atomically.

`timescale 1ns/1ps

module rv32_icache #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CACHE_BYTES = rv32_cache_pkg::L1_DEFAULT_CACHE_BYTES,
    parameter int unsigned LINE_BYTES = rv32_cache_pkg::L1_DEFAULT_LINE_BYTES
) (
    input  logic                  clk_i,
    input  logic                  rst_i,

    input  logic                  cpu_req_valid_i,
    output logic                  cpu_req_ready_o,
    input  logic [ADDR_WIDTH-1:0] cpu_req_addr_i,
    output logic                  cpu_resp_valid_o,
    output logic [31:0]           cpu_resp_data_o,
    output logic                  cpu_resp_error_o,

    output logic                  mem_req_valid_o,
    input  logic                  mem_req_ready_i,
    output logic [ADDR_WIDTH-1:0] mem_req_addr_o,
    input  logic                  mem_resp_valid_i,
    input  logic [31:0]           mem_resp_data_i,
    input  logic                  mem_resp_error_i
);

  localparam int unsigned WORD_BYTES = rv32_cache_pkg::CACHE_WORD_BYTES;
  localparam int unsigned WORD_BITS = WORD_BYTES * 8;
  localparam int unsigned LINE_BITS = LINE_BYTES * 8;
  localparam int unsigned WORDS_PER_LINE = LINE_BYTES / WORD_BYTES;
  localparam int unsigned SET_COUNT = CACHE_BYTES / LINE_BYTES;
  localparam int unsigned OFFSET_BITS = $clog2(LINE_BYTES);
  localparam int unsigned WORD_OFFSET_BITS = $clog2(WORD_BYTES);
  localparam int unsigned INDEX_BITS = $clog2(SET_COUNT);
  localparam int unsigned WORD_INDEX_BITS = $clog2(WORDS_PER_LINE);
  localparam int unsigned TAG_BITS = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;
  localparam int unsigned REFILL_COUNT_BITS = WORDS_PER_LINE > 1 ? $clog2(WORDS_PER_LINE) : 1;

  int reset_index;

  logic [OFFSET_BITS-1:0] cpu_req_offset;
  logic [INDEX_BITS-1:0] cpu_req_index;
  logic [WORD_INDEX_BITS-1:0] cpu_req_word_index;
  logic [TAG_BITS-1:0] cpu_req_tag;
  logic [ADDR_WIDTH-1:0] cpu_req_line_base;
  logic valid_array [0:SET_COUNT-1];
  logic [TAG_BITS-1:0] tag_array [0:SET_COUNT-1];
  logic [LINE_BITS-1:0] data_array [0:SET_COUNT-1];

  logic lookup_valid;
  logic [TAG_BITS-1:0] lookup_stored_tag;
  logic [LINE_BITS-1:0] lookup_line;
  logic lookup_hit;
  logic [WORD_BITS-1:0] lookup_word;

  rv32_cache_pkg::icache_state_e state_q;
  logic [ADDR_WIDTH-1:0] request_addr_q;
  logic [WORD_BITS-1:0] response_data_q;
  logic response_error_q;

  logic [INDEX_BITS-1:0] request_index;
  logic [WORD_INDEX_BITS-1:0] request_word_index;
  logic [TAG_BITS-1:0] request_tag;
  logic [ADDR_WIDTH-1:0] request_line_base;

  logic [REFILL_COUNT_BITS-1:0] refill_word_count_q;
  logic [LINE_BITS-1:0] refill_buffer_q;

  assign cpu_req_ready_o = state_q == rv32_cache_pkg::ICACHE_STATE_IDLE;
  assign cpu_resp_valid_o = state_q == rv32_cache_pkg::ICACHE_STATE_RESPONSE;
  assign cpu_resp_data_o = response_data_q;
  assign cpu_resp_error_o = response_error_q;
  assign mem_req_valid_o = state_q == rv32_cache_pkg::ICACHE_STATE_REFILL_REQUEST;
  assign mem_req_addr_o = request_line_base + refill_word_count_q * WORD_BYTES;

  assign cpu_req_offset = cpu_req_addr_i[OFFSET_BITS-1:0];
  assign cpu_req_index = cpu_req_addr_i[OFFSET_BITS +: INDEX_BITS];
  assign cpu_req_word_index = cpu_req_addr_i[WORD_OFFSET_BITS +: WORD_INDEX_BITS];
  assign cpu_req_tag = cpu_req_addr_i[ADDR_WIDTH-1 -: TAG_BITS];
  assign cpu_req_line_base = {cpu_req_addr_i[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};

  assign lookup_valid = valid_array[request_index];
  assign lookup_stored_tag = tag_array[request_index];
  assign lookup_line = data_array[request_index];
  assign lookup_hit = lookup_valid && (lookup_stored_tag == request_tag);
  assign lookup_word = lookup_line[request_word_index * WORD_BITS +: WORD_BITS];

  assign request_index = request_addr_q[OFFSET_BITS +: INDEX_BITS];
  assign request_word_index = request_addr_q[WORD_OFFSET_BITS +: WORD_INDEX_BITS];
  assign request_tag = request_addr_q[ADDR_WIDTH-1 -: TAG_BITS];
  assign request_line_base = {request_addr_q[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};

  // Address fields are derived from geometry parameters so line-size and
  // capacity experiments do not require fixed bit-slice changes.
  // The blocking controller accepts one CPU request and returns one response.
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= rv32_cache_pkg::ICACHE_STATE_IDLE;
      request_addr_q <= '0;
      response_data_q <= '0;
      response_error_q <= 1'b0;
      refill_word_count_q <= '0;
      refill_buffer_q <= '0;
      for (reset_index = 0; reset_index < SET_COUNT; reset_index++) begin
        valid_array[reset_index] <= 1'b0;
      end
    end else begin
      case (state_q)
        rv32_cache_pkg::ICACHE_STATE_IDLE: begin
          if (cpu_req_valid_i && cpu_req_ready_o) begin
            request_addr_q <= cpu_req_addr_i;
            response_error_q <= 1'b0;
            state_q <= rv32_cache_pkg::ICACHE_STATE_LOOKUP;
          end
        end
        rv32_cache_pkg::ICACHE_STATE_LOOKUP: begin
          if (lookup_hit) begin
            response_data_q <= lookup_word;
            state_q <= rv32_cache_pkg::ICACHE_STATE_RESPONSE;
          end else begin
            refill_word_count_q <= '0;
            refill_buffer_q <= '0;
            state_q <= rv32_cache_pkg::ICACHE_STATE_REFILL_REQUEST;
          end
        end
        rv32_cache_pkg::ICACHE_STATE_REFILL_REQUEST: begin
            if (mem_req_valid_o && mem_req_ready_i) begin
              state_q <= rv32_cache_pkg::ICACHE_STATE_REFILL_WAIT;
            end
        end
        rv32_cache_pkg::ICACHE_STATE_RESPONSE: begin
          state_q <= rv32_cache_pkg::ICACHE_STATE_IDLE;
        end
        rv32_cache_pkg::ICACHE_STATE_REFILL_WAIT: begin
          if (mem_resp_valid_i) begin
            if (mem_resp_error_i) begin
              response_data_q <= '0;
              response_error_q <= 1'b1;
              state_q <= rv32_cache_pkg::ICACHE_STATE_RESPONSE;
            end else begin
              refill_buffer_q[refill_word_count_q * WORD_BITS +: WORD_BITS] <= mem_resp_data_i;
              if (refill_word_count_q != WORDS_PER_LINE - 1) begin
                refill_word_count_q <= refill_word_count_q + 1'b1;
                state_q <= rv32_cache_pkg::ICACHE_STATE_REFILL_REQUEST;
              end else begin
                state_q <= rv32_cache_pkg::ICACHE_STATE_REFILL_INSTALL;
              end
            end
          end
        end
        rv32_cache_pkg::ICACHE_STATE_REFILL_INSTALL: begin
          valid_array[request_index] <= 1'b1;
          tag_array[request_index] <= request_tag;
          data_array[request_index] <= refill_buffer_q;
          response_data_q <= refill_buffer_q[request_word_index * WORD_BITS +: WORD_BITS];
          state_q <= rv32_cache_pkg::ICACHE_STATE_RESPONSE;
        end
        default: begin
          state_q <= rv32_cache_pkg::ICACHE_STATE_IDLE;
        end
      endcase
    end
  end

endmodule
