// SPDX-License-Identifier: Apache-2.0
//
// Self-checking integration regression for the five-stage pipeline and L1
// I-cache. It checks architectural commits, same-line hits, cross-line refill,
// JAL redirect recovery, and backing-memory request counts.

`timescale 1ns/1ps

module rv32_pipeline_icache_tb;

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
  int unsigned backing_imem_request_count;

  rv32_pipeline_icache_top dut (
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
    #10000;
    $fatal(1, "rv32_pipeline_icache_tb: timeout");
  end

  // Core-to-cache hits do not appear on this backing-memory request counter.
  always_ff @(posedge clk) begin
    if (rst) begin
      backing_imem_request_count <= 0;
    end else if (imem_req_valid && imem_req_ready) begin
      backing_imem_request_count <= backing_imem_request_count + 1;
    end
  end

  // This program stays within one line and exercises dependent ALU commits.
  task automatic reset_and_load();
    int unsigned address;
    begin
      rst = 1'b1;
      memory_model.clear_memory();
      memory_model.write_word(32'h00000000, 32'h00500093);
      memory_model.write_word(32'h00000004, 32'h00308113);
      memory_model.write_word(32'h00000008, 32'h002081b3);
      for (address = 32'h0000_000c; address < 32'h0000_0020; address += 4) begin
        memory_model.write_word(address, 32'h00000013);
      end
      repeat(2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
    end
  endtask

  // This program jumps into the next line; x2 is on the flushed fall-through path.
  task automatic reset_and_load_redirect;
    int unsigned address;
    begin
      rst = 1'b1;
      memory_model.clear_memory();
      for (address = 32'h0000_0000; address < 32'h0000_0040; address += 4) begin
        memory_model.write_word(address, 32'h00000013);
      end
      memory_model.write_word(32'h0000_0000, 32'h0010_0093);
      memory_model.write_word(32'h0000_0004, 32'h01c0_026f);
      memory_model.write_word(32'h0000_0008, 32'h0630_0113);
      memory_model.write_word(32'h0000_0020, 32'h0070_0193);
      repeat(2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
    end
  endtask

  // Each call samples the next retirement event and checks architectural state.
  task automatic expect_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [4:0]  expected_rd_addr,
    input logic [31:0] expected_rd_wdata
  );
    int unsigned cycles;
    logic found_commit;
    begin
      cycles = 0;
      found_commit = 1'b0;
      while (!found_commit && cycles < 200) begin
        @(posedge clk);
        #1;
        cycles++;
        if (commit_valid) begin
          found_commit = 1'b1;
        end
      end
      if (!found_commit) begin
        $error("expect_commit: timeout waiting for PC=%08h", expected_pc);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("expect_commit: commit_pc mismatch: got %h, expected %h", commit_pc, expected_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("expect_commit: commit_instr mismatch: got %h, expected %h", commit_instr, expected_instr);
          errors++;
        end
        if (commit_rd_write !== 1'b1) begin
          $error("expect_commit: commit_rd_write mismatch: got %b, expected 1", commit_rd_write);
          errors++;
        end
        if (commit_rd_addr !== expected_rd_addr) begin
          $error("expect_commit: commit_rd_addr mismatch: got %d, expected %d", commit_rd_addr, expected_rd_addr);
          errors++;
        end
        if (commit_rd_wdata !== expected_rd_wdata) begin
          $error("expect_commit: commit_rd_wdata mismatch: got %h, expected %h", commit_rd_wdata, expected_rd_wdata);
          errors++;
        end
        if (commit_mem_valid !== 1'b0) begin
          $error("expect_commit: commit_mem_valid mismatch: got %b, expected 0", commit_mem_valid);
          errors++;
        end
        if (commit_trap !== 1'b0) begin
          $error("expect_commit: commit_trap mismatch: got %b, expected 0", commit_trap);
          errors++;
        end
        if (halted !== 1'b0) begin
          $error("expect_commit: halted mismatch: got %b, expected 0", halted);
          errors++;
        end
      end
    end
  endtask

  initial begin
    errors = 0;
    reset_and_load();
    expect_commit(32'h0000_0000, 32'h0050_0093, 5'd1, 32'd5);
    expect_commit(32'h0000_0004, 32'h0030_8113, 5'd2, 32'd8);
    expect_commit(32'h0000_0008, 32'h0020_81b3, 5'd3, 32'd13);
    if (backing_imem_request_count !== 8) begin
      $error("backing_imem_request_count mismatch: got %d, expected %d", backing_imem_request_count, 8);
      errors++;
    end

    reset_and_load_redirect();
    expect_commit(32'h0000_0000, 32'h0010_0093, 5'd1, 32'd1);
    expect_commit(32'h0000_0004, 32'h01c0_026f, 5'd4, 32'd8);
    expect_commit(32'h0000_0020, 32'h0070_0193, 5'd3, 32'd7);
    if (backing_imem_request_count !== 16) begin
      $error("backing_imem_request_count mismatch: got %d, expected %d", backing_imem_request_count, 16);
      errors++;
    end
    if (dut.core.regfile.registers[2] !== 32'd0) begin
      $error("register x2 mismatch: got %d, expected %d", dut.core.regfile.registers[2], 32'd0);
      errors++;
    end

    if (errors == 0) begin
      $display("rv32_pipeline_icache_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_pipeline_icache_tb: FAIL with %d errors", errors);
    end
  end

endmodule
