// SPDX-License-Identifier: Apache-2.0
//
// Pipeline control-flow and redirect integration test.
//
// The program covers a taken branch, a not-taken branch, JAL, and JALR. The
// instruction responder deliberately waits multiple cycles so a redirect can
// occur while a younger sequential-path request is still outstanding. A
// correct core must discard that stale response and fetch the redirect target.

`timescale 1ns/1ps

module rv32_pipeline_control_flow_tb;

  localparam int unsigned IMEM_RESPONSE_DELAY = 2;

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
  int unsigned imem_delay_q;
  int unsigned errors;

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
        32'h0000_0004: instruction_at = 32'h0050_0113; // addi x2, x0, 5
        32'h0000_0008: instruction_at = 32'h0020_8463; // beq  x1, x2, 8
        32'h0000_000c: instruction_at = 32'h0630_0193; // addi x3, x0, 99; wrong path
        32'h0000_0010: instruction_at = 32'h0030_0193; // addi x3, x0, 3
        32'h0000_0014: instruction_at = 32'h0020_9463; // bne  x1, x2, 8; not taken
        32'h0000_0018: instruction_at = 32'h0080_026f; // jal  x4, 8
        32'h0000_001c: instruction_at = 32'h0630_0293; // addi x5, x0, 99; wrong path
        32'h0000_0020: instruction_at = 32'h02d0_0313; // addi x6, x0, 45
        32'h0000_0024: instruction_at = 32'h0003_03e7; // jalr x7, x6, 0
        32'h0000_0028: instruction_at = 32'h0580_0293; // addi x5, x0, 88; wrong path
        32'h0000_002c: instruction_at = 32'h0080_0413; // addi x8, x0, 8
        default:       instruction_at = 32'h0000_0013; // addi x0, x0, 0
      endcase
    end
  endfunction

  assign imem_req_ready = !imem_pending_q;
  assign imem_resp_valid = imem_pending_q && imem_delay_q == 0;
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
      imem_delay_q <= 0;
    end else if (imem_pending_q) begin
      if (imem_delay_q == 0) begin
        imem_pending_q <= 1'b0;
      end else begin
        imem_delay_q <= imem_delay_q - 1;
      end
    end else if (imem_req_valid && imem_req_ready) begin
      imem_pending_q <= 1'b1;
      imem_addr_q <= imem_req_addr;
      imem_delay_q <= IMEM_RESPONSE_DELAY;
    end
  end

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    #5000;
    $fatal(1, "rv32_pipeline_control_flow_tb: timeout");
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

  task automatic expect_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic expected_rd_write,
    input logic [4:0] expected_rd_addr,
    input logic [31:0] expected_rd_wdata
  );
    int cycles;
    begin
      // Compare one architectural commit and consume its pulse before returning.
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 100) begin
        @(posedge clk);
        #1;
        cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $error("rv32_pipeline_control_flow_tb: timeout waiting for commit");
        errors++;
      end else if (commit_pc !== expected_pc ||
                   commit_instr !== expected_instr ||
                   commit_rd_write !== expected_rd_write ||
                   commit_rd_addr !== expected_rd_addr ||
                   commit_rd_wdata !== expected_rd_wdata ||
                   commit_mem_valid !== 1'b0 ||
                   commit_trap !== 1'b0) begin
        $error("rv32_pipeline_control_flow_tb: commit values do not match expected");
        errors++;
      end

      @(posedge clk);
      #1;
    end
  endtask

  task automatic check_redirect_discard;
    logic [31:0] expected_target;
    begin
      // A redirect with an outstanding sequential fetch must mark and discard
      // that stale response before accepting the target instruction.
      wait (dut.ex_redirect_valid === 1'b1 &&
            dut.id_ex_q.valid === 1'b1 &&
            dut.id_ex_q.pc === 32'h0000_0008 &&
            dut.fetch_pending_q === 1'b1);
      #1;
      expected_target = dut.ex_redirect_target;

      if (expected_target !== 32'h0000_0010 ||
          imem_addr_q !== 32'h0000_000c) begin
        $error("rv32_pipeline_control_flow_tb: unexpected redirect target %h", expected_target);
        errors++;
      end
      @(posedge clk);
      #1;
      if (dut.fetch_discard_q !== 1'b1 ||
          dut.fetch_pc_q !== expected_target ||
          dut.if_id_q.valid !== 1'b0 ||
          dut.id_ex_q.valid !== 1'b0) begin
        $error("rv32_pipeline_control_flow_tb: unexpected pipeline state after redirect");
        errors++;
      end
      wait (imem_resp_valid === 1'b1);
      @(posedge clk);
      #1;
      if (dut.if_id_q.valid !== 1'b0 ||
          dut.fetch_pending_q !== 1'b0 ||
          dut.fetch_discard_q !== 1'b0 ||
          dut.fetch_pc_q !== expected_target) begin
        $error("rv32_pipeline_control_flow_tb: stale response was not discarded as expected");
        errors++;
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    errors = 0;
    reset_core();

    fork
      check_redirect_discard();
    join_none

    // Check the exact legal-path sequence; wrong-path sentinels must not retire.
    expect_commit(32'h0000_0000, 32'h0050_0093, 1'b1, 5'd1, 32'h0000_0005);
    expect_commit(32'h0000_0004, 32'h0050_0113, 1'b1, 5'd2, 32'h0000_0005);
    expect_commit(32'h0000_0008, 32'h0020_8463, 1'b0, 5'd0, 32'h0000_0000);
    expect_commit(32'h0000_0010, 32'h0030_0193, 1'b1, 5'd3, 32'h0000_0003);
    expect_commit(32'h0000_0014, 32'h0020_9463, 1'b0, 5'd0, 32'h0000_0000);
    expect_commit(32'h0000_0018, 32'h0080_026f, 1'b1, 5'd4, 32'h0000_001c);
    expect_commit(32'h0000_0020, 32'h02d0_0313, 1'b1, 5'd6, 32'h0000_002d);
    expect_commit(32'h0000_0024, 32'h0003_03e7, 1'b1, 5'd7, 32'h0000_0028);
    expect_commit(32'h0000_002c, 32'h0080_0413, 1'b1, 5'd8, 32'h0000_0008);

    wait fork;

    // Final register values include branch results and JAL/JALR link addresses.
    if (dut.regfile.registers[3] !== 32'h0000_0003 ||
        dut.regfile.registers[4] !== 32'h0000_001c ||
        dut.regfile.registers[5] !== 32'h0000_0000 ||
        dut.regfile.registers[6] !== 32'h0000_002d ||
        dut.regfile.registers[7] !== 32'h0000_0028 ||
        dut.regfile.registers[8] !== 32'h0000_0008) begin
      $error("rv32_pipeline_control_flow_tb: final regfile values do not match expected");
      errors++;
    end
    if (errors === 0) begin
      $display("rv32_pipeline_control_flow_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_pipeline_control_flow_tb: FAIL with %0d errors",
      errors);
    end
  end

endmodule
