// SPDX-License-Identifier: Apache-2.0
//
// Blocking direct-mapped L1 data cache.
//
// The cache accepts one aligned 32-bit load or masked store at a time and uses
// write-back, write-allocate, sequential word refill, and dirty-line eviction.
// Request backpressure and lower-memory access errors are handled without
// exposing partially refilled lines to the CPU.

`timescale 1ns/1ps

module rv32_dcache #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned CACHE_BYTES = rv32_cache_pkg::L1_DEFAULT_CACHE_BYTES,
    parameter int unsigned LINE_BYTES = rv32_cache_pkg::L1_DEFAULT_LINE_BYTES
) (
    input  logic                  clk_i,
    input  logic                  rst_i,

    input  logic                  cpu_req_valid_i,
    output logic                  cpu_req_ready_o,
    input  logic [ADDR_WIDTH-1:0] cpu_req_addr_i,
    input  logic                  cpu_req_write_i,
    input  logic [31:0]           cpu_req_wdata_i,
    input  logic [3:0]            cpu_req_wstrb_i,
    output logic                  cpu_resp_valid_o,
    output logic [31:0]           cpu_resp_rdata_o,
    output logic                  cpu_resp_error_o,

    output logic                  mem_req_valid_o,
    input  logic                  mem_req_ready_i,
    output logic [ADDR_WIDTH-1:0] mem_req_addr_o,
    output logic                  mem_req_write_o,
    output logic [31:0]           mem_req_wdata_o,
    output logic [3:0]            mem_req_wstrb_o,
    input  logic                  mem_resp_valid_i,
    input  logic [31:0]           mem_resp_rdata_i,
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
  localparam int unsigned TRANSFER_COUNT_BITS = WORDS_PER_LINE > 1 ? $clog2(WORDS_PER_LINE) : 1;

  int reset_index;

  logic [OFFSET_BITS-1:0] cpu_req_offset;
  logic [INDEX_BITS-1:0] cpu_req_index;
  logic [WORD_INDEX_BITS-1:0] cpu_req_word_index;
  logic [TAG_BITS-1:0] cpu_req_tag;
  logic [ADDR_WIDTH-1:0] cpu_req_line_base;
  logic valid_array [0:SET_COUNT-1];
  logic dirty_array [0:SET_COUNT-1];
  logic [TAG_BITS-1:0] tag_array [0:SET_COUNT-1];
  logic [LINE_BITS-1:0] data_array [0:SET_COUNT-1];

  logic lookup_valid;
  logic lookup_dirty;
  logic [TAG_BITS-1:0] lookup_stored_tag;
  logic [LINE_BITS-1:0] lookup_line;
  logic lookup_hit;
  logic [WORD_BITS-1:0] lookup_word;
  logic [INDEX_BITS-1:0] lookup_index;
  logic [WORD_INDEX_BITS-1:0] lookup_word_index;
  logic [TAG_BITS-1:0] lookup_tag;

  logic [WORD_BITS-1:0] merged_word;
  int byte_lane;
  logic [WORD_BITS-1:0] merge_wdata;
  logic [3:0] merge_wstrb;

  rv32_cache_pkg::dcache_state_e state_q;
  logic [ADDR_WIDTH-1:0] request_addr_q;
  logic request_write_q;
  logic [WORD_BITS-1:0] request_wdata_q;
  logic [3:0] request_wstrb_q;
  logic [WORD_BITS-1:0] response_rdata_q;
  logic response_error_q;

  logic [INDEX_BITS-1:0] request_index;
  logic [WORD_INDEX_BITS-1:0] request_word_index;
  logic [TAG_BITS-1:0] request_tag;
  logic [ADDR_WIDTH-1:0] request_line_base;

  logic [TRANSFER_COUNT_BITS-1:0] transfer_count_q;
  logic [LINE_BITS-1:0] refill_buffer_q;
  logic [LINE_BITS-1:0] install_line;
  int install_byte_lane;

  logic [TAG_BITS-1:0] victim_tag_q;
  logic [LINE_BITS-1:0] victim_line_q;
  logic [ADDR_WIDTH-1:0] victim_line_base;


  // Address fields are derived from the configured capacity and line size so
  // the implementation does not depend on the default 32 KiB geometry.
  assign cpu_req_offset = cpu_req_addr_i[OFFSET_BITS-1:0];
  assign cpu_req_index = cpu_req_addr_i[OFFSET_BITS +: INDEX_BITS];
  assign cpu_req_word_index = cpu_req_addr_i[WORD_OFFSET_BITS +: WORD_INDEX_BITS];
  assign cpu_req_tag = cpu_req_addr_i[ADDR_WIDTH-1 -: TAG_BITS];
  assign cpu_req_line_base = {cpu_req_addr_i[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};

  // CPU requests are accepted only in IDLE. Lower-memory requests are issued
  // one word at a time during refill or dirty-victim writeback.
  assign cpu_req_ready_o = state_q == rv32_cache_pkg::DCACHE_STATE_IDLE;
  assign cpu_resp_valid_o = state_q == rv32_cache_pkg::DCACHE_STATE_RESPONSE;
  assign cpu_resp_rdata_o = response_rdata_q;
  assign cpu_resp_error_o = response_error_q;
  assign mem_req_valid_o = state_q == rv32_cache_pkg::DCACHE_STATE_REFILL_REQUEST || state_q == rv32_cache_pkg::DCACHE_STATE_WRITEBACK_REQUEST;
  assign mem_req_addr_o = state_q == rv32_cache_pkg::DCACHE_STATE_WRITEBACK_REQUEST ? victim_line_base + transfer_count_q * WORD_BYTES : request_line_base + transfer_count_q * WORD_BYTES;
  assign mem_req_write_o = state_q == rv32_cache_pkg::DCACHE_STATE_WRITEBACK_REQUEST;
  assign mem_req_wdata_o = victim_line_q[transfer_count_q * WORD_BITS +: WORD_BITS];
  assign mem_req_wstrb_o = state_q == rv32_cache_pkg::DCACHE_STATE_WRITEBACK_REQUEST ? 4'b1111 : 4'b0000;

  assign lookup_valid = valid_array[lookup_index];
  assign lookup_dirty = dirty_array[lookup_index];
  assign lookup_stored_tag = tag_array[lookup_index];
  assign lookup_line = data_array[lookup_index];
  assign lookup_hit = lookup_valid && (lookup_stored_tag == lookup_tag);
  assign lookup_word = lookup_line[lookup_word_index * WORD_BITS +: WORD_BITS];
  assign lookup_index = state_q == rv32_cache_pkg::DCACHE_STATE_IDLE ? cpu_req_index : request_index;
  assign lookup_word_index = state_q == rv32_cache_pkg::DCACHE_STATE_IDLE ? cpu_req_word_index : request_word_index;
  assign lookup_tag = state_q == rv32_cache_pkg::DCACHE_STATE_IDLE ? cpu_req_tag : request_tag;

  assign request_index = request_addr_q[OFFSET_BITS +: INDEX_BITS];
  assign request_word_index = request_addr_q[WORD_OFFSET_BITS +: WORD_INDEX_BITS];
  assign request_tag = request_addr_q[ADDR_WIDTH-1 -: TAG_BITS];

  assign merge_wdata = state_q == rv32_cache_pkg::DCACHE_STATE_IDLE ? cpu_req_wdata_i : request_wdata_q;
  assign merge_wstrb = state_q == rv32_cache_pkg::DCACHE_STATE_IDLE ? cpu_req_wstrb_i : request_wstrb_q;

  assign request_line_base = {request_addr_q[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
  assign victim_line_base = {victim_tag_q, request_index, {OFFSET_BITS{1'b0}}};

  // Merge only the byte lanes selected by the saved store mask.
  always_comb begin
    merged_word = lookup_word;
    for (byte_lane = 0; byte_lane < WORD_BYTES; byte_lane++) begin
      if (merge_wstrb[byte_lane]) begin
        merged_word[byte_lane * 8 +: 8] = merge_wdata[byte_lane * 8 +: 8];
      end
    end
  end

  always_comb begin
    install_line = refill_buffer_q;
    if (request_write_q) begin
      for (install_byte_lane = 0; install_byte_lane < WORD_BYTES; install_byte_lane++) begin
        if (request_wstrb_q[install_byte_lane]) begin
          install_line[request_word_index * WORD_BITS + install_byte_lane * 8 +: 8] = request_wdata_q[install_byte_lane * 8 +: 8];
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      state_q <= rv32_cache_pkg::DCACHE_STATE_IDLE;
      response_rdata_q <= '0;
      response_error_q <= 1'b0;
      request_addr_q <= '0;
      request_write_q <= 1'b0;
      request_wdata_q <= '0;
      request_wstrb_q <= 4'b0000;
      transfer_count_q <= '0;
      refill_buffer_q <= '0;
      for (reset_index = 0; reset_index < SET_COUNT; reset_index++) begin
        valid_array[reset_index] <= 1'b0;
        dirty_array[reset_index] <= 1'b0;
      end
    end else begin
      // The blocking controller retains one CPU request until a hit, refill,
      // writeback, or access-error response completes it.
      case (state_q)
        rv32_cache_pkg::DCACHE_STATE_IDLE: begin
          if (cpu_req_valid_i && cpu_req_ready_o) begin
            request_addr_q <= cpu_req_addr_i;
            request_write_q <= cpu_req_write_i;
            request_wdata_q <= cpu_req_wdata_i;
            request_wstrb_q <= cpu_req_wstrb_i;
            response_error_q <= 1'b0;
            state_q <= rv32_cache_pkg::DCACHE_STATE_LOOKUP;
          end
        end
        rv32_cache_pkg::DCACHE_STATE_LOOKUP: begin
          if (lookup_hit) begin
            if (request_write_q) begin
              data_array[lookup_index][lookup_word_index * WORD_BITS +: WORD_BITS] <= merged_word;
              dirty_array[lookup_index] <= 1'b1;
              response_rdata_q <= '0;
            end else begin
              response_rdata_q <= lookup_word;
            end
            state_q <= rv32_cache_pkg::DCACHE_STATE_RESPONSE;
          end else begin
            transfer_count_q <= '0;
            refill_buffer_q <= '0;
            if (lookup_valid && lookup_dirty) begin
              victim_tag_q <= lookup_stored_tag;
              victim_line_q <= lookup_line;
              state_q <= rv32_cache_pkg::DCACHE_STATE_WRITEBACK_REQUEST;
            end else begin
              state_q <= rv32_cache_pkg::DCACHE_STATE_REFILL_REQUEST;
            end
          end
        end
        rv32_cache_pkg::DCACHE_STATE_WRITEBACK_REQUEST: begin
            if (mem_req_valid_o && mem_req_ready_i) begin
              state_q <= rv32_cache_pkg::DCACHE_STATE_WRITEBACK_WAIT;
            end
        end
        rv32_cache_pkg::DCACHE_STATE_WRITEBACK_WAIT: begin
          if (mem_resp_valid_i) begin
            if (mem_resp_error_i) begin
              response_rdata_q <= '0;
              response_error_q <= 1'b1;
              state_q <= rv32_cache_pkg::DCACHE_STATE_RESPONSE;
            end else if (transfer_count_q != WORDS_PER_LINE - 1) begin
              transfer_count_q <= transfer_count_q + 1'b1;
              state_q <= rv32_cache_pkg::DCACHE_STATE_WRITEBACK_REQUEST;
            end else begin
              transfer_count_q <= '0;
              refill_buffer_q <= '0;
              state_q <= rv32_cache_pkg::DCACHE_STATE_REFILL_REQUEST;
            end
          end
        end
        rv32_cache_pkg::DCACHE_STATE_RESPONSE: begin
          state_q <= rv32_cache_pkg::DCACHE_STATE_IDLE;
        end
        rv32_cache_pkg::DCACHE_STATE_REFILL_REQUEST: begin
            if (mem_req_valid_o && mem_req_ready_i) begin
              state_q <= rv32_cache_pkg::DCACHE_STATE_REFILL_WAIT;
            end
        end
        rv32_cache_pkg::DCACHE_STATE_REFILL_WAIT: begin
          if (mem_resp_valid_i) begin
            if (mem_resp_error_i) begin
              response_rdata_q <= '0;
              response_error_q <= 1'b1;
              state_q <= rv32_cache_pkg::DCACHE_STATE_RESPONSE;
            end else begin
              refill_buffer_q[transfer_count_q * WORD_BITS +: WORD_BITS] <= mem_resp_rdata_i;
              if (transfer_count_q != WORDS_PER_LINE - 1) begin
                transfer_count_q <= transfer_count_q + 1'b1;
                state_q <= rv32_cache_pkg::DCACHE_STATE_REFILL_REQUEST;
              end else begin
                state_q <= rv32_cache_pkg::DCACHE_STATE_REFILL_INSTALL;
              end
            end
          end
        end
        rv32_cache_pkg::DCACHE_STATE_REFILL_INSTALL: begin
          valid_array[request_index] <= 1'b1;
          tag_array[request_index] <= request_tag;
          dirty_array[request_index] <= request_write_q;
          data_array[request_index] <= install_line;
          if (request_write_q) begin
            response_rdata_q <= '0;
          end else begin
            response_rdata_q <= install_line[request_word_index * WORD_BITS +: WORD_BITS];
          end
          response_error_q <= 1'b0;
          state_q <= rv32_cache_pkg::DCACHE_STATE_RESPONSE;
        end
        default: begin
          state_q <= rv32_cache_pkg::DCACHE_STATE_IDLE;
        end
      endcase
    end
  end

endmodule
