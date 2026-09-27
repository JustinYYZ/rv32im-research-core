// SPDX-License-Identifier: Apache-2.0
//
// Integration test for the out-of-order core behind separate blocking L1
// instruction and data caches.

`timescale 1ns/1ps

module rv32_ooo_l1_tb;

  logic clk;
  logic rst;

  logic        imem_req_valid;
  logic        imem_req_ready;
  logic [31:0] imem_req_addr;
  logic        imem_resp_valid;
  logic [31:0] imem_resp_data;
  logic        imem_resp_error;

  logic        dmem_req_valid;
  logic        dmem_req_ready;
  logic [31:0] dmem_req_addr;
  logic        dmem_req_write;
  logic [31:0] dmem_req_wdata;
  logic [3:0]  dmem_req_wstrb;
  logic        dmem_resp_valid;
  logic [31:0] dmem_resp_rdata;
  logic        dmem_resp_error;

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

  int unsigned dmem_read_count;
  int unsigned dmem_write_count;
  int unsigned errors;

  // Small caches make same-line hits and same-set conflicts deterministic.
  rv32_ooo_l1_top #(
    .ICACHE_BYTES(64),
    .ICACHE_LINE_BYTES(16),
    .DCACHE_BYTES(64),
    .DCACHE_LINE_BYTES(16)
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

  // Both cache backing ports share one byte-addressed memory image.
  rv32_simple_memory memory (
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

  // Count accepted backing-memory data transfers so hits can be distinguished
  // from line refills and dirty writebacks.
  always #5 clk = ~clk;

  always_ff @(posedge clk) begin
    if (rst) begin
      dmem_read_count <= 0;
      dmem_write_count <= 0;
    end else begin
      if (dmem_req_valid && dmem_req_ready && !dmem_req_write)
        dmem_read_count <= dmem_read_count + 1;
      if (dmem_req_valid && dmem_req_ready && dmem_req_write)
        dmem_write_count <= dmem_write_count + 1;
    end
  end

  // Minimal instruction constructors keep the directed program readable.
  function automatic logic [31:0] addi(input logic [4:0] rd, input logic [4:0] rs1, input logic [11:0] imm);
    return {imm, rs1, 3'b000, rd, 7'b0010011};
  endfunction

  function automatic logic [31:0] lw(input logic [4:0] rd, input logic [4:0] rs1, input logic [11:0] imm);
    return {imm, rs1, 3'b010, rd, 7'b0000011};
  endfunction

  function automatic logic [31:0] sw(input logic [4:0] rs2, input logic [4:0] rs1, input logic [11:0] imm);
    return {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011};
  endfunction

  // Commit checks are bounded so a deadlocked core cannot hang the regression.
  task automatic expect_reg(
    input logic [31:0] expected_pc,
    input logic [4:0] rd,
    input logic [31:0] value
  );
    int unsigned cycles;
    begin
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 1000) begin
        @(negedge clk);
        cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $fatal(1, "timeout waiting for register Commit at PC %08h", expected_pc);
      end else if (commit_pc !== expected_pc) begin
        $error("Commit PC mismatch: expected %h, got %h", expected_pc, commit_pc);
        errors++;
      end else if (commit_rd_write !== 1'b1 || commit_rd_addr !== rd || commit_rd_wdata !== value || commit_trap !== 1'b0) begin
        $error("Commit register write mismatch: expected rd=%0d value=%h, got rd=%0d value=%h", rd, value, commit_rd_addr, commit_rd_wdata);
        errors++;
      end

      @(posedge clk);
      #1;
    end
  endtask

  task automatic expect_memory(
    input logic [31:0] expected_pc,
    input logic write,
    input logic [31:0] expected_addr,
    input logic [31:0] value
  );
    int unsigned cycles;
    begin
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 1000) begin
        @(negedge clk);
        cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $fatal(1, "timeout waiting for memory Commit at PC %08h", expected_pc);
      end else if (commit_pc !== expected_pc) begin
        $error("Commit PC mismatch: expected %h, got %h", expected_pc, commit_pc);
        errors++;
      end else if (commit_mem_valid !== 1'b1 || commit_mem_write !== write || commit_mem_addr !== expected_addr || commit_trap !== 1'b0) begin
        $error("Commit memory identity mismatch: expected write=%b addr=%h, got write=%b addr=%h",
               write, expected_addr, commit_mem_write, commit_mem_addr);
        errors++;
      end

      if (write) begin
        if (commit_mem_wmask !== 4'b1111 || commit_mem_wdata !== value) begin
          $error("Commit memory write mismatch: expected value=%h, got value=%h", value, commit_mem_wdata);
          errors++;
        end
      end else begin
        if (commit_mem_rmask !== 4'b1111 || commit_mem_rdata !== value || commit_rd_wdata !== value) begin
          $error("Commit memory read mismatch: expected value=%h, got value=%h", value, commit_mem_rdata);
          errors++;
        end
      end
      @(posedge clk);
      #1;
    end
  endtask

  // The program covers a cold refill, a same-line hit, a Store hit, a read of
  // dirty data, a same-set conflict, dirty eviction, and precise ECALL halt.
  initial begin
    clk = 1'b0;
    rst = 1'b1;
    errors = 0;

    memory.clear_memory();

    memory.write_word(32'h0000_0100, 32'h1122_3344);
    memory.write_word(32'h0000_0104, 32'h5566_7788);
    memory.write_word(32'h0000_0140, 32'haabb_ccdd);

    memory.write_word(32'h0000_0000, addi(5'd1, 5'd0, 12'h100));
    memory.write_word(32'h0000_0004, lw(5'd2, 5'd1, 12'd0));
    memory.write_word(32'h0000_0008, lw(5'd3, 5'd1, 12'd4));
    memory.write_word(32'h0000_000c, addi(5'd4, 5'd0, 12'd42));
    memory.write_word(32'h0000_0010, sw(5'd4, 5'd1, 12'd0));
    memory.write_word(32'h0000_0014, lw(5'd5, 5'd1, 12'd0));
    memory.write_word(32'h0000_0018, lw(5'd6, 5'd1, 12'h040));
    memory.write_word(32'h0000_001c, 32'h0000_0073);

    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    expect_reg(32'h0000_0000, 5'd1, 32'h0000_0100);
    expect_memory(32'h0000_0004, 1'b0, 32'h0000_0100, 32'h1122_3344);
    expect_memory(32'h0000_0008, 1'b0, 32'h0000_0104, 32'h5566_7788);
    expect_reg(32'h0000_000c, 5'd4, 32'd42);
    expect_memory(32'h0000_0010, 1'b1, 32'h0000_0100, 32'd42);
    expect_memory(32'h0000_0014, 1'b0, 32'h0000_0100, 32'd42);
    expect_memory(32'h0000_0018, 1'b0, 32'h0000_0140, 32'haabb_ccdd);

    begin : wait_for_ecall
      int unsigned cycles;
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 1000) begin
        @(negedge clk);
        cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $fatal(1, "timeout waiting for ECALL Commit");
      end else if (commit_pc !== 32'h0000_001c) begin
        $error("Commit PC mismatch: expected %h, got %h", 32'h0000_001c, commit_pc);
        errors++;
      end else if (commit_trap !== 1'b1 || commit_trap_cause !== rv32_core_pkg::CORE_TRAP_ECALL) begin
        $error("Commit trap mismatch: expected ECALL, got cause=%0d", commit_trap_cause);
        errors++;
      end

      @(posedge clk);
      #1;
    end

    if (dmem_read_count !== 8 || dmem_write_count !== 4 || memory.read_word(32'h0000_0100) !== 32'd42) begin
      $error("L1 traffic/final-memory mismatch: reads=%0d writes=%0d data=%08h",
             dmem_read_count, dmem_write_count, memory.read_word(32'h0000_0100));
      errors++;
    end

    if (halted !== 1'b1) begin
      $error("Core did not halt after ECALL");
      errors++;
    end

    if (errors !== 0) begin
      $fatal(1, "rv32_ooo_l1_tb: Test failed with %0d errors", errors);
    end
    $display("rv32_ooo_l1_tb: PASS - OoO core, L1 hits, refill, and dirty eviction");
    $finish;
  end

  // This time-based guard still fires if the clock stops or becomes unknown.
  initial begin
    #200000;
    $fatal(1, "rv32_ooo_l1_tb: global timeout");
  end

endmodule
