// SPDX-License-Identifier: Apache-2.0
//
// Self-checking testbench for a misaligned reference-core reset address. The
// core must report one instruction-address-misaligned trap without issuing an
// instruction or data request, then remain inactive in HALT until reset.

`timescale 1ns/1ps

module rv32_reference_core_reset_pc_tb;

  logic clk;
  logic rst;

  logic imem_req_valid;
  logic dmem_req_valid;

  logic commit_valid;
  logic [31:0] commit_pc;
  logic [31:0] commit_instr;
  logic commit_rd_write;
  logic commit_mem_valid;
  logic commit_trap;
  rv32_core_pkg::trap_cause_e commit_trap_cause;
  logic halted;

  logic saw_request;
  int unsigned errors;

  rv32_reference_core #(
    .RESET_PC(32'h0000_0002)
  ) dut (
    .clk_i(clk),
    .rst_i(rst),
    .imem_req_valid_o(imem_req_valid),
    .imem_req_ready_i(1'b1),
    .imem_req_addr_o(),
    .imem_resp_valid_i(1'b0),
    .imem_resp_data_i(32'd0),
    .imem_resp_error_i(1'b0),
    .dmem_req_valid_o(dmem_req_valid),
    .dmem_req_ready_i(1'b1),
    .dmem_req_addr_o(),
    .dmem_req_write_o(),
    .dmem_req_wdata_o(),
    .dmem_req_wstrb_o(),
    .dmem_resp_valid_i(1'b0),
    .dmem_resp_rdata_i(32'd0),
    .dmem_resp_error_i(1'b0),
    .commit_valid_o(commit_valid),
    .commit_pc_o(commit_pc),
    .commit_instr_o(commit_instr),
    .commit_rd_write_o(commit_rd_write),
    .commit_rd_addr_o(),
    .commit_rd_wdata_o(),
    .commit_mem_valid_o(commit_mem_valid),
    .commit_mem_write_o(),
    .commit_mem_addr_o(),
    .commit_mem_rmask_o(),
    .commit_mem_wmask_o(),
    .commit_mem_rdata_o(),
    .commit_mem_wdata_o(),
    .commit_trap_o(commit_trap),
    .commit_trap_cause_o(commit_trap_cause),
    .halted_o(halted)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    #1000;
    $fatal(1, "rv32_reference_core_reset_pc_tb: timeout");
  end

  always_ff @(posedge clk) begin
    // Keep a sticky record so a one-cycle request cannot disappear before the
    // final HALT checks inspect it.
    if (rst) begin
      saw_request <= 1'b0;
    end else if (imem_req_valid || dmem_req_valid) begin
      saw_request <= 1'b1;
    end
  end

  initial begin
    rst = 1'b1;
    errors = 0;

    // Reset spans two rising edges; sampling after #1 observes updated state.
    repeat (2) @(posedge clk);
    #1;
    if (imem_req_valid !== 1'b0 || dmem_req_valid !== 1'b0 || commit_valid !== 1'b0 || halted !== 1'b0) begin
      $error("rv32_reference_core_reset_pc_tb: outputs active during reset");
      errors++;
    end

    // The first active edge detects RESET_PC misalignment before any fetch.
    @(negedge clk);
    #1;
    rst = 1'b0;
    @(posedge clk);
    #1;
    if (commit_valid !== 1'b1 || commit_trap !== 1'b1) begin
      $error("rv32_reference_core_reset_pc_tb: missing reset-PC trap commit");
      errors++;
    end
    if (commit_pc !== 32'h0000_0002) begin
      $error("rv32_reference_core_reset_pc_tb: wrong trap PC: expected 0x00000002, got 0x%h", commit_pc);
      errors++;
    end
    if (commit_instr !== 32'd0) begin
      $error("rv32_reference_core_reset_pc_tb: reset-PC trap report an instruction: %h", commit_instr);
      errors++;
    end
    if (commit_trap_cause !== rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED) begin
      $error("rv32_reference_core_reset_pc_tb: wrong reset-PC trap cause");
      errors++;
    end
    if (commit_rd_write !== 1'b0 || commit_mem_valid !== 1'b0) begin
      $error("rv32_reference_core_reset_pc_tb: reset-PC trap produced an architectural side effect");
      errors++;
    end

    // TRAP lasts one cycle and is followed by an inactive persistent HALT.
    @(posedge clk);
    #1;
    if (commit_valid !== 1'b0 || commit_trap !== 1'b0 || halted !== 1'b1) begin
      $error("rv32_reference_core_reset_pc_tb: reset-PC trap did not enter HALT");
      errors++;
    end
    if (imem_req_valid !== 1'b0 || dmem_req_valid !== 1'b0 || saw_request !== 1'b0) begin
      $error("rv32_reference_core_reset_pc_tb: reset-PC trap issued a memory request");
      errors++;
    end
    repeat (3) begin
      @(posedge clk);
      #1;
      if (halted !== 1'b1 || commit_valid !== 1'b0 || imem_req_valid !== 1'b0 || dmem_req_valid !== 1'b0 || saw_request !== 1'b0) begin
        $error("core did not remain inactive in HALT");
        errors++;
      end
    end

    // Finish explicitly so the independent timeout process cannot fire later.
    if (errors != 0) begin
      $fatal(1, "rv32_reference_core_reset_pc_tb: %0d errors detected",
      errors);
    end
    $display("rv32_reference_core_reset_pc_tb: PASS");
    $finish;
  end

endmodule
