// SPDX-License-Identifier: Apache-2.0
//
// Single-dispatch, single-issue scheduler for the out-of-order backend. Entries
// retain renamed uops until both operands and the selected functional unit are
// ready. CDB broadcasts update stored source readiness by physical-register tag.

`timescale 1ns/1ps

module rv32_issue_queue
  import rv32_ooo_pkg::*;
(
  input  logic                         clk_i,
  input  logic                         rst_i,
  input  logic                         flush_i,

  input  logic                         dispatch_valid_i,
  output logic                         dispatch_ready_o,
  input  issue_uop_t                   dispatch_uop_i,
  input  logic                         dispatch_rs1_ready_i,
  input  logic                         dispatch_rs2_ready_i,

  input  logic                         cdb_valid_i,
  input  phys_reg_idx_t                cdb_phys_rd_i,

  input  logic [FU_COUNT-1:0]          fu_ready_i,
  output logic                         issue_valid_o,
  output issue_uop_t                   issue_uop_o,

  output logic                         empty_o,
  output logic                         full_o,
  output logic [ISSUE_COUNT_WIDTH-1:0] count_o
);

  // Entry payload and source readiness are stored separately because CDB wakeup
  // changes readiness without modifying the renamed instruction itself.
  issue_uop_t entry_uop_q [0:ISSUE_ENTRIES-1];
  logic [ISSUE_ENTRIES-1:0] entry_valid_q;
  logic [ISSUE_ENTRIES-1:0] entry_rs1_ready_q;
  logic [ISSUE_ENTRIES-1:0] entry_rs2_ready_q;
  logic [ISSUE_COUNT_WIDTH-1:0] count_q;

  logic dispatch_slot_found;
  logic [ISSUE_INDEX_WIDTH-1:0] dispatch_idx;
  logic dispatch_fire;
  int dispatch_scan_idx;

  logic issue_candidate_found;
  logic [ISSUE_INDEX_WIDTH-1:0] issue_idx;
  logic issue_fire;
  int issue_scan_idx;
  issue_uop_t issue_scan_uop;

  logic cdb_wakeup_valid;
  int wakeup_idx;
  issue_uop_t wakeup_scan_uop;


  // Dispatch uses the lowest-numbered free slot. A full queue does not accept a
  // replacement on the same edge as Issue; the newly free slot appears next cycle.
  // Select the lowest-numbered ready entry whose functional unit can accept it.
  // CDB wakeup updates stored readiness at the edge and is visible next cycle.
  always_comb begin
    dispatch_slot_found = 1'b0;
    dispatch_idx = '0;
    for (dispatch_scan_idx = 0; dispatch_scan_idx < ISSUE_ENTRIES; dispatch_scan_idx++) begin
      if (!entry_valid_q[dispatch_scan_idx] && !dispatch_slot_found) begin
        dispatch_slot_found = 1'b1;
        dispatch_idx = ISSUE_INDEX_WIDTH'(dispatch_scan_idx);
      end
    end
  end

  always_comb begin
    issue_candidate_found = 1'b0;
    issue_idx = '0;
    issue_scan_uop = '0;
    for (issue_scan_idx = 0; issue_scan_idx < ISSUE_ENTRIES; issue_scan_idx++) begin
      issue_scan_uop = entry_uop_q[issue_scan_idx];
      if (entry_valid_q[issue_scan_idx] &&
          entry_rs1_ready_q[issue_scan_idx] &&
          entry_rs2_ready_q[issue_scan_idx] &&
          fu_ready_i[issue_scan_uop.fu_kind] &&
          !issue_candidate_found) begin
        issue_candidate_found = 1'b1;
        issue_idx = ISSUE_INDEX_WIDTH'(issue_scan_idx);
      end
    end
  end

  assign dispatch_ready_o = !rst_i && !flush_i && dispatch_slot_found;
  assign dispatch_fire = dispatch_valid_i && dispatch_ready_o;
  assign issue_valid_o = !rst_i && !flush_i && issue_candidate_found;
  assign issue_fire = issue_valid_o;
  assign issue_uop_o = issue_valid_o ? entry_uop_q[issue_idx] : '0;
  assign cdb_wakeup_valid = cdb_valid_i && (cdb_phys_rd_i != '0);
  assign empty_o = count_q == '0;
  assign full_o = count_q == ISSUE_COUNT_WIDTH'(ISSUE_ENTRIES);
  assign count_o = count_q;

  // Reset and recovery Flush discard all speculative scheduling state. CDB p0
  // broadcasts are ignored, while a real same-cycle broadcast also initializes
  // the readiness of a newly dispatched entry so that its wakeup is not missed.
  always_ff @(posedge clk_i) begin
    if (rst_i || flush_i) begin
      entry_valid_q <= '0;
      entry_rs1_ready_q <= '0;
      entry_rs2_ready_q <= '0;
      count_q <= '0;
    end else begin
      if (cdb_wakeup_valid) begin
        for (wakeup_idx = 0; wakeup_idx < ISSUE_ENTRIES; wakeup_idx++) begin
          wakeup_scan_uop = entry_uop_q[wakeup_idx];
          if (entry_valid_q[wakeup_idx] && wakeup_scan_uop.rs1_used &&
              (wakeup_scan_uop.phys_rs1 == cdb_phys_rd_i)) begin
            entry_rs1_ready_q[wakeup_idx] <= 1'b1;
          end
          if (entry_valid_q[wakeup_idx] && wakeup_scan_uop.rs2_used &&
              (wakeup_scan_uop.phys_rs2 == cdb_phys_rd_i)) begin
            entry_rs2_ready_q[wakeup_idx] <= 1'b1;
          end
        end
      end
      if (dispatch_fire) begin
        entry_valid_q[dispatch_idx] <= 1'b1;
        entry_uop_q[dispatch_idx] <= dispatch_uop_i;
        entry_rs1_ready_q[dispatch_idx] <= !dispatch_uop_i.rs1_used || dispatch_rs1_ready_i || (cdb_wakeup_valid && (dispatch_uop_i.phys_rs1 == cdb_phys_rd_i));
        entry_rs2_ready_q[dispatch_idx] <= !dispatch_uop_i.rs2_used || dispatch_rs2_ready_i || (cdb_wakeup_valid && (dispatch_uop_i.phys_rs2 == cdb_phys_rd_i));
      end
      if (issue_fire) begin
        entry_valid_q[issue_idx] <= 1'b0;
        entry_rs1_ready_q[issue_idx] <= 1'b0;
        entry_rs2_ready_q[issue_idx] <= 1'b0;
      end
      if (dispatch_fire && !issue_fire) begin
        count_q <= count_q + 1'b1;
      end else if (!dispatch_fire && issue_fire) begin
        count_q <= count_q - 1'b1;
      end
    end
  end

endmodule
