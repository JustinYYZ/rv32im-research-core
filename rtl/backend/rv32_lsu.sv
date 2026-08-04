// SPDX-License-Identifier: Apache-2.0
//
// RV32 load/store data formatting unit.
//
// The ALU provides a byte address. This unit converts it into an aligned
// 32-bit memory access, formats store data and byte enables, and extracts and
// extends load data returned by memory. Cache hit/miss handling and exception
// delivery are outside this module.

`timescale 1ns/1ps

module rv32_lsu (
    input  rv32_pkg::mem_op_e           mem_op_i,
    input  rv32_pkg::mem_size_e         mem_size_i,
    input  logic                        load_unsigned_i,
    input  logic [31:0]                 addr_i,
    input  logic [31:0]                 store_value_i,
    input  logic [31:0]                 load_word_i,

    output logic [31:0]                 aligned_addr_o,
    output logic [31:0]                 store_word_o,
    output logic [3:0]                  store_mask_o,
    output logic [31:0]                 load_value_o,
    output logic                        misaligned_o
);

  logic [7:0]  selected_byte;
  logic [15:0] selected_half;

  // A 32-bit memory port is addressed on four-byte boundaries. addr_i[1:0]
  // selects the byte or halfword within the returned word.
  assign aligned_addr_o = {addr_i[31:2], 2'b00};

  always_comb begin
    misaligned_o = 1'b0;

    if (mem_op_i != rv32_pkg::MEM_NONE) begin
      // This LSU handles one aligned 32-bit word per access. Halfword and word
      // requests that would cross the supported boundary are reported to the
      // core instead of producing a partial result.
      case (mem_size_i)
        rv32_pkg::MEM_BYTE: misaligned_o = 1'b0;
        rv32_pkg::MEM_HALF: misaligned_o = addr_i[0];
        rv32_pkg::MEM_WORD: misaligned_o = |addr_i[1:0];
        default: misaligned_o = 1'b1;
      endcase
    end
  end

  always_comb begin
    store_word_o = 32'b0;
    store_mask_o = 4'b0000;

    if (mem_op_i == rv32_pkg::MEM_STORE && !misaligned_o) begin
      // Move the low byte(s) of rs2 into the lane selected by the byte address.
      // The mask prevents all unselected bytes from being modified.
      case (mem_size_i)
        rv32_pkg::MEM_BYTE: begin
          case (addr_i[1:0])
            2'b00: begin
              store_word_o = {24'b0, store_value_i[7:0]};
              store_mask_o = 4'b0001;
            end
            2'b01: begin
              store_word_o = {16'b0, store_value_i[7:0], 8'b0};
              store_mask_o = 4'b0010;
            end
            2'b10: begin
              store_word_o = {8'b0, store_value_i[7:0], 16'b0};
              store_mask_o = 4'b0100;
            end
            2'b11: begin
              store_word_o = {store_value_i[7:0], 24'b0};
              store_mask_o = 4'b1000;
            end
          endcase
        end
        rv32_pkg::MEM_HALF: begin
          if (addr_i[1] == 1'b0) begin
            store_word_o = {16'b0, store_value_i[15:0]};
            store_mask_o = 4'b0011;
          end else begin
            store_word_o = {store_value_i[15:0], 16'b0};
            store_mask_o = 4'b1100;
          end
        end
        rv32_pkg::MEM_WORD: begin
          store_word_o = store_value_i;
          store_mask_o = 4'b1111;
        end
        default: begin
          store_word_o = 32'b0;
          store_mask_o = 4'b0000;
        end
      endcase
    end
  end

  always_comb begin
    load_value_o = 32'b0;

    if (mem_op_i == rv32_pkg::MEM_LOAD && !misaligned_o) begin
      // Select the addressed lane from the returned word. Signed byte and
      // halfword loads replicate their sign bit; unsigned loads extend with 0.
      case (mem_size_i)
        rv32_pkg::MEM_BYTE: begin
          case (addr_i[1:0])
            2'b00: begin
              if (load_unsigned_i) begin
                load_value_o = {24'b0, load_word_i[7:0]};
              end else begin
                load_value_o = {{24{load_word_i[7]}}, load_word_i[7:0]};
              end
            end
            2'b01: begin
              if (load_unsigned_i) begin
                load_value_o = {24'b0, load_word_i[15:8]};
              end else begin
                load_value_o = {{24{load_word_i[15]}}, load_word_i[15:8]};
              end
            end
            2'b10: begin
              if (load_unsigned_i) begin
                load_value_o = {24'b0, load_word_i[23:16]};
              end else begin
                load_value_o = {{24{load_word_i[23]}}, load_word_i[23:16]};
              end
            end
            2'b11: begin
              if (load_unsigned_i) begin
                load_value_o = {24'b0, load_word_i[31:24]};
              end else begin
                load_value_o = {{24{load_word_i[31]}}, load_word_i[31:24]};
              end
            end
          endcase
        end
        rv32_pkg::MEM_HALF: begin
          if (addr_i[1] == 1'b0) begin
            if (load_unsigned_i) begin
              load_value_o = {16'b0, load_word_i[15:0]};
            end else begin
              load_value_o = {{16{load_word_i[15]}}, load_word_i[15:0]};
            end
          end else begin
            if (load_unsigned_i) begin
              load_value_o = {16'b0, load_word_i[31:16]};
            end else begin
              load_value_o = {{16{load_word_i[31]}}, load_word_i[31:16]};
            end
          end
        end
        rv32_pkg::MEM_WORD: load_value_o = load_word_i;
        default: load_value_o = 32'b0;
      endcase
    end
  end

endmodule
