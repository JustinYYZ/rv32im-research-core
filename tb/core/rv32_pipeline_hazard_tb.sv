// SPDX-License-Identifier: Apache-2.0
//
// Core-level RAW hazard and stall test with forwarding disabled.
//
// The program contains two true data dependencies. This test must prove both
// microarchitectural behavior (IF/ID holds and ID/EX receives a bubble during
// a stall) and architectural behavior (all three instructions commit with the
// correct register results).

`timescale 1ns/1ps

module rv32_pipeline_hazard_tb;

  logic clk;
  logic rst;

  logic imem_req_valid;
  logic imem_req_ready;
  logic [31:0] imem_req_addr;
  logic imem_resp_valid;
  logic [31:0] imem_resp_data;
  logic imem_resp_error;

  logic dmem_req_valid;
  logic dmem_req_ready;
  logic [31:0] dmem_req_addr;
  logic dmem_req_write;
  logic [31:0] dmem_req_wdata;
  logic [3:0] dmem_req_wstrb;
  logic dmem_resp_valid;
  logic [31:0] dmem_resp_rdata;
  logic dmem_resp_error;

  logic commit_valid;
  logic [31:0] commit_pc;
  logic [31:0] commit_instr;
  logic commit_rd_write;
  logic [4:0] commit_rd_addr;
  logic [31:0] commit_rd_wdata;
  logic commit_mem_valid;
  logic commit_mem_write;
  logic [31:0] commit_mem_addr;
  logic [3:0] commit_mem_rmask;
  logic [3:0] commit_mem_wmask;
  logic [31:0] commit_mem_rdata;
  logic [31:0] commit_mem_wdata;
  logic commit_trap;
  rv32_core_pkg::trap_cause_e commit_trap_cause;
  logic halted;

  int unsigned errors;
  int unsigned stall_cycles;

  rv32_pipeline_core #(
    .ENABLE_FORWARDING(1'b0)
  ) dut (
    .clk_i(clk),
    .rst_i(rst),
    .imem_req_valid_o(imem_req_valid),
    .imem_req_ready_i(imem_req_ready),
    .imem_req_addr_o(imem_req_addr),
    .imem_resp_valid_i(imem_resp_valid),
    .imem_resp_data_i(imem_resp_data),
    .imem_resp_error_i(imem_resp_error),
    .dmem_req_valid_o(dmem_req_valid),
    .dmem_req_ready_i(dmem_req_ready),
    .dmem_req_addr_o(dmem_req_addr),
    .dmem_req_write_o(dmem_req_write),
    .dmem_req_wdata_o(dmem_req_wdata),
    .dmem_req_wstrb_o(dmem_req_wstrb),
    .dmem_resp_valid_i(dmem_resp_valid),
    .dmem_resp_rdata_i(dmem_resp_rdata),
    .dmem_resp_error_i(dmem_resp_error),
    .commit_valid_o(commit_valid),
    .commit_pc_o(commit_pc),
    .commit_instr_o(commit_instr),
    .commit_rd_write_o(commit_rd_write),
    .commit_rd_addr_o(commit_rd_addr),
    .commit_rd_wdata_o(commit_rd_wdata),
    .commit_mem_valid_o(commit_mem_valid),
    .commit_mem_write_o(commit_mem_write),
    .commit_mem_addr_o(commit_mem_addr),
    .commit_mem_rmask_o(commit_mem_rmask),
    .commit_mem_wmask_o(commit_mem_wmask),
    .commit_mem_rdata_o(commit_mem_rdata),
    .commit_mem_wdata_o(commit_mem_wdata),
    .commit_trap_o(commit_trap),
    .commit_trap_cause_o(commit_trap_cause),
    .halted_o(halted)
  );

  rv32_simple_memory memory_model (
    .clk_i(clk),
    .rst_i(rst),
    .imem_req_valid_i(imem_req_valid),
    .imem_req_ready_o(imem_req_ready),
    .imem_req_addr_i(imem_req_addr),
    .imem_resp_valid_o(imem_resp_valid),
    .imem_resp_data_o(imem_resp_data),
    .imem_resp_error_o(imem_resp_error),
    .dmem_req_valid_i(dmem_req_valid),
    .dmem_req_ready_o(dmem_req_ready),
    .dmem_req_addr_i(dmem_req_addr),
    .dmem_req_write_i(dmem_req_write),
    .dmem_req_wdata_i(dmem_req_wdata),
    .dmem_req_wstrb_i(dmem_req_wstrb),
    .dmem_resp_valid_o(dmem_resp_valid),
    .dmem_resp_rdata_o(dmem_resp_rdata),
    .dmem_resp_error_o(dmem_resp_error)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    #2000;
    $fatal(1, "rv32_pipeline_hazard_tb: timeout");
  end

  always @(posedge clk) begin
    if (rst) begin
      stall_cycles <= 0;
    end else if (dut.id_stall) begin
      stall_cycles <= stall_cycles + 1;
    end
  end

  task automatic reset_and_load;
    begin
      rst = 1'b1;
      memory_model.clear_memory();
      memory_model.write_word(32'h0000_0000, 32'h0050_0093); // addi x1, x0, 5
      memory_model.write_word(32'h0000_0004, 32'h0030_8113); // addi x2, x1, 3
      memory_model.write_word(32'h0000_0008, 32'h0011_01b3); // add  x3, x2, x1
      repeat (2) @(posedge clk);
      @(negedge clk);
      #1;
      rst = 1'b0;
    end
  endtask

  task automatic check_stall_behavior;
    logic [31:0] held_pc;
    logic [31:0] held_instr;
    begin
      // Capture the dependent instruction when RAW control asserts a stall.
      wait (dut.id_stall === 1'b1);
      held_pc = dut.if_id_q.pc;
      held_instr = dut.if_id_q.instr;

      // A stall holds IF/ID and inserts a bubble into ID/EX.
      @(posedge clk);
      #1;
      if (dut.if_id_q.valid !== 1'b1 || dut.if_id_q.pc !== held_pc || dut.if_id_q.instr !== held_instr) begin
        $error("rv32_pipeline_hazard_tb: IF/ID pipeline stage not holding expected values");
        errors++;
      end
      if (dut.id_ex_q.valid !== 1'b0) begin
        $error("rv32_pipeline_hazard_tb: ID/EX is not a bubble during stall");
        errors++;
      end
    end
  endtask

  task automatic expect_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [4:0] expected_rd_addr,
    input logic [31:0] expected_rd_wdata
  );
    int cycles;
    begin
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 100) begin
        @(posedge clk);
        #1;
        cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $error("rv32_pipeline_hazard_tb: timeout waiting for commit");
        errors++;
      end else if (commit_pc !== expected_pc || commit_instr !== expected_instr || commit_rd_write !== 1'b1 || commit_rd_addr !== expected_rd_addr || commit_rd_wdata !== expected_rd_wdata || commit_mem_valid !== 1'b0 || commit_trap !== 1'b0) begin
        $error("rv32_pipeline_hazard_tb: commit mismatch for PC=0x%08h, instr=0x%08h, rd_addr=%d, rd_wdata=0x%08h", expected_pc, expected_instr, expected_rd_addr, expected_rd_wdata);
        errors++;
      end

      @(posedge clk);
      #1;
    end
  endtask

  initial begin
    rst = 1'b1;
    errors = 0;
    reset_and_load();

    fork
      check_stall_behavior();
    join_none

    expect_commit(32'h0000_0000, 32'h0050_0093, 5'd1, 32'd5);
    expect_commit(32'h0000_0004, 32'h0030_8113, 5'd2, 32'd8);
    expect_commit(32'h0000_0008, 32'h0011_01b3, 5'd3, 32'd13);
    wait fork;

    // The dependent program must both stall and retire with correct results.
    if (stall_cycles == 0) begin
      $error("rv32_pipeline_hazard_tb: no RAW stall cycles was detected");
      errors++;
    end

    if (dut.regfile.registers[1] !== 32'd5 ||
        dut.regfile.registers[2] !== 32'd8 ||
        dut.regfile.registers[3] !== 32'd13) begin
      $error("rv32_pipeline_hazard_tb: final regfile values incorrect: x1=%d, x2=%d, x3=%d", dut.regfile.registers[1], dut.regfile.registers[2], dut.regfile.registers[3]);
      errors++;
    end

    if (errors == 0) begin
      $display("rv32_pipeline_hazard_tb: PASS - %0d stall cycles", stall_cycles);
      $finish;
    end else begin
      $fatal(1, "rv32_pipeline_hazard_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
