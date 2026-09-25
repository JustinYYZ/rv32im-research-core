// SPDX-License-Identifier: Apache-2.0
//
// Round-robin arbiter for the ALU, multiplier, divider, and memory completion paths.
// Each producer retains its payload until ready is asserted. At most one
// completion is transferred to the shared PRF/ROB writeback path per cycle.

`timescale 1ns/1ps

module rv32_cdb_arbiter
  import rv32_ooo_pkg::*;
(
  input  logic                clk_i,
  input  logic                rst_i,
  input  logic                flush_i,

  input  logic                alu_valid_i,
  output logic                alu_ready_o,
  input  completion_payload_t alu_payload_i,

  input  logic                mul_valid_i,
  output logic                mul_ready_o,
  input  completion_payload_t mul_payload_i,

  input  logic                div_valid_i,
  output logic                div_ready_o,
  input  completion_payload_t div_payload_i,

  input  logic                mem_valid_i,
  output logic                mem_ready_o,
  input  completion_payload_t mem_payload_i,

  output logic                cdb_valid_o,
  input  logic                cdb_ready_i,
  output completion_payload_t cdb_payload_o
);

  typedef enum logic [1:0] {
    CDB_SOURCE_ALU,
    CDB_SOURCE_MUL,
    CDB_SOURCE_DIV,
    CDB_SOURCE_MEM
  } cdb_source_e;

  cdb_source_e priority_q;
  cdb_source_e selected_source;
  logic        selection_valid;
  logic        transfer;

  always_comb begin
    selection_valid = 1'b0;
    selected_source = priority_q;
    alu_ready_o = 1'b0;
    mul_ready_o = 1'b0;
    div_ready_o = 1'b0;
    mem_ready_o = 1'b0;
    cdb_valid_o = 1'b0;
    cdb_payload_o = '0;

    // Search from the registered priority and select the first valid producer.
    // Priority changes only after a completed downstream transfer.
    if (!rst_i && !flush_i) begin
      case (priority_q)
        CDB_SOURCE_ALU: begin
          if (alu_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_ALU;
          end else if (mul_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_MUL;
          end else if (div_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_DIV;
          end else if (mem_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_MEM;
          end
        end

        CDB_SOURCE_MUL: begin
          if (mul_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_MUL;
          end else if (div_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_DIV;
          end else if (mem_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_MEM;
          end else if (alu_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_ALU;
          end
        end

        CDB_SOURCE_DIV: begin
          if (div_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_DIV;
          end else if (mem_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_MEM;
          end else if (alu_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_ALU;
          end else if (mul_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_MUL;
          end
        end

        CDB_SOURCE_MEM: begin
          if (mem_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_MEM;
          end else if (alu_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_ALU;
          end else if (mul_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_MUL;
          end else if (div_valid_i) begin
            selection_valid = 1'b1;
            selected_source = CDB_SOURCE_DIV;
          end
        end
      endcase
    end

    // The selected payload remains visible while the downstream path stalls;
    // only the selected producer receives ready on a completed transfer.
    if (selection_valid) begin
      cdb_valid_o = 1'b1;
      case (selected_source)
        CDB_SOURCE_ALU: begin
          cdb_payload_o = alu_payload_i;
          alu_ready_o = cdb_ready_i;
        end

        CDB_SOURCE_MUL: begin
          cdb_payload_o = mul_payload_i;
          mul_ready_o = cdb_ready_i;
        end

        CDB_SOURCE_DIV: begin
          cdb_payload_o = div_payload_i;
          div_ready_o = cdb_ready_i;
        end

        CDB_SOURCE_MEM: begin
          cdb_payload_o = mem_payload_i;
          mem_ready_o = cdb_ready_i;
        end
      endcase
    end
  end

  assign transfer = cdb_valid_o && cdb_ready_i;

  always_ff @(posedge clk_i) begin
    if (rst_i || flush_i) begin
      priority_q <= CDB_SOURCE_ALU;
    end else if (transfer) begin
      // Begin the next search after the producer that just transferred.
      case (selected_source)
        CDB_SOURCE_ALU: priority_q <= CDB_SOURCE_MUL;
        CDB_SOURCE_MUL: priority_q <= CDB_SOURCE_DIV;
        CDB_SOURCE_DIV: priority_q <= CDB_SOURCE_MEM;
        CDB_SOURCE_MEM: priority_q <= CDB_SOURCE_ALU;
        default:        priority_q <= CDB_SOURCE_ALU;
      endcase
    end
  end

endmodule
