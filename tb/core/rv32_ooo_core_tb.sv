// SPDX-License-Identifier: Apache-2.0
//
// Core-level regression for frontend/decode/backend integration, integer data
// dependencies, taken-branch recovery, wrong-path suppression, precise ECALL
// retirement, and sticky halt behavior.

`timescale 1ns/1ps

module rv32_ooo_core_tb;

  logic                       clk;
  logic                       rst;
  logic                       imem_req_valid;
  logic                       imem_req_ready;
  logic [31:0]                imem_req_addr;
  logic                       imem_resp_valid;
  logic [31:0]                imem_resp_data;
  logic                       imem_resp_error;
  logic                       imem_pending;
  logic [31:0]                imem_pending_addr;
  logic                       dmem_req_valid;
  logic                       dmem_req_ready;
  logic [31:0]                dmem_req_addr;
  logic                       dmem_req_write;
  logic [31:0]                dmem_req_wdata;
  logic [3:0]                 dmem_req_wstrb;
  logic                       dmem_resp_valid;
  logic [31:0]                dmem_resp_rdata;
  logic                       dmem_resp_error;
  logic                       commit_valid;
  logic [31:0]                commit_pc;
  logic [31:0]                commit_instr;
  logic                       commit_rd_write;
  logic [4:0]                 commit_rd_addr;
  logic [31:0]                commit_rd_wdata;
  logic                       commit_mem_valid;
  logic                       commit_mem_write;
  logic [31:0]                commit_mem_addr;
  logic [3:0]                 commit_mem_rmask;
  logic [3:0]                 commit_mem_wmask;
  logic [31:0]                commit_mem_rdata;
  logic [31:0]                commit_mem_wdata;
  logic                       commit_trap;
  rv32_core_pkg::trap_cause_e commit_trap_cause;
  logic                       halted;

  localparam int unsigned     PROGRAM_WORDS = 11;
  logic [31:0]                program_mem [0:PROGRAM_WORDS-1];

  int unsigned                errors;

  rv32_ooo_core dut (
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

  always #5 clk = ~clk;

  // One request may be outstanding. Each accepted request returns no earlier
  // than the following cycle so frontend request tracking is exercised.
  assign imem_req_ready = !rst && !imem_pending;
  assign imem_resp_valid = imem_pending;
  
  always_comb begin
    imem_resp_data = 32'b0;
    imem_resp_error = 1'b0;
    case (imem_pending_addr)
      32'h0000_0000: imem_resp_data = program_mem[0];
      32'h0000_0004: imem_resp_data = program_mem[1];
      32'h0000_0008: imem_resp_data = program_mem[2];
      32'h0000_000c: imem_resp_data = program_mem[3];
      32'h0000_0010: imem_resp_data = program_mem[4];
      32'h0000_0014: imem_resp_data = program_mem[5];
      32'h0000_0018: imem_resp_data = program_mem[6];
      32'h0000_001c: imem_resp_data = program_mem[7];
      32'h0000_0020: imem_resp_data = program_mem[8];
      32'h0000_0024: imem_resp_data = program_mem[9];
      32'h0000_0028: imem_resp_data = program_mem[10];
      default:       imem_resp_error = 1'b1;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      imem_pending <= 1'b0;
      imem_pending_addr <= 32'b0;
    end else begin
      if (imem_pending) begin
        imem_pending <= 1'b0;
      end else if (imem_req_valid && imem_req_ready) begin
        imem_pending <= 1'b1;
        imem_pending_addr <= imem_req_addr;
      end
    end
  end

  task automatic expect_commit(
    input string test_name,
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic expected_rd_write,
    input logic [4:0] expected_rd,
    input logic [31:0] expected_result
  );
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (commit_valid !== 1'b1 && timeout_cycles < 200) begin
        @(negedge clk);
        timeout_cycles++;
      end
      if (commit_valid !== 1'b1) begin
        $error("%s: timeout waiting for commit", test_name);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("%s: commit PC mismatch: expected 0x%08x, got 0x%08x", test_name, expected_pc, commit_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("%s: commit instruction mismatch: expected 0x%08x, got 0x%08x", test_name, expected_instr, commit_instr);
          errors++;
        end
        if (commit_rd_write !== expected_rd_write) begin
          $error("%s: commit rd_write mismatch: expected %b, got %b", test_name, expected_rd_write, commit_rd_write);
          errors++;
        end
        if (commit_rd_write) begin
          if (commit_rd_addr !== expected_rd) begin
            $error("%s: commit rd mismatch: expected %d, got %d", test_name, expected_rd, commit_rd_addr);
            errors++;
          end
          if (commit_rd_wdata !== expected_result) begin
            $error("%s: commit result mismatch: expected 0x%08x, got 0x%08x", test_name, expected_result, commit_rd_wdata);
            errors++;
          end
        end
        if (commit_mem_valid !== 1'b0 || commit_trap !== 1'b0) begin
          $error("%s: commit should not have memory or trap signals asserted", test_name);
          errors++;
        end
        @(posedge clk);
        #1;
      end
    end
  endtask

  task automatic expect_trap(
    input string test_name,
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input rv32_core_pkg::trap_cause_e expected_cause
  );
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (commit_valid !== 1'b1 && timeout_cycles < 200) begin
        @(negedge clk);
        timeout_cycles++;
      end
      if (commit_valid !== 1'b1) begin
        $error("%s: timeout waiting for commit", test_name);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("%s: commit PC mismatch: expected 0x%08x, got 0x%08x", test_name, expected_pc, commit_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("%s: commit instruction mismatch: expected 0x%08x, got 0x%08x", test_name, expected_instr, commit_instr);
          errors++;
        end
        if (commit_trap !== 1'b1) begin
          $error("%s: expected trap, but commit_trap is not asserted", test_name);
          errors++;
        end else if (commit_trap_cause !== expected_cause) begin
          $error("%s: trap cause mismatch: expected %0d, got %0d", test_name, expected_cause, commit_trap_cause);
          errors++;
        end
        if (commit_mem_valid !== 1'b0 || commit_rd_write !== 1'b0) begin
          $error("%s: commit should not have memory or rd_write signals asserted", test_name);
          errors++;
        end
      end
      @(posedge clk);
      #1;

      if (halted !== 1'b1) begin
        $error("%s: expected core to halt after trap, but halted signal is not asserted", test_name);
        errors++;
      end
      repeat (5) begin
        @(negedge clk);
        if (commit_valid !== 1'b0) begin
          $error("%s: commit should not be valid after trap and halt", test_name);
          errors++;
        end
        if (imem_req_valid !== 1'b0) begin
          $error("%s: imem_req_valid should not be asserted after trap and halt", test_name);
          errors++;
        end
      end
    end
  endtask

  // The program checks ordered integer Commit, a taken BEQ whose sequential
  // successor must not retire, and ECALL as the representative precise-trap
  // path. Decoder and frontend unit regressions cover the remaining encodings
  // and stale-response epoch behavior independently.

  initial begin
    errors = 0;
    clk = 1'b0;
    rst = 1'b1;
    dmem_req_ready = 1'b0;
    dmem_resp_valid = 1'b0;
    dmem_resp_rdata = 32'b0;
    dmem_resp_error = 1'b0;

    program_mem[0]  = 32'h1234_50b7; // LUI x1, 0x12345000
    program_mem[1]  = 32'h0000_1117; // AUIPC x2, 0x1
    program_mem[2]  = 32'h00a0_8193; // ADDI x3, x1, 10
    program_mem[3]  = 32'h0140_0213; // ADDI x4, x0, 20
    program_mem[4]  = 32'h0041_82b3; // ADD x5, x3, x4
    program_mem[5]  = 32'h0012_c333; // XOR x6, x5, x1
    program_mem[6]  = 32'h0063_0463; // BEQ x6, x6, +8: taken to 0x20
    program_mem[7]  = 32'h0630_0393; // ADDI x7, x0, 99: wrong path
    program_mem[8]  = 32'h0070_0413; // ADDI x8, x0, 7: branch target
    program_mem[9]  = 32'h0000_0073; // ECALL
    program_mem[10] = 32'h0370_0493; // ADDI x9, x0, 55: should not be executed

    repeat (2) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    
    expect_commit("LUI", 32'h0000_0000, program_mem[0], 1'b1, 5'd1, 32'h1234_5000);
    expect_commit("AUIPC", 32'h0000_0004, program_mem[1], 1'b1, 5'd2, 32'h0000_1004);
    expect_commit("ADDI dependency", 32'h0000_0008, program_mem[2], 1'b1, 5'd3, 32'h1234_500a);
    expect_commit("ADDI independent", 32'h0000_000c, program_mem[3], 1'b1, 5'd4, 32'h0000_0014);
    expect_commit("ADD", 32'h0000_0010, program_mem[4], 1'b1, 5'd5, 32'h1234_501e);
    expect_commit("XOR", 32'h0000_0014, program_mem[5], 1'b1, 5'd6, 32'h0000_001e);
    expect_commit("BEQ taken", 32'h0000_0018, program_mem[6], 1'b0, 5'd0, 32'b0);
    expect_commit("ADDI branch target", 32'h0000_0020, program_mem[8], 1'b1, 5'd8, 32'h0000_0007);
    expect_trap("ECALL trap", 32'h0000_0024, program_mem[9], rv32_core_pkg::CORE_TRAP_ECALL);

    if (errors !== 0) begin
      $fatal(1, "rv32_ooo_core_tb: %0d errors detected", errors);
    end
    $display("rv32_ooo_core_tb: PASSED");
    $finish;
  end

endmodule
