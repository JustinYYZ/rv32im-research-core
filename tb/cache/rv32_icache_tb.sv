// SPDX-License-Identifier: Apache-2.0
//
// Self-checking regression for the blocking direct-mapped L1 I-cache.
// It covers parameter-derived address geometry, hits, cold and conflict misses,
// refill, request backpressure, access errors, and reset invalidation.

`timescale 1ns/1ps

module rv32_icache_tb;

  logic clk;
  logic rst;
  logic cpu_req_valid;
  logic cpu_req_ready;
  logic [31:0] cpu_req_addr;
  logic cpu_resp_valid;
  logic [31:0] cpu_resp_data;
  logic cpu_resp_error;
  logic mem_req_valid;
  logic mem_req_ready;
  logic [31:0] mem_req_addr;
  logic mem_resp_valid;
  logic [31:0] mem_resp_data;
  logic mem_resp_error;

  int unsigned mem_request_count;
  int test_word;

  localparam int unsigned TEST_SET_COUNT = rv32_cache_pkg::L1_DEFAULT_CACHE_BYTES / rv32_cache_pkg::L1_DEFAULT_LINE_BYTES;

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
  localparam logic [255:0] CONFLICT_LINE = {
    32'hbeef_0007,
    32'hbeef_0006,
    32'hbeef_0005,
    32'hbeef_0004,
    32'hbeef_0003,
    32'hbeef_0002,
    32'hbeef_0001,
    32'hbeef_0000
  };

  rv32_icache dut (
    .clk_i(clk),
    .rst_i(rst),
    .cpu_req_valid_i(cpu_req_valid),
    .cpu_req_ready_o(cpu_req_ready),
    .cpu_req_addr_i(cpu_req_addr),
    .cpu_resp_valid_o(cpu_resp_valid),
    .cpu_resp_data_o(cpu_resp_data),
    .cpu_resp_error_o(cpu_resp_error),
    .mem_req_valid_o(mem_req_valid),
    .mem_req_ready_i(mem_req_ready),
    .mem_req_addr_o(mem_req_addr),
    .mem_resp_valid_i(mem_resp_valid),
    .mem_resp_data_i(mem_resp_data),
    .mem_resp_error_i(mem_resp_error)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_request_count <= 0;
    end else if (mem_req_valid && mem_req_ready) begin
      mem_request_count <= mem_request_count + 1;
    end
  end

  task automatic reset_dut;
    begin
      rst = 1'b1;
      repeat (2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
    end
  endtask

  task automatic check_address_fields(input logic [31:0] address, input logic [16:0] expected_tag, input logic [9:0] expected_index, input logic [4:0] expected_offset, input logic [2:0] expected_word_index, input logic [31:0] expected_line_base);
    begin
      // Geometry is checked directly; behavioral tests use the external ports.
      cpu_req_addr = address;
      #1;
      if (dut.cpu_req_tag !== expected_tag) begin
        $fatal(1, "Address %08h tag mismatch: expected=%05h actual=%05h", address, expected_tag, dut.cpu_req_tag);
      end
      if (dut.cpu_req_index !== expected_index) begin
        $fatal(1, "Address %08h index mismatch: expected=%03h actual=%03h", address, expected_index, dut.cpu_req_index);
      end
      if (dut.cpu_req_offset !== expected_offset) begin
        $fatal(1, "Address %08h offset mismatch: expected=%02h actual=%02h", address, expected_offset, dut.cpu_req_offset);
      end
      if (dut.cpu_req_word_index !== expected_word_index) begin
        $fatal(1, "Address %08h word index mismatch: expected=%0d actual=%0d", address, expected_word_index, dut.cpu_req_word_index);
      end
      if (dut.cpu_req_line_base !== expected_line_base) begin
        $fatal(1, "Address %08h line base mismatch: expected=%08h actual=%08h", address, expected_line_base, dut.cpu_req_line_base);
      end
    end
  endtask

  task automatic start_request(input logic [31:0] address);
    begin
      @(negedge clk);

      if (cpu_req_ready !== 1'b1) begin
        $fatal(1, "I-cache was not ready before request");
      end

      cpu_req_addr = address;
      cpu_req_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      cpu_req_valid = 1'b0;
    end
  endtask

  task automatic expect_hit_response(input logic [31:0] address, input logic [31:0] expected_data);
    int unsigned cycles;
    begin
      start_request(address);

      cycles = 0;
      while (cpu_resp_valid !== 1'b1 && cycles < 4) begin
        @(negedge clk);
        cycles++;
      end

      if (cpu_resp_valid !== 1'b1) begin
        $fatal(1, "Address %08h did not produce a hit response", address);
      end

      if (cpu_resp_error !== 1'b0) begin
        $fatal(1, "Address %08h unexpectedly returned an error", address);
      end

      if (cpu_resp_data !== expected_data) begin
        $fatal(1, "Address %08h response mismatch: expected=%08h actual=%08h", address, expected_data,
        cpu_resp_data);
      end

      @(negedge clk);

      if (cpu_req_ready !== 1'b1) begin
        $fatal(1, "I-cache did not return to IDLE after response");
      end
    end
  endtask

  task automatic serve_memory_word(input logic [31:0] expected_address, input logic [31:0] response_data, input logic response_error);
    int unsigned wait_cycles;
    begin
      wait_cycles = 0;
      while (mem_req_valid !== 1'b1 && wait_cycles < 8) begin
        @(negedge clk);
        wait_cycles++;
      end
      if (mem_req_valid !== 1'b1) begin
        $fatal(1, "Memory request for %08h did not appear", expected_address);
      end
      if (mem_req_addr !== expected_address) begin
        $fatal(1, "Memory address mismatch: expected=%08h actual=%08h", expected_address, mem_req_addr);
      end

      mem_req_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      mem_req_ready = 1'b0;
      mem_resp_data = response_data;
      mem_resp_error = response_error;
      mem_resp_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      mem_resp_valid = 1'b0;
      mem_resp_error = 1'b0;
    end
  endtask

  task automatic hold_memory_backpressure(input logic [31:0] expected_address, input int unsigned stall_cycles);
    int unsigned wait_cycles;
    int unsigned stalled_cycles;
    int unsigned request_count_before;
    begin
      wait_cycles = 0;
      while (mem_req_valid !== 1'b1 && wait_cycles < 8) begin
        @(negedge clk);
        wait_cycles++;
      end

      if (mem_req_valid !== 1'b1) begin
        $fatal(1, "Memory request for backpressure test did not appear");
      end

      request_count_before = mem_request_count;
      mem_req_ready = 1'b0;

      for (stalled_cycles = 0; stalled_cycles < stall_cycles; stalled_cycles++) begin
        if (mem_req_valid !== 1'b1) begin
          $fatal(1, "Memory request valid dropped during backpressure");
        end

        if (mem_req_addr !== expected_address) begin
          $fatal(1, "Memory request address changed during backpressure: expected=%08h actual=%08h",
          expected_address, mem_req_addr);
        end

        if (mem_request_count !== request_count_before) begin
          $fatal(1, "Memory request was counted before handshake");
        end

        if (cpu_req_ready !== 1'b0 || cpu_resp_valid !== 1'b0) begin
          $fatal(1, "CPU interface changed while miss request was stalled");
        end

        @(posedge clk);
        @(negedge clk);
      end
    end
  endtask

  task automatic expect_cpu_response(input logic [31:0] expected_data, input logic expected_error);
    int unsigned wait_cycles;
    begin
      wait_cycles = 0;
      while (cpu_resp_valid !== 1'b1 && wait_cycles < 8) begin
        @(negedge clk);
        wait_cycles++;
      end
      if (cpu_resp_valid !== 1'b1) begin
        $fatal(1, "CPU response did not appear");
      end
      if (cpu_resp_error !== expected_error) begin
        $fatal(1, "CPU response error mismatch: expected=%b actual=%b", expected_error, cpu_resp_error);
      end
      if (cpu_resp_data !== expected_data) begin
        $fatal(1, "CPU response data mismatch: expected=%08h actual=%08h", expected_data, cpu_resp_data);
      end
      @(posedge clk);
      @(negedge clk);
      if (cpu_req_ready !== 1'b1) begin
        $fatal(1, "I-cache did not return to IDLE after response");
      end
    end
  endtask

  task automatic check_reset_invalidation;
    int unsigned set_index;
    begin
      for (set_index = 0; set_index < TEST_SET_COUNT; set_index++) begin
        dut.valid_array[set_index] = 1'b1;
      end
      reset_dut();
      for (set_index = 0; set_index < TEST_SET_COUNT; set_index++) begin
        if (dut.valid_array[set_index] !== 1'b0) begin
          $fatal(1, "Cache set %0d remained valid after reset", set_index);
        end
      end
      if (cpu_req_ready !== 1'b1) begin
        $fatal(1, "I-cache was not ready after reset");
      end
      if (cpu_resp_valid !== 1'b0 || mem_req_valid !== 1'b0) begin
        $fatal(1, "I-cache exposed an active transaction after reset");
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    cpu_req_valid = 1'b0;
    cpu_req_addr = 32'd0;
    mem_req_ready = 1'b0;
    mem_resp_valid = 1'b0;
    mem_resp_data = 32'd0;
    mem_resp_error = 1'b0;
    reset_dut();
    check_address_fields(32'h0000_0000, 17'h00000, 10'h000, 5'h00, 3'd0, 32'h0000_0000);
    check_address_fields(32'h0000_104c, 17'h00000, 10'h082, 5'h0c, 3'd3, 32'h0000_1040);
    check_address_fields(32'h0000_904c, 17'h00001, 10'h082, 5'h0c, 3'd3, 32'h0000_9040);
    check_address_fields(32'h0000_7ffc, 17'h00000, 10'h3ff, 5'h1c, 3'd7, 32'h0000_7fe0);

    dut.valid_array[10'h082] = 1'b1;
    dut.tag_array[10'h082] = 17'h00000;
    dut.data_array[10'h082] = TEST_LINE;
    expect_hit_response(32'h0000_1040, 32'hcafe_0000);
    expect_hit_response(32'h0000_1044, 32'hcafe_0001);
    expect_hit_response(32'h0000_104c, 32'hcafe_0003);
    expect_hit_response(32'h0000_105c, 32'hcafe_0007);

    reset_dut();
    start_request(32'h0000_104c);
    for (test_word = 0; test_word < 8; test_word++) begin
      serve_memory_word(32'h0000_1040 + test_word * 4, TEST_LINE[test_word * 32 +: 32], 1'b0);
    end
    expect_cpu_response(32'hcafe_0003, 1'b0);
    if (mem_request_count !== 8) begin
      $fatal(1, "Cold miss request count mismatch: expected=8 actual=%0d", mem_request_count);
    end
    start_request(32'h0000_1058);
    expect_cpu_response(32'hcafe_0006, 1'b0);
    if (mem_request_count !== 8) begin
      $fatal(1, "Post-refill hit unexpectedly accessed memory");
    end

    reset_dut();
    start_request(32'h0000_200c);
    hold_memory_backpressure(32'h0000_2000, 3);
    for (test_word = 0; test_word < 8; test_word++) begin
      serve_memory_word(32'h0000_2000 + test_word * 4, TEST_LINE[test_word * 32 +: 32], 1'b0);
    end
    expect_cpu_response(32'hcafe_0003, 1'b0);
    if (mem_request_count !== 8) begin
      $fatal(1, "Backpressure refill request count mismatch: expected=8 actual=%0d", mem_request_count);
    end

    reset_dut();
    start_request(32'h0000_104c);
    for (test_word = 0; test_word < 8; test_word++) begin
      serve_memory_word(32'h0000_1040 + test_word * 4, TEST_LINE[test_word * 32 +: 32], 1'b0);
    end
    expect_cpu_response(32'hcafe_0003, 1'b0);
    if (mem_request_count !== 8) begin
      $fatal(1, "First conflict line request count mismatch: expected=8 actual=%0d", mem_request_count);
    end

    start_request(32'h0000_904c);
    for (test_word = 0; test_word < 8; test_word++) begin
      serve_memory_word(32'h0000_9040 + test_word * 4, CONFLICT_LINE[test_word * 32 +: 32], 1'b0);
    end
    expect_cpu_response(32'hbeef_0003, 1'b0);
    if (mem_request_count !== 16) begin
      $fatal(1, "Conflict replacement request count mismatch: expected=16 actual=%0d", mem_request_count);
    end

    start_request(32'h0000_9058);
    expect_cpu_response(32'hbeef_0006, 1'b0);
    if (mem_request_count !== 16) begin
      $fatal(1, "Replacement line hit unexpectedly accessed memory");
    end

    start_request(32'h0000_104c);
    for (test_word = 0; test_word < 8; test_word++) begin
      serve_memory_word(32'h0000_1040 + test_word * 4, TEST_LINE[test_word * 32 +: 32], 1'b0);
    end
    expect_cpu_response(32'hcafe_0003, 1'b0);
    if (mem_request_count !== 24) begin
      $fatal(1, "Replaced line did not miss: expected=24 actual=%0d", mem_request_count);
    end

    reset_dut();
    start_request(32'h0000_304c);
    serve_memory_word(32'h0000_3040, 32'hcafe_0000, 1'b0);
    serve_memory_word(32'h0000_3044, 32'hcafe_0001, 1'b0);
    serve_memory_word(32'h0000_3048, 32'hdead_beef, 1'b1);
    expect_cpu_response(32'h0000_0000, 1'b1);
    if (mem_request_count !== 3) begin
      $fatal(1, "Cold refill error did not stop immediately: expected=3 actual=%0d", mem_request_count);
    end
    start_request(32'h0000_304c);
    for (test_word = 0; test_word < 8; test_word++) begin
      serve_memory_word(32'h0000_3040 + test_word * 4, TEST_LINE[test_word * 32 +: 32], 1'b0);
    end
    expect_cpu_response(32'hcafe_0003, 1'b0);
    if (mem_request_count !== 11) begin
      $fatal(1, "Failed cold refill was incorrectly cached: expected=11 actual=%0d", mem_request_count);
    end
    start_request(32'h0000_3058);
    expect_cpu_response(32'hcafe_0006, 1'b0);
    if (mem_request_count !== 11) begin
      $fatal(1, "Successful retry did not produce a cache hit");
    end

    reset_dut();
    start_request(32'h0000_104c);
    for (test_word = 0; test_word < 8; test_word++) begin
      serve_memory_word(32'h0000_1040 + test_word * 4, TEST_LINE[test_word * 32 +: 32], 1'b0);
    end
    expect_cpu_response(32'hcafe_0003, 1'b0);
    if (mem_request_count !== 8) begin
      $fatal(1, "Conflict-error setup request count mismatch: expected=8 actual=%0d", mem_request_count);
    end
    start_request(32'h0000_904c);
    serve_memory_word(32'h0000_9040, 32'hdead_beef, 1'b1);
    expect_cpu_response(32'h0000_0000, 1'b1);
    if (mem_request_count !== 9) begin
      $fatal(1, "Conflict refill error request count mismatch: expected=9 actual=%0d", mem_request_count);
    end
    start_request(32'h0000_104c);
    expect_cpu_response(32'hcafe_0003, 1'b0);
    if (mem_request_count !== 9) begin
      $fatal(1, "Failed conflict refill destroyed the old cache line");
    end

    check_reset_invalidation();

    start_request(32'h0000_104c);
    for (test_word = 0; test_word < 8; test_word++) begin
      serve_memory_word(32'h0000_1040 + test_word * 4, TEST_LINE[test_word * 32 +: 32], 1'b0);
    end
    expect_cpu_response(32'hcafe_0003, 1'b0);

    if (mem_request_count !== 8) begin
      $fatal(1, "Reset-invalidated line did not miss: expected=8 actual=%0d", mem_request_count);
    end

    $display("rv32_icache_tb: PASS - hit, refill, replacement, backpressure, error, and reset");
    $finish;
  end

endmodule
