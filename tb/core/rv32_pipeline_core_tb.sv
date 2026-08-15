// SPDX-License-Identifier: Apache-2.0
//
// Basic self-checking integration test for the five-stage pipeline.
// It checks blocking fetch handshakes, one instruction through every stage,
// architectural commit pulses, and final register-file state.

`timescale 1ns/1ps

module rv32_pipeline_core_tb;

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

  logic memory_imem_req_ready;
  logic allow_imem_request;

  rv32_pipeline_core dut (
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
    .imem_req_valid_i(imem_req_valid && allow_imem_request),
    .imem_req_ready_o(memory_imem_req_ready),
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
    $fatal(1, "rv32_pipeline_core_tb: timeout");
  end

  task automatic reset_and_load;
    begin
      rst = 1'b1;
      memory_model.clear_memory();
      memory_model.write_word(32'h0000_0000, 32'h0050_0093); // ADDI x1, x0, 5
      memory_model.write_word(32'h0000_0004, 32'h0080_0113); // ADDI x2, x0, 8
      memory_model.write_word(32'h0000_0008, 32'h00b0_0193); // ADDI x3, x0, 11
      repeat (2) @(posedge clk);
      #1;

      if (imem_req_valid !== 1'b0 || dmem_req_valid !== 1'b0 || commit_valid !== 1'b0 || halted !== 1'b0) begin
        $error("rv32_pipeline_core_tb: reset_and_load: request, commit or halt active during reset");
        errors++;
      end

      @(negedge clk);
      #1;
      rst = 1'b0;
    end
  endtask

  // The first fetch must hold RESET_PC until accepted and must not be reissued
  // while its response is outstanding.

  assign imem_req_ready = allow_imem_request && memory_imem_req_ready;

  task automatic check_first_fetch;
    begin
      allow_imem_request = 1'b0;
      #1;

      if (imem_req_valid !== 1'b1 || imem_req_addr !== 32'd0) begin
        $error("rv32_pipeline_core_tb: check_first_fetch: first instruction request is incorrect");
        errors++;
      end

      repeat (2) begin
        @(posedge clk);
        #1;
        if (imem_req_valid !== 1'b1 || imem_req_addr !== 32'd0 || dut.fetch_pending_q !== 1'b0) begin
          $error("rv32_pipeline_core_tb: check_first_fetch: instruction request changed before ready");
          errors++;
        end
      end

      @(negedge clk);
      allow_imem_request = 1'b1;
      #1;

      if (imem_req_ready !== 1'b1 || imem_req_valid !== 1'b1) begin
        $error("rv32_pipeline_core_tb: check_first_fetch: instruction request not ready when allowed");
        errors++;
      end

      @(posedge clk);
      #1;

      if (dut.fetch_pending_q !== 1'b1) begin
        $error("rv32_pipeline_core_tb: check_first_fetch: fetch_pending_q not set after first request accepted");
        errors++;
      end

      if (imem_req_valid !== 1'b0) begin
        $error("rv32_pipeline_core_tb: check_first_fetch: second fetch request issued while first response is outstanding");
        errors++;
      end
    end
  endtask

  // Observe the first ADDI at each pipeline boundary and at commit.
  task automatic check_addi_pipeline;
    begin
      wait (imem_resp_valid === 1'b1);
      #1;

      if(imem_resp_error !== 1'b0 || imem_resp_data !== 32'h0050_0093) begin
        $error("rv32_pipeline_core_tb: check_addi_pipeline: instruction memory response is incorrect");
        errors++;
      end

      @(posedge clk);
      #1;
      if(dut.if_id_q.valid !== 1'b1 ||
         dut.if_id_q.pc !== 32'h0000_0000 ||
         dut.if_id_q.instr !== 32'h0050_0093) begin
        $error("rv32_pipeline_core_tb: check_addi_pipeline: IF/ID payload is incorrect");
        errors++;
      end

      @(posedge clk);
      #1;
      if (dut.id_ex_q.valid !== 1'b1 ||
          dut.id_ex_q.pc !== 32'd0 ||
          dut.id_ex_q.instr !== 32'h0050_0093 ||
          dut.id_ex_q.rs1_data !== 32'd0 ||
          dut.id_ex_q.imm !== 32'd5 ||
          dut.id_ex_q.rd_addr !== 5'd1 ||
          dut.id_ex_q.alu_op !== rv32_pkg::ALU_ADD ||
          dut.id_ex_q.reg_write !== 1'b1) begin
        $error("rv32_pipeline_core_tb: check_addi_pipeline: ADDI did not enter ID/EX correctly");
        errors++;
      end

      @(posedge clk);
      #1;
      if (dut.ex_mem_q.valid !== 1'b1 ||
          dut.ex_mem_q.pc !== 32'd0 ||
          dut.ex_mem_q.instr !== 32'h0050_0093 ||
          dut.ex_mem_q.rd_write !== 1'b1 ||
          dut.ex_mem_q.rd_addr !== 5'd1 ||
          dut.ex_mem_q.rd_wdata !== 32'd5) begin
        $error("rv32_pipeline_core_tb: check_addi_pipeline: ADDI did not enter EX/MEM correctly");
        errors++;
      end

      @(posedge clk);
      #1;
      if (dut.mem_wb_q.valid !== 1'b1 ||
          commit_valid !== 1'b1 ||
          commit_pc !== 32'h0 ||
          commit_instr !== 32'h0050_0093 ||
          commit_rd_write !== 1'b1 ||
          commit_rd_addr !== 5'd1 ||
          commit_rd_wdata !== 32'd5 ||
          commit_mem_valid !== 1'b0 ||
          commit_trap !== 1'b0 ||
          dut.if_id_q.valid !== 1'b1 ||
          dut.if_id_q.pc !== 32'h0000_0004 ||
          dut.if_id_q.instr !== 32'h0080_0113) begin
        $error("rv32_pipeline_core_tb: check_addi_pipeline: ADDI commit is incorrect");
        errors++;
      end

      @(posedge clk);
      #1;
      if (commit_valid !== 1'b0) begin
        $error("rv32_pipeline_core_tb: check_addi_pipeline: commit_valid did not return to zero after commit");
        errors++;
      end
      if (commit_rd_write !== 1'b0) begin
        $error("rv32_pipeline_core_tb: check_addi_pipeline: commit_rd_write did not return to zero after commit");
        errors++;
      end
      if (dut.regfile.registers[1] !== 32'd5) begin
        $error("rv32_pipeline_core_tb: check_addi_pipeline: register file x1 does not contain 5 after commit");
        errors++;
      end
    end
  endtask

  // Subsequent commits are checked through the architectural interface.
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
        $error("rv32_pipeline_core_tb: expect_commit: timeout waiting for commit");
        errors++;
      end else if (commit_pc !== expected_pc ||
                   commit_instr !== expected_instr ||
                   commit_rd_write !== 1'b1 ||
                   commit_rd_addr !== expected_rd_addr ||
                   commit_rd_wdata !== expected_rd_wdata ||
                   commit_mem_valid !== 1'b0 ||
                   commit_trap !== 1'b0) begin
        $error("rv32_pipeline_core_tb: expect_commit: commit values do not match expected");
        errors++;
      end

      @(posedge clk);
      #1;

      if (commit_valid !== 1'b0) begin
        $error("rv32_pipeline_core_tb: expect_commit: commit_valid did not return to zero after commit");
        errors++;
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    errors = 0;
    reset_and_load();
    check_first_fetch();
    check_addi_pipeline();
    expect_commit(32'd4, 32'h0080_0113, 5'd2, 32'd8);
    expect_commit(32'd8, 32'h00b0_0193, 5'd3, 32'd11);
    if (dut.regfile.registers[1] !== 32'd5) begin
      $error("rv32_pipeline_core_tb: final check: register file x1 does not contain 5");
      errors++;
    end
    if (dut.regfile.registers[2] !== 32'd8) begin
      $error("rv32_pipeline_core_tb: final check: register file x2 does not contain 8");
      errors++;
    end
    if (dut.regfile.registers[3] !== 32'd11) begin
      $error("rv32_pipeline_core_tb: final check: register file x3 does not contain 11");
      errors++;
    end
    if (errors != 0) begin
      $fatal(1, "rv32_pipeline_core_tb: %0d errors detected", errors);
    end
    $display("rv32_pipeline_core_tb: PASS");
    $finish;
  end

endmodule
