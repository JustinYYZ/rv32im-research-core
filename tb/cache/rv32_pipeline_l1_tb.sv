// SPDX-License-Identifier: Apache-2.0
//
// Self-checking integration regression for the five-stage pipeline with
// separate blocking L1 instruction and data caches.

`timescale 1ns/1ps

module rv32_pipeline_l1_tb;

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
  int unsigned backing_dmem_read_count;
  int unsigned backing_dmem_write_count;

  rv32_pipeline_l1_top dut (
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

  rv32_simple_memory #(
    .WORDS(16384)
  ) memory_model (
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
    $fatal(1, "rv32_pipeline_l1_tb: timeout");
  end

  // Core-to-cache hits do not appear on this backing-memory request counter.
  always_ff @(posedge clk) begin
    if (rst) begin
      backing_imem_request_count <= 0;
      backing_dmem_read_count <= 0;
      backing_dmem_write_count <= 0;
    end else if (imem_req_valid && imem_req_ready) begin
      backing_imem_request_count <= backing_imem_request_count + 1;
    end
    if (!rst && dmem_req_valid && dmem_req_ready) begin
      if (dmem_req_write) begin
        backing_dmem_write_count <= backing_dmem_write_count + 1;
      end else begin
        backing_dmem_read_count <= backing_dmem_read_count + 1;
      end
    end
  end

  // Commit checkers are shared by the I-cache and D-cache test scenarios.
  task automatic expect_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [4:0] expected_rd_addr,
    input logic [31:0] expected_rd_wdata
  );
    int unsigned cycles;
    logic found_commit;
    begin
      cycles = 0;
      found_commit = 1'b0;
      while (!found_commit && cycles < 400) begin
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
        if (commit_rd_write !== 1'b1 || commit_rd_addr !== expected_rd_addr || commit_rd_wdata !== expected_rd_wdata) begin
          $error("expect_commit: register write result mismatch");
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

  task automatic expect_load_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [4:0] expected_rd_addr,
    input logic [31:0] expected_rd_wdata,
    input logic [31:0] expected_mem_addr,
    input logic [31:0] expected_mem_rdata
  );
    int unsigned cycles;
    logic found_commit;
    begin
      cycles = 0;
      found_commit = 1'b0;

      while (!found_commit && cycles < 400) begin
        @(posedge clk);
        #1;
        cycles++;
        if (commit_valid) begin
          found_commit = 1'b1;
        end
      end

      if (!found_commit) begin
        $error("expect_load_commit: timeout waiting for PC=%08h", expected_pc);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("expect_load_commit: PC got %08h, expected %08h", commit_pc, expected_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("expect_load_commit: instruction got %08h, expected %08h", commit_instr, expected_instr);
          errors++;
        end
        if (commit_rd_write !== 1'b1 || commit_rd_addr !== expected_rd_addr || commit_rd_wdata !== expected_rd_wdata) begin
          $error("expect_load_commit: register write result mismatch");
          errors++;
        end
        if (commit_mem_valid !== 1'b1 || commit_mem_write !== 1'b0) begin
          $error("expect_load_commit: expected a load commit");
          errors++;
        end
        if (commit_mem_addr !== expected_mem_addr) begin
          $error("expect_load_commit: address got %08h, expected %08h", commit_mem_addr, expected_mem_addr);
          errors++;
        end
        if (commit_mem_rmask !== 4'b1111 || commit_mem_wmask !== 4'b0000) begin
          $error("expect_load_commit: load mask mismatch");
          errors++;
        end
        if (commit_mem_rdata !== expected_mem_rdata || commit_mem_wdata !== 32'd0) begin
          $error("expect_load_commit: memory data mismatch");
          errors++;
        end
        if (commit_trap !== 1'b0) begin
          $error("expect_load_commit: unexpected trap");
          errors++;
        end
      end
    end
  endtask

  task automatic expect_store_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [31:0] expected_mem_addr,
    input logic [3:0] expected_mem_wmask,
    input logic [31:0] expected_mem_wdata
  );
    int unsigned cycles;
    logic found_commit;
    begin
      cycles = 0;
      found_commit = 1'b0;
      while (!found_commit && cycles < 400) begin
        @(posedge clk);
        #1;
        cycles++;
        if (commit_valid) begin
          found_commit = 1'b1;
        end
      end
      if (!found_commit) begin
        $error("expect_store_commit: timeout waiting for PC=%08h", expected_pc);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("expect_store_commit: PC got %08h, expected %08h", commit_pc, expected_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("expect_store_commit: instruction got %08h, expected %08h", commit_instr, expected_instr);
          errors++;
        end
        if (commit_rd_write !== 1'b0 || commit_rd_addr !== 5'd0 || commit_rd_wdata !== 32'd0) begin
          $error("expect_store_commit: store unexpectedly wrote to a register");
          errors++;
        end
        if (commit_mem_valid !== 1'b1 || commit_mem_write !== 1'b1) begin
          $error("expect_store_commit: expected a store commit");
          errors++;
        end
        if (commit_mem_addr !== expected_mem_addr) begin
          $error("expect_store_commit: address got %08h, expected %08h", commit_mem_addr, expected_mem_addr);
          errors++;
        end
        if (commit_mem_rmask !== 4'b0000 || commit_mem_wmask !== expected_mem_wmask) begin
          $error("expect_store_commit: store mask mismatch");
          errors++;
        end
        if (commit_mem_rdata !== 32'd0 || commit_mem_wdata !== expected_mem_wdata) begin
          $error("expect_store_commit: memory data mismatch");
          errors++;
        end
        if (commit_trap !== 1'b0) begin
          $error("expect_store_commit: unexpected trap");
          errors++;
        end
      end
    end
  endtask

  task automatic expect_trap_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input rv32_core_pkg::trap_cause_e expected_trap_cause
  );
    int unsigned cycles;
    logic found_commit;
    begin
      cycles = 0;
      found_commit = 1'b0;
      while (!found_commit && cycles < 400) begin
        @(posedge clk);
        #1;
        cycles++;
        if (commit_valid) begin
          found_commit = 1'b1;
        end
      end
      if (!found_commit) begin
        $error("expect_trap_commit: timeout waiting for PC=%08h", expected_pc);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("expect_trap_commit: PC got %08h, expected %08h", commit_pc, expected_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("expect_trap_commit: instruction got %08h, expected %08h", commit_instr, expected_instr);
          errors++;
        end
        if (commit_trap !== 1'b1 || commit_trap_cause !== expected_trap_cause) begin
          $error("expect_trap_commit: trap mismatch");
          errors++;
        end
        if (commit_rd_write !== 1'b0 || commit_rd_addr !== 5'd0 || commit_rd_wdata !== 32'd0) begin
          $error("expect_trap_commit: trap had register side effects");
          errors++;
        end
        if (commit_mem_valid !== 1'b0 || commit_mem_write !== 1'b0 || commit_mem_addr !== 32'd0 || commit_mem_rmask !== 4'b0000 || commit_mem_wmask !== 4'b0000 || commit_mem_rdata !== 32'd0 || commit_mem_wdata !== 32'd0) begin
          $error("expect_trap_commit: trap had memory side effects");
          errors++;
        end
        if (halted !== 1'b0) begin
          $error("expect_trap_commit: halted asserted during trap commit");
          errors++;
        end
      end
    end
  endtask

  // I-cache tests keep instruction/data effects simple so backing instruction
  // requests can be counted independently from pipeline retirement behavior.
  task automatic test_icache_same_line;
    int unsigned address;
    begin
      rst = 1'b1;
      memory_model.clear_memory();
      memory_model.write_word(32'h0000_0000, 32'h0050_0093); // ADDI x1, x0, 5
      memory_model.write_word(32'h0000_0004, 32'h0030_8113); // ADDI x2, x1, 3
      memory_model.write_word(32'h0000_0008, 32'h0020_81b3); // ADD  x3, x1, x2
      for (address = 32'h0000_000c; address < 32'h0000_0020; address += 4) begin
        memory_model.write_word(address, 32'h0000_0013);
      end
      repeat (2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
      expect_commit(32'h0000_0000, 32'h0050_0093, 5'd1, 32'd5);
      expect_commit(32'h0000_0004, 32'h0030_8113, 5'd2, 32'd8);
      expect_commit(32'h0000_0008, 32'h0020_81b3, 5'd3, 32'd13);
      if (backing_imem_request_count !== 8) begin
        $error("test_icache_same_line: backing request count got %0d, expected 8", backing_imem_request_count);
        errors++;
      end
    end
  endtask

  // JAL redirects fetch to the next line; x2 belongs to the flushed path.
  task automatic test_icache_redirect;
    int unsigned address;
    begin
      rst = 1'b1;
      memory_model.clear_memory();
      for (address = 32'h0000_0000; address < 32'h0000_0040; address += 4) begin
        memory_model.write_word(address, 32'h0000_0013);
      end
      memory_model.write_word(32'h0000_0000, 32'h0010_0093); // ADDI x1, x0, 1
      memory_model.write_word(32'h0000_0004, 32'h01c0_026f); // JAL  x4, 0x20
      memory_model.write_word(32'h0000_0008, 32'h0630_0113); // ADDI x2, x0, 99; flushed
      memory_model.write_word(32'h0000_0020, 32'h0070_0193); // ADDI x3, x0, 7
      repeat (2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
      expect_commit(32'h0000_0000, 32'h0010_0093, 5'd1, 32'd1);
      expect_commit(32'h0000_0004, 32'h01c0_026f, 5'd4, 32'd8);
      expect_commit(32'h0000_0020, 32'h0070_0193, 5'd3, 32'd7);
      if (backing_imem_request_count !== 16) begin
        $error("test_icache_redirect: backing request count got %0d, expected 16", backing_imem_request_count);
        errors++;
      end
      if (dut.core.regfile.registers[2] !== 32'd0) begin
        $error("test_icache_redirect: flushed instruction wrote x2");
        errors++;
      end
    end
  endtask

  // D-cache tests exercise architectural memory commits and backing-memory
  // traffic separately: cache hits never appear on the backing port counters.
  // The first cold load refills one line; the second load must hit that line
  // without increasing the backing-memory read count.
  task automatic test_dcache_load_miss_and_hit;
    int unsigned address;
    begin
      rst = 1'b1;
      memory_model.clear_memory();
      memory_model.write_word(32'h0000_0000, 32'h1000_0093); // ADDI x1, x0, 256
      memory_model.write_word(32'h0000_0004, 32'h0000_a103); // LW x2, 0(x1)
      memory_model.write_word(32'h0000_0008, 32'h0040_a183); // LW x3, 4(x1)
      for (address = 32'h0000_000c; address < 32'h0000_0020; address += 4) begin
        memory_model.write_word(address, 32'h00000013);
      end
      memory_model.write_word(32'h0000_0100, 32'h1122_3344);
      memory_model.write_word(32'h0000_0104, 32'h5566_7788);
      repeat(2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
      expect_commit(32'h0000_0000, 32'h1000_0093, 5'd1, 32'h0000_0100);
      expect_load_commit(32'h0000_0004, 32'h0000_a103, 5'd2, 32'h1122_3344, 32'h0000_0100, 32'h1122_3344);
      if (backing_dmem_read_count !== 8) begin
        $error("test_dcache_load_miss_and_hit: backing_dmem_read_count got %d, expected 8", backing_dmem_read_count);
        errors++;
      end
      expect_load_commit(32'h0000_0008, 32'h0040_a183, 5'd3, 32'h5566_7788, 32'h0000_0104, 32'h5566_7788);
      if (backing_dmem_read_count !== 8) begin
        $error("test_dcache_load_miss_and_hit: backing_dmem_read_count got %d, expected 8", backing_dmem_read_count);
        errors++;
      end
      if (backing_dmem_write_count !== 0) begin
        $error("test_dcache_load_miss_and_hit: backing_dmem_write_count got %d, expected 0", backing_dmem_write_count);
        errors++;
      end
    end
  endtask

  // SB, SH, and SW must update only selected byte lanes. Following loads check
  // both the architectural commit metadata and the merged cache-line contents.
  task automatic test_dcache_store_merge;
    int unsigned address;
    begin
      rst = 1'b1;
      memory_model.clear_memory();
      memory_model.write_word(32'h0000_0000, 32'h1000_0093); // ADDI x1, x0, 256
      memory_model.write_word(32'h0000_0004, 32'h0aa0_0113); // ADDI x2, x0, 170
      memory_model.write_word(32'h0000_0008, 32'h0000_a183); // LW x3, 0(x1)
      memory_model.write_word(32'h0000_000c, 32'h0020_80a3); // SB x2, 1(x1)
      memory_model.write_word(32'h0000_0010, 32'h0000_a203); // LW x4, 0(x1)
      memory_model.write_word(32'h0000_0014, 32'h5cc0_0293); // ADDI x5, x0, 0x5cc
      memory_model.write_word(32'h0000_0018, 32'h0050_9123); // SH   x5, 2(x1)
      memory_model.write_word(32'h0000_001c, 32'h0000_a303); // LW   x6, 0(x1)
      memory_model.write_word(32'h0000_0020, 32'h1230_0393); // ADDI x7, x0, 0x123
      memory_model.write_word(32'h0000_0024, 32'h0070_a223); // SW   x7, 4(x1)
      memory_model.write_word(32'h0000_0028, 32'h0040_a403); // LW   x8, 4(x1)
      for (address = 32'h0000_002c; address < 32'h0000_0040; address += 4) begin
        memory_model.write_word(address, 32'h00000013);
      end
      memory_model.write_word(32'h0000_0100, 32'h1122_3344);
      memory_model.write_word(32'h0000_0104, 32'h5566_7788);
      repeat(2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
      expect_commit(32'h0000_0000, 32'h1000_0093, 5'd1, 32'h0000_0100);
      expect_commit(32'h0000_0004, 32'h0aa0_0113, 5'd2, 32'h0000_00aa);
      expect_load_commit(32'h0000_0008, 32'h0000_a183, 5'd3, 32'h1122_3344, 32'h0000_0100, 32'h1122_3344);
      expect_store_commit(32'h0000_000c, 32'h0020_80a3, 32'h0000_0100, 4'b0010, 32'h0000_aa00);
      expect_load_commit(32'h0000_0010, 32'h0000_a203, 5'd4, 32'h1122_aa44, 32'h0000_0100, 32'h1122_aa44);
      expect_commit(32'h0000_0014, 32'h5cc0_0293, 5'd5, 32'h0000_05cc);
      expect_store_commit(32'h0000_0018, 32'h0050_9123, 32'h0000_0100, 4'b1100, 32'h05cc_0000);
      expect_load_commit(32'h0000_001c, 32'h0000_a303, 5'd6, 32'h05cc_aa44, 32'h0000_0100, 32'h05cc_aa44);
      expect_commit(32'h0000_0020, 32'h1230_0393, 5'd7, 32'h0000_0123);
      expect_store_commit(32'h0000_0024, 32'h0070_a223, 32'h0000_0104, 4'b1111, 32'h0000_0123);
      expect_load_commit(32'h0000_0028, 32'h0040_a403, 5'd8, 32'h0000_0123, 32'h0000_0104, 32'h0000_0123);
      if (backing_dmem_read_count !== 8) begin
        $error("test_dcache_store_merge: backing read count got %d, expected 8", backing_dmem_read_count);
        errors++;
      end
      if (backing_dmem_write_count !== 0) begin
        $error("test_dcache_store_merge: backing write count got %d, expected 0", backing_dmem_write_count);
        errors++;
      end
    end
  endtask

  // A conflict miss against a dirty line must write eight victim words before
  // reading eight replacement words. Backing memory changes only on eviction.
  task automatic test_dcache_dirty_eviction;
    int unsigned address;
    begin
      rst = 1'b1;
      memory_model.clear_memory();
      memory_model.write_word(32'h0000_0000, 32'h1000_0093); // ADDI x1, x0, 0x100
      memory_model.write_word(32'h0000_0004, 32'h05a0_0113); // ADDI x2, x0, 0x5a
      memory_model.write_word(32'h0000_0008, 32'h0000_a183); // LW   x3, 0(x1)
      memory_model.write_word(32'h0000_000c, 32'h0020_a023); // SW   x2, 0(x1)
      memory_model.write_word(32'h0000_0010, 32'h0000_8237); // LUI  x4, 0x8
      memory_model.write_word(32'h0000_0014, 32'h1002_2283); // LW   x5, 0x100(x4)
      for (address = 32'h0000_0018; address < 32'h0000_0040; address += 4) begin
        memory_model.write_word(address, 32'h0000_0013);
      end
      memory_model.write_word(32'h0000_0100, 32'h1122_3344);
      memory_model.write_word(32'h0000_8100, 32'haabb_ccdd);
      repeat(2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
      expect_commit(32'h0000_0000, 32'h1000_0093, 5'd1, 32'h0000_0100);
      expect_commit(32'h0000_0004, 32'h05a0_0113, 5'd2, 32'h0000_005a);
      expect_load_commit(32'h0000_0008, 32'h0000_a183, 5'd3, 32'h1122_3344, 32'h0000_0100, 32'h1122_3344);
      expect_store_commit(32'h0000_000c, 32'h0020_a023, 32'h0000_0100, 4'b1111, 32'h0000_005a);
      if (memory_model.read_word(32'h0000_0100) !== 32'h1122_3344) begin
        $error("test_dcache_dirty_eviction: backing memory read got %08h, expected %08h", memory_model.read_word(32'h0000_0100), 32'h1122_3344);
        errors++;
      end
      expect_commit(32'h0000_0010, 32'h0000_8237, 5'd4, 32'h0000_8000);
      expect_load_commit(32'h0000_0014, 32'h1002_2283, 5'd5, 32'haabb_ccdd, 32'h0000_8100, 32'haabb_ccdd);
      if (backing_dmem_write_count !== 8) begin
        $error("test_dcache_dirty_eviction: backing write count got %d, expected 8", backing_dmem_write_count);
        errors++;
      end
      if (backing_dmem_read_count !== 16) begin
        $error("test_dcache_dirty_eviction: backing read count got %d, expected 16", backing_dmem_read_count);
        errors++;
      end
      if (memory_model.read_word(32'h0000_0100) !== 32'h0000_005a) begin
        $error("test_dcache_dirty_eviction: backing memory read got %08h, expected %08h", memory_model.read_word(32'h0000_0100), 32'h0000_005a);
        errors++;
      end
    end
  endtask

  // Refill and dirty-writeback failures must produce one precise fault for the
  // original load, suppress younger side effects, and stop further transfers.
  task automatic test_dcache_access_errors;
    begin
      rst = 1'b1;
      memory_model.clear_memory();
      memory_model.write_word(32'h0000_0000, 32'h1000_0093); // ADDI x1, x0, 256
      memory_model.write_word(32'h0000_0004, 32'h0000_a103); // LW   x2, 0(x1)
      memory_model.write_word(32'h0000_0008, 32'h0110_0193); // ADDI x3, x0, 17
      for (int unsigned address = 32'h0000_000c; address < 32'h0000_0040; address += 4) begin
        memory_model.write_word(address, 32'h00000013);
      end
      memory_model.write_word(32'h0000_0100, 32'h1122_3344);
      repeat(2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
      memory_model.set_dmem_error(32'h0000_0100, 1'b0);
      expect_commit(32'h0000_0000, 32'h1000_0093, 5'd1, 32'h0000_0100);
      expect_trap_commit(32'h0000_0004, 32'h0000_a103, rv32_core_pkg::CORE_TRAP_LOAD_ACCESS_FAULT);
      @(posedge clk);
      #1;
      if (halted !== 1'b1) begin
        $error("test_dcache_access_errors: core did not halt after load access fault");
        errors++;
      end
      if (dut.core.regfile.registers[2] !== 32'd0) begin
        $error("test_dcache_access_errors: faulting load wrote x2");
        errors++;
      end
      if (dut.core.regfile.registers[3] !== 32'd0) begin
        $error("test_dcache_access_errors: younger instruction wrote x3");
        errors++;
      end
      if (backing_dmem_read_count !== 1) begin
        $error("test_dcache_access_errors: backing read count got %0d, expected 1", backing_dmem_read_count);
        errors++;
      end
      if (backing_dmem_write_count !== 0) begin
        $error("test_dcache_access_errors: unexpected backing write");
        errors++;
      end

      rst = 1'b1;
      memory_model.clear_memory();
      memory_model.write_word(32'h0000_0000, 32'h1000_0093); // ADDI x1, x0, 0x100
      memory_model.write_word(32'h0000_0004, 32'h05a0_0113); // ADDI x2, x0, 0x5a
      memory_model.write_word(32'h0000_0008, 32'h0000_a183); // LW   x3, 0(x1)
      memory_model.write_word(32'h0000_000c, 32'h0020_a023); // SW   x2, 0(x1)
      memory_model.write_word(32'h0000_0010, 32'h0000_8237); // LUI  x4, 0x8
      memory_model.write_word(32'h0000_0014, 32'h1002_2283); // LW   x5, 0x100(x4)
      memory_model.write_word(32'h0000_0018, 32'h0130_0313); // ADDI x6, x0, 19
      for (int unsigned address = 32'h0000_001c; address < 32'h0000_0040; address += 4) begin
        memory_model.write_word(address, 32'h0000_0013);
      end
      memory_model.write_word(32'h0000_0100, 32'h1122_3344);
      memory_model.write_word(32'h0000_8100, 32'haabb_ccdd);
      repeat(2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
      memory_model.set_dmem_error(32'h0000_0100, 1'b1);
      expect_commit(32'h0000_0000, 32'h1000_0093, 5'd1, 32'h0000_0100);
      expect_commit(32'h0000_0004, 32'h05a0_0113, 5'd2, 32'h0000_005a);
      expect_load_commit(32'h0000_0008, 32'h0000_a183, 5'd3, 32'h1122_3344, 32'h0000_0100, 32'h1122_3344);
      expect_store_commit(32'h0000_000c, 32'h0020_a023, 32'h0000_0100, 4'b1111, 32'h0000_005a);
      expect_commit(32'h0000_0010, 32'h0000_8237, 5'd4, 32'h0000_8000);
      expect_trap_commit(32'h0000_0014, 32'h1002_2283, rv32_core_pkg::CORE_TRAP_LOAD_ACCESS_FAULT);
      @(posedge clk);
      #1;
      if (halted !== 1'b1) begin
        $error("test_dcache_access_errors: core did not halt after writeback-induced load access fault");
        errors++;
      end
      if (dut.core.regfile.registers[5] !== 32'd0) begin
        $error("test_dcache_access_errors: faulting load wrote x5");
        errors++;
      end
      if (dut.core.regfile.registers[6] !== 32'd0) begin
        $error("test_dcache_access_errors: younger instruction wrote x6");
        errors++;
      end
      if (backing_dmem_read_count !== 8) begin
        $error("test_dcache_access_errors: backing read count got %0d, expected 8", backing_dmem_read_count);
        errors++;
      end
      if (backing_dmem_write_count !== 1) begin
        $error("test_dcache_access_errors: backing write count got %0d, expected 1", backing_dmem_write_count);
        errors++;
      end
      if (memory_model.read_word(32'h0000_0100) !== 32'h1122_3344) begin
        $error("test_dcache_access_errors: failed writeback modified backing memory");
        errors++;
      end
    end
  endtask

  initial begin
    errors = 0;
    test_icache_same_line();
    test_icache_redirect();
    test_dcache_load_miss_and_hit();
    test_dcache_store_merge();
    test_dcache_dirty_eviction();
    test_dcache_access_errors();

    if (errors == 0) begin
      $display("rv32_pipeline_l1_tb: PASS - pipeline, I-cache, D-cache, eviction, and access errors");
      $finish;
    end else begin
      $fatal(1, "rv32_pipeline_l1_tb: FAIL with %d errors", errors);
    end
  end

endmodule
