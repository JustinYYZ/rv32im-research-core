// SPDX-License-Identifier: Apache-2.0
//
// Core-level forwarding integration test.
//
// A one-cycle instruction responder keeps dependent instructions close enough
// for the consumer in EX to overlap a producer in MEM/WB. The test must prove
// that the saved ID/EX operand can still contain an old regfile value while the
// forwarding path supplies the new value, no RAW stall occurs, and all three
// dependent instructions commit with correct architectural results.

`timescale 1ns/1ps

module rv32_pipeline_forwarding_tb;

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

  logic imem_pending_q;
  logic [31:0] imem_addr_q;
  int unsigned errors;
  int unsigned stall_cycles;

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

  function automatic logic [31:0] instruction_at(input logic [31:0] byte_addr);
    begin
      case (byte_addr)
        32'h0000_0000: instruction_at = 32'h0050_0093; // addi x1, x0, 5
        32'h0000_0004: instruction_at = 32'h0030_8113; // addi x2, x1, 3
        32'h0000_0008: instruction_at = 32'h0011_01b3; // add  x3, x2, x1
        default:       instruction_at = 32'h0000_0013; // addi x0, x0, 0
      endcase
    end
  endfunction

  assign imem_req_ready = !imem_pending_q;
  assign imem_resp_valid = imem_pending_q;
  assign imem_resp_data = instruction_at(imem_addr_q);
  assign imem_resp_error = 1'b0;
  assign dmem_req_ready = 1'b1;
  assign dmem_resp_valid = 1'b0;
  assign dmem_resp_rdata = 32'd0;
  assign dmem_resp_error = 1'b0;

  always_ff @(posedge clk) begin
    if (rst) begin
      imem_pending_q <= 1'b0;
      imem_addr_q <= 32'd0;
    end else if (imem_pending_q) begin
      imem_pending_q <= 1'b0;
    end else if (imem_req_valid && imem_req_ready) begin
      imem_pending_q <= 1'b1;
      imem_addr_q <= imem_req_addr;
    end
  end

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    #2000;
    $fatal(1, "rv32_pipeline_forwarding_tb: timeout");
  end

  always @(posedge clk) begin
    if (rst) begin
      stall_cycles <= 0;
    end else if (dut.id_stall) begin
      stall_cycles <= stall_cycles + 1;
    end
  end

  task automatic reset_core;
    begin
      rst = 1'b1;
      repeat (2) @(posedge clk);
      @(negedge clk);
      #1;
      rst = 1'b0;
    end
  endtask

  task automatic check_forwarding_behavior;
    begin
      // Observe ADDI x2, x1, 3 while it consumes the preceding result.
      wait (dut.id_ex_q.valid === 1'b1 && dut.id_ex_q.pc === 32'h0000_0004);
      #1;

      // The saved operand is stale while the EX forwarding path supplies x1=5;
      // this distinguishes real forwarding from a later regfile write.
      if (dut.id_ex_q.rs1_data !== 32'd0 ||
          dut.mem_wb_q.valid !== 1'b1 ||
          dut.mem_wb_q.pc !== 32'h0000_0000 ||
          dut.mem_wb_q.rd_write !== 1'b1 ||
          dut.mem_wb_q.rd_addr !== 5'd1 ||
          dut.mem_wb_q.rd_wdata !== 32'd5 ||
          dut.ex_rs1_data_forwarded !== 32'd5 ||
          dut.id_stall !== 1'b0) begin
        $error("rv32_pipeline_forwarding_tb: forwarding behavior not as expected");
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
        $error("rv32_pipeline_forwarding_tb: timeout waiting for commit");
        errors++;
      end else if (commit_pc !== expected_pc ||
                   commit_instr !== expected_instr ||
                   commit_rd_write !== 1'b1 ||
                   commit_rd_addr !== expected_rd_addr ||
                   commit_rd_wdata !== expected_rd_wdata ||
                   commit_mem_valid !== 1'b0 ||
                   commit_trap !== 1'b0) begin
        $error("rv32_pipeline_forwarding_tb: commit values do not match expected");
        errors++;
      end
        // Compare the complete architectural commit before consuming its pulse.

      @(posedge clk);
      #1;
    end
  endtask

  initial begin
    rst = 1'b1;
    errors = 0;
    reset_core();

    fork
      check_forwarding_behavior();
    join_none

    expect_commit(32'h0000_0000, 32'h0050_0093, 5'd1, 32'd5);
    expect_commit(32'h0000_0004, 32'h0030_8113, 5'd2, 32'd8);
    expect_commit(32'h0000_0008, 32'h0011_01b3, 5'd3, 32'd13);
    wait fork;

    // Forwarding must eliminate RAW stalls and preserve architectural results.
    if (stall_cycles !== 0) begin
      $error("rv32_pipeline_forwarding_tb: unexpected stalls occurred");
      errors++;
    end
    if (dut.regfile.registers[1] !== 32'd5 ||
        dut.regfile.registers[2] !== 32'd8 ||
        dut.regfile.registers[3] !== 32'd13) begin
      $error("rv32_pipeline_forwarding_tb: final regfile values do not match expected");
      errors++;
    end

    if (errors === 0) begin
      $display("rv32_pipeline_forwarding_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_pipeline_forwarding_tb: FAIL with %0d errors", errors);
    end
  end

endmodule
