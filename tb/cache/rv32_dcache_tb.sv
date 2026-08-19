// SPDX-License-Identifier: Apache-2.0
//
// Self-checking regression for the blocking direct-mapped L1 data cache.
// The test covers address geometry, hit behavior, masked stores, clean refill,
// write-allocate, dirty eviction, request backpressure, and access errors.

`timescale 1ns/1ps

module rv32_dcache_tb;

  logic clk;
  logic rst;
  logic cpu_req_valid;
  logic cpu_req_ready;
  logic [31:0] cpu_req_addr;
  logic cpu_req_write;
  logic [31:0] cpu_req_wdata;
  logic [3:0] cpu_req_wstrb;
  logic cpu_resp_valid;
  logic [31:0] cpu_resp_rdata;
  logic cpu_resp_error;
  logic mem_req_valid;
  logic mem_req_ready;
  logic [31:0] mem_req_addr;
  logic mem_req_write;
  logic [31:0] mem_req_wdata;
  logic [3:0] mem_req_wstrb;
  logic mem_resp_valid;
  logic [31:0] mem_resp_rdata;
  logic mem_resp_error;
  int unsigned mem_read_count;
  int unsigned read_count_before;
  int unsigned mem_write_count;
  int unsigned write_count_before;
  logic [31:0] accepted_read_addr [0:63];
  logic [31:0] accepted_write_addr [0:63];
  logic [31:0] accepted_write_data [0:63];
  logic [3:0] accepted_write_strb [0:63];
  logic [31:0] stalled_write_addr;
  logic [31:0] stalled_write_data;
  logic [3:0] stalled_write_strb;
  logic inject_mem_error;

  localparam logic [255:0] TEST_LINE = {
    32'hcafe_0007,
    32'hcafe_0006,
    32'hcafe_0005,
    32'hcafe_0004,
    32'hcafe_0003,
    32'hcafe_0002,
    32'hcafe_0001,
    32'hcafe_0000
  };

  rv32_dcache dut (
    .clk_i(clk),
    .rst_i(rst),
    .cpu_req_valid_i(cpu_req_valid),
    .cpu_req_ready_o(cpu_req_ready),
    .cpu_req_addr_i(cpu_req_addr),
    .cpu_req_write_i(cpu_req_write),
    .cpu_req_wdata_i(cpu_req_wdata),
    .cpu_req_wstrb_i(cpu_req_wstrb),
    .cpu_resp_valid_o(cpu_resp_valid),
    .cpu_resp_rdata_o(cpu_resp_rdata),
    .cpu_resp_error_o(cpu_resp_error),
    .mem_req_valid_o(mem_req_valid),
    .mem_req_ready_i(mem_req_ready),
    .mem_req_addr_o(mem_req_addr),
    .mem_req_write_o(mem_req_write),
    .mem_req_wdata_o(mem_req_wdata),
    .mem_req_wstrb_o(mem_req_wstrb),
    .mem_resp_valid_i(mem_resp_valid),
    .mem_resp_rdata_i(mem_resp_rdata),
    .mem_resp_error_i(mem_resp_error)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst) begin
      mem_resp_valid <= 1'b0;
      mem_resp_rdata <= 32'b0;
      mem_resp_error <= 1'b0;
      mem_read_count <= 0;
      mem_write_count <= 0;
    end else begin
      mem_resp_valid <= 1'b0;
      mem_resp_error <= 1'b0;
      if (mem_req_valid && mem_req_ready) begin
        mem_resp_valid <= 1'b1;
        mem_resp_error <= inject_mem_error;
        if (mem_req_write) begin
          accepted_write_addr[mem_write_count] <= mem_req_addr;
          accepted_write_data[mem_write_count] <= mem_req_wdata;
          accepted_write_strb[mem_write_count] <= mem_req_wstrb;
          mem_write_count <= mem_write_count + 1;
          mem_resp_rdata <= 32'b0;
        end else begin
          accepted_read_addr[mem_read_count] <= mem_req_addr;
          mem_read_count <= mem_read_count + 1;
          mem_resp_rdata <= lower_memory_word(mem_req_addr);
        end
      end
    end
  end

  task automatic check_address_fields(input logic [31:0] address, input logic [16:0] expected_tag, input logic [9:0] expected_index, input logic [4:0] expected_offset, input logic [2:0] expected_word_index, input logic [31:0] expected_line_base);
    begin
      // Address decomposition is combinational, so allow one simulation step
      // before checking each field with four-state comparisons.
      cpu_req_addr = address;
      #1;
      if (dut.cpu_req_tag !== expected_tag) begin
        $fatal(1, "Tag mismatch: got %h, expected %h", dut.cpu_req_tag, expected_tag);
      end
      if (dut.cpu_req_index !== expected_index) begin
        $fatal(1, "Index mismatch: got %h, expected %h", dut.cpu_req_index, expected_index);
      end
      if (dut.cpu_req_offset !== expected_offset) begin
        $fatal(1, "Offset mismatch: got %h, expected %h", dut.cpu_req_offset, expected_offset);
      end
      if (dut.cpu_req_word_index !== expected_word_index) begin
        $fatal(1, "Word index mismatch: got %h, expected %h", dut.cpu_req_word_index, expected_word_index);
      end
      if (dut.cpu_req_line_base !== expected_line_base) begin
        $fatal(1, "Line base mismatch: got %h, expected %h", dut.cpu_req_line_base, expected_line_base);
      end
    end
  endtask

  task automatic check_lookup(
    input logic [31:0] address,
    input logic expected_hit,
    input logic expected_dirty,
    input logic [31:0] expected_word
  );
    begin
      cpu_req_addr = address;
      #1;
      if (dut.lookup_hit !== expected_hit) begin
        $fatal(1, "Lookup hit mismatch: got %b, expected %b", dut.lookup_hit, expected_hit);
      end
      if (expected_hit) begin
        if (dut.lookup_dirty !== expected_dirty) begin
          $fatal(1, "Lookup dirty mismatch: got %b, expected %b", dut.lookup_dirty, expected_dirty);
        end
        if (dut.lookup_word !== expected_word) begin
          $fatal(1, "Lookup word mismatch: got %h, expected %h", dut.lookup_word, expected_word);
        end
      end
    end
  endtask

  task automatic check_store_merge(
    input logic [31:0] address,
    input logic [31:0] wdata,
    input logic [3:0] wstrb,
    input logic [31:0] expected_merged_word
  );
    begin
      cpu_req_addr = address;
      cpu_req_wdata = wdata;
      cpu_req_wstrb = wstrb;
      #1;
      if (dut.lookup_hit !== 1'b1) begin
        $fatal(1, "Store merge: expected hit, but got miss");
      end
      if (dut.merged_word !== expected_merged_word) begin
        $fatal(1, "Merged word mismatch: got %h, expected %h", dut.merged_word, expected_merged_word);
      end
    end
  endtask

  task automatic start_request(
    input logic [31:0] address,
    input logic write,
    input logic [31:0] wdata,
    input logic [3:0] wstrb
  );
    begin
      @(negedge clk);
      if (cpu_req_ready !== 1'b1) begin
        $fatal(1, "D-cache was not ready before request");
      end

      cpu_req_valid = 1'b1;
      cpu_req_addr = address;
      cpu_req_write = write;
      cpu_req_wdata = wdata;
      cpu_req_wstrb = wstrb;

      @(posedge clk);
      @(negedge clk);

      if (cpu_req_ready !== 1'b0) begin
        $fatal(1, "D-cache remained ready after accepting request");
      end
      if (mem_req_valid !== 1'b0) begin
        $fatal(1, "Cache hit unexpectedly accessed lower memory");
      end

      cpu_req_valid = 1'b0;
      cpu_req_addr = 32'hffff_fffc;
      cpu_req_write = !write;
      cpu_req_wdata = 32'hdead_beef;
      cpu_req_wstrb = 4'b1111;
    end
  endtask

  task automatic expect_response(
    input logic [31:0] expected_data,
    input logic expected_error
  );
    int unsigned cycles;
    begin
      cycles = 0;
      while (cpu_resp_valid !== 1'b1 && cycles < 100) begin
        @(negedge clk);
        cycles++;
      end

      if (cpu_resp_valid !== 1'b1) begin
        $fatal(1, "Timed out waiting for CPU response");
      end
      if (cpu_resp_rdata !== expected_data) begin
        $fatal(1, "Response data mismatch: got %h, expected %h", cpu_resp_rdata, expected_data);
      end
      if (cpu_resp_error !== expected_error) begin
        $fatal(1, "Response error mismatch: got %b, expected %b", cpu_resp_error, expected_error);
      end
      if (cpu_req_ready !== 1'b0) begin
        $fatal(1, "D-cache was ready while response was active");
      end
      if (mem_req_valid !== 1'b0) begin
        $fatal(1, "Cache hit unexpectedly accessed lower memory");
      end

      @(posedge clk);
      @(negedge clk);

      if (cpu_resp_valid !== 1'b0 || cpu_req_ready !== 1'b1) begin
        $fatal(1, "D-cache did not return to IDLE after response");
      end
    end
  endtask

  function automatic logic [31:0] lower_memory_word(input logic [31:0] address);
    lower_memory_word = 32'ha5a5_0000 ^ address;
  endfunction

  task automatic test_address_geometry;
    begin
      check_address_fields(32'h0000_0000, 17'h0, 10'h000, 5'h00, 3'h0, 32'h0000_0000);
      check_address_fields(32'h0000_104c, 17'h0, 10'h082, 5'h0c, 3'h3, 32'h0000_1040);
      check_address_fields(32'h0000_904c, 17'h1, 10'h082, 5'h0c, 3'h3, 32'h0000_9040);
      check_address_fields(32'h0000_7ffc, 17'h0, 10'h3ff, 5'h1c, 3'h7, 32'h0000_7fe0);
    end
  endtask

  task automatic test_lookup_and_merge;
    begin
      dut.valid_array[10'h082] = 1'b0;
      dut.dirty_array[10'h082] = 1'b0;
      dut.tag_array[10'h082] = 17'h0;
      dut.data_array[10'h082] = TEST_LINE;
      check_lookup(32'h0000_104c, 1'b0, 1'b0, 32'b0);
      dut.valid_array[10'h082] = 1'b1;
      dut.tag_array[10'h082] = 17'h00001;
      check_lookup(32'h0000_104c, 1'b0, 1'b0, 32'b0);
      dut.tag_array[10'h082] = 17'h00000;
      dut.dirty_array[10'h082] = 1'b0;
      check_lookup(32'h0000_1040, 1'b1, 1'b0, 32'hcafe_0000);
      check_lookup(32'h0000_1044, 1'b1, 1'b0, 32'hcafe_0001);
      check_lookup(32'h0000_104c, 1'b1, 1'b0, 32'hcafe_0003);
      check_lookup(32'h0000_105c, 1'b1, 1'b0, 32'hcafe_0007);
      dut.dirty_array[10'h082] = 1'b1;
      check_lookup(32'h0000_104c, 1'b1, 1'b1, 32'hcafe_0003);

      check_store_merge(32'h0000_104c, 32'h0000_00aa, 4'b0001, 32'hcafe_00aa);
      check_store_merge(32'h0000_104c, 32'h0000_bb00, 4'b0010, 32'hcafe_bb03);
      check_store_merge(32'h0000_104c, 32'h00cc_0000, 4'b0100, 32'hcacc_0003);
      check_store_merge(32'h0000_104c, 32'hdd00_0000, 4'b1000, 32'hddfe_0003);
      check_store_merge(32'h0000_104c, 32'h0000_1234, 4'b0011, 32'hcafe_1234);
      check_store_merge(32'h0000_104c, 32'habcd_0000, 4'b1100, 32'habcd_0003);
      check_store_merge(32'h0000_104c, 32'h1234_5678, 4'b1111, 32'h1234_5678);
      check_store_merge(32'h0000_104c, 32'hffff_ffff, 4'b0000, 32'hcafe_0003);
    end
  endtask

  task automatic test_hit_handshake;
    begin
      dut.valid_array[10'h082] = 1'b1;
      dut.dirty_array[10'h082] = 1'b0;
      dut.tag_array[10'h082] = 17'h00000;
      dut.data_array[10'h082] = TEST_LINE;
      start_request(32'h0000_104c, 1'b0, 32'b0, 4'b0000);
      expect_response(32'hcafe_0003, 1'b0);
      if (dut.dirty_array[10'h082] !== 1'b0) begin
        $fatal(1, "Load hit should not set dirty");
      end

      start_request(32'h0000_104c, 1'b1, 32'h0000_aa00, 4'b0010);
      expect_response(32'b0, 1'b0);
      if (dut.data_array[10'h082][3*32 +:32] !== 32'hcafe_aa03) begin
        $fatal(1, "Store should merge byte lane 1");
      end
      if (dut.dirty_array[10'h082] !== 1'b1) begin
        $fatal(1, "Store should set dirty");
      end

      start_request(32'h0000_104c, 1'b0, 32'b0, 4'b0000);
      expect_response(32'hcafe_aa03, 1'b0);
    end
  endtask

  task automatic test_clean_miss_and_write_allocate;
    begin
      read_count_before = mem_read_count;
      start_request(32'h0000_200c, 1'b0, 32'b0, 4'b0000);
      expect_response(lower_memory_word(32'h0000_200c), 1'b0);
      if (mem_read_count - read_count_before !== 8) begin
        $fatal(1, "Load miss should issue 8 refill reads");
      end
      for (int i = 0; i < 8; i++) begin
        if (accepted_read_addr[read_count_before + i] !== 32'h0000_2000 + i * 4) begin
          $fatal(1, "Refill address %0d mismatch: got %h, expected %h", i, accepted_read_addr[read_count_before + i], 32'h0000_2000 + i * 4);
        end
      end

      read_count_before = mem_read_count;
      start_request(32'h0000_200c, 1'b0, 32'b0, 4'b0000);
      expect_response(lower_memory_word(32'h0000_200c), 1'b0);
      if (mem_read_count !== read_count_before) begin
        $fatal(1, "Post-refill load should hit without accessing lower memory");
      end

      read_count_before = mem_read_count;
      start_request(32'h0000_3054, 1'b1, 32'h0000_aa00, 4'b0010);
      expect_response(32'b0, 1'b0);
      if (mem_read_count - read_count_before !== 8) begin
        $fatal(1, "Store miss should issue 8 refill reads");
      end
      for (int i = 0; i < 8; i++) begin
        if (accepted_read_addr[read_count_before + i] !== 32'h0000_3040 + i * 4) begin
          $fatal(1, "Store-miss refill address %0d mismatch: got %h, expected %h", i, accepted_read_addr[read_count_before + i], 32'h0000_3040 + i * 4);
        end
      end

      read_count_before = mem_read_count;
      start_request(32'h0000_3054, 1'b0, 32'b0, 4'b0000);
      expect_response(32'ha5a5_aa54, 1'b0);
      if (mem_read_count !== read_count_before) begin
        $fatal(1, "Post-store-miss load should hit without accessing lower memory");
      end
      if (dut.dirty_array[10'h182] !== 1'b1) begin
        $fatal(1, "Store miss should install a dirty cache line");
      end
    end
  endtask

  task automatic test_dirty_eviction;
    begin
      read_count_before = mem_read_count;
      write_count_before = mem_write_count;
      start_request(32'h0000_b054, 1'b0, 32'b0, 4'b0000);
      expect_response(lower_memory_word(32'h0000_b054), 1'b0);
      if (mem_read_count - read_count_before !== 8) begin
        $fatal(1, "Load miss should issue 8 refill reads");
      end
      if (mem_write_count - write_count_before !== 8) begin
        $fatal(1, "Load miss should evict 8 dirty words");
      end
      for (int i = 0; i < 8; i++) begin
        if (accepted_write_addr[write_count_before + i] !== 32'h0000_3040 + i * 4) begin
          $fatal(1, "Writeback address %0d mismatch: got %h, expected %h", i, accepted_write_addr[write_count_before + i], 32'h0000_3040 + i * 4);
        end
        if (accepted_write_strb[write_count_before + i] !== 4'b1111) begin
          $fatal(1, "Writeback strobe %0d mismatch", i);
        end
        if (i == 5) begin
          if (accepted_write_data[write_count_before + i] !== 32'ha5a5_aa54) begin
            $fatal(1, "Modified victim word mismatch");
          end
        end else if (accepted_write_data[write_count_before + i] !== lower_memory_word(32'h0000_3040 + i * 4)) begin
          $fatal(1, "Writeback data %0d mismatch", i);
        end
        if (accepted_read_addr[read_count_before + i] !== 32'h0000_b040 + i * 4) begin
          $fatal(1, "Post-writeback refill address %0d mismatch", i);
        end
      end

      read_count_before = mem_read_count;
      write_count_before = mem_write_count;
      start_request(32'h0000_b054, 1'b0, 32'b0, 4'b0000);
      expect_response(lower_memory_word(32'h0000_b054), 1'b0);
      if (mem_read_count !== read_count_before) begin
        $fatal(1, "Post-eviction load should hit without refill");
      end
      if (mem_write_count !== write_count_before) begin
        $fatal(1, "Post-eviction load should not write back");
      end
      if (dut.dirty_array[10'h182] !== 1'b0) begin
        $fatal(1, "Load refill should install a clean line");
      end
    end
  endtask

  task automatic test_writeback_backpressure;
    begin
      start_request(32'h0000_b054, 1'b1, 32'h1234_5678, 4'b1111);
      expect_response(32'b0, 1'b0);
      read_count_before = mem_read_count;
      write_count_before = mem_write_count;
      mem_req_ready = 1'b0;
      start_request(32'h0001_3054, 1'b0, 32'b0, 4'b0000);
      while (mem_req_valid !== 1'b1) begin
        @(negedge clk);
      end
      if (mem_req_write !== 1'b1) begin
        $fatal(1, "Expected stalled writeback request");
      end
      stalled_write_addr = mem_req_addr;
      stalled_write_data = mem_req_wdata;
      stalled_write_strb = mem_req_wstrb;
      repeat (3) begin
        @(posedge clk);
        @(negedge clk);
        if (mem_req_valid !== 1'b1 ||
            mem_req_write !== 1'b1 ||
            mem_req_addr !== stalled_write_addr ||
            mem_req_wdata !== stalled_write_data ||
            mem_req_wstrb !== stalled_write_strb) begin
          $fatal(1, "Writeback request changed under backpressure");
        end
        if (mem_write_count !== write_count_before) begin
          $fatal(1, "Stalled writeback request must not be accepted");
        end
      end
      mem_req_ready = 1'b1;
      expect_response(lower_memory_word(32'h0001_3054), 1'b0);
      if (mem_write_count - write_count_before !== 8) begin
        $fatal(1, "Backpressured dirty eviction should write 8 words");
      end
      if (mem_read_count - read_count_before !== 8) begin
        $fatal(1, "Backpressured dirty eviction should refill 8 words");
      end
    end
  endtask

  task automatic test_error_paths;
    begin
      read_count_before = mem_read_count;
      inject_mem_error = 1'b1;
      start_request(32'h0000_4004, 1'b0, 32'b0, 4'b0000);
      expect_response(32'b0, 1'b1);
      inject_mem_error = 1'b0;
      if (mem_read_count - read_count_before !== 1) begin
        $fatal(1, "Refill error should stop after one failed read");
      end
      if (dut.valid_array[10'h200] !== 1'b0) begin
        $fatal(1, "Refill error must not install a cache line");
      end

      start_request(32'h0001_3054, 1'b1, 32'hcafe_babe, 4'b1111);
      expect_response(32'b0, 1'b0);
      read_count_before = mem_read_count;
      write_count_before = mem_write_count;
      inject_mem_error = 1'b1;
      start_request(32'h0001_b054, 1'b0, 32'b0, 4'b0000);
      expect_response(32'b0, 1'b1);
      inject_mem_error = 1'b0;
      if (mem_write_count - write_count_before !== 1) begin
        $fatal(1, "Writeback error should stop after one failed write");
      end
      if (mem_read_count !== read_count_before) begin
        $fatal(1, "Writeback error must not start refill");
      end
      if (accepted_write_addr[write_count_before] !== 32'h0001_3040) begin
        $fatal(1, "Failed writeback used the wrong victim address");
      end
      if (accepted_write_strb[write_count_before] !== 4'b1111) begin
        $fatal(1, "Failed writeback should use full-word strobe");
      end
      if (dut.dirty_array[10'h182] !== 1'b1) begin
        $fatal(1, "Writeback error must preserve the dirty victim");
      end
      read_count_before = mem_read_count;
      write_count_before = mem_write_count;
      start_request(32'h0001_3054, 1'b0, 32'b0, 4'b0000);
      expect_response(32'hcafe_babe, 1'b0);
      if (mem_read_count !== read_count_before || mem_write_count !== write_count_before) begin
        $fatal(1, "Preserved victim should remain accessible as a cache hit");
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    cpu_req_valid = 1'b0;
    cpu_req_addr = 32'b0;
    cpu_req_write = 1'b0;
    cpu_req_wdata = 32'b0;
    cpu_req_wstrb = 4'b0000;
    mem_req_ready = 1'b1;
    inject_mem_error = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    // Later tests intentionally build on cache state created by earlier ones.
    test_address_geometry();
    test_lookup_and_merge();
    test_hit_handshake();
    test_clean_miss_and_write_allocate();
    test_dirty_eviction();
    test_writeback_backpressure();
    test_error_paths();

    $display("rv32_dcache_tb: PASS - hit, refill, write-allocate, dirty eviction, backpressure, and errors");
    $finish;
  end

endmodule
