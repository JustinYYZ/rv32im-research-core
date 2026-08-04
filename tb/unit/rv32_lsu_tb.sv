// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for rv32_lsu.
//
// Tests cover address alignment, every supported store lane, load extraction
// and extension, and suppression of side effects for other operation types.
// The unit is combinational, so each test waits #1 after driving its inputs.

`timescale 1ns/1ps

module rv32_lsu_tb;

  import rv32_pkg::*;

  mem_op_e   mem_op;
  mem_size_e mem_size;
  logic      load_unsigned;
  logic [31:0] addr;
  logic [31:0] store_value;
  logic [31:0] load_word;

  logic [31:0] aligned_addr;
  logic [31:0] store_word;
  logic [3:0]  store_mask;
  logic [31:0] load_value;
  logic        misaligned;
  int unsigned errors;

  rv32_lsu dut (
    .mem_op_i        (mem_op),
    .mem_size_i      (mem_size),
    .load_unsigned_i (load_unsigned),
    .addr_i          (addr),
    .store_value_i   (store_value),
    .load_word_i     (load_word),
    .aligned_addr_o  (aligned_addr),
    .store_word_o    (store_word),
    .store_mask_o    (store_mask),
    .load_value_o    (load_value),
    .misaligned_o    (misaligned)
  );

  task automatic check_idle_defaults;
    begin
      mem_op = MEM_NONE;
      mem_size = MEM_WORD;
      load_unsigned = 1'b0;
      addr = 32'h1234567b;
      store_value = 32'ha1b2c3d4;
      load_word = 32'h80ff7f01;
      #1;

      if (aligned_addr !== 32'h12345678 ||
          store_word !== 32'b0 ||
          store_mask !== 4'b0000 ||
          load_value !== 32'b0 ||
          misaligned !== 1'b0) begin
        $error("MEM_NONE did not keep safe LSU outputs");
        errors++;
      end
    end
  endtask

  // Exercise every address offset for byte, halfword, and word accesses.
  task automatic check_alignment(
    input string       test_name,
    input mem_op_e     test_mem_op,
    input mem_size_e   test_mem_size,
    input logic [1:0]  test_offset,
    input logic        expected_misaligned
  );
    begin
      mem_op = test_mem_op;
      mem_size = test_mem_size;
      load_unsigned = 1'b0;
      addr = 32'h00001000 | test_offset;
      store_value = 32'b0;
      load_word = 32'b0;
      #1;

      if (aligned_addr !== 32'h00001000 ||
          misaligned !== expected_misaligned) begin
        $error(
          "Test %s failed: offset=%0d expected_misaligned=%b got=%b",
          test_name, test_offset, expected_misaligned, misaligned);
        errors++;
      end
    end
  endtask

  task automatic test_alignment;
    begin
      check_alignment("MEM_NONE", MEM_NONE, MEM_WORD, 2'd3, 1'b0);

      check_alignment("BYTE offset 0", MEM_LOAD, MEM_BYTE, 2'd0, 1'b0);
      check_alignment("BYTE offset 1", MEM_LOAD, MEM_BYTE, 2'd1, 1'b0);
      check_alignment("BYTE offset 2", MEM_LOAD, MEM_BYTE, 2'd2, 1'b0);
      check_alignment("BYTE offset 3", MEM_LOAD, MEM_BYTE, 2'd3, 1'b0);

      check_alignment("HALF offset 0", MEM_LOAD, MEM_HALF, 2'd0, 1'b0);
      check_alignment("HALF offset 1", MEM_LOAD, MEM_HALF, 2'd1, 1'b1);
      check_alignment("HALF offset 2", MEM_LOAD, MEM_HALF, 2'd2, 1'b0);
      check_alignment("HALF offset 3", MEM_LOAD, MEM_HALF, 2'd3, 1'b1);

      check_alignment("WORD offset 0", MEM_STORE, MEM_WORD, 2'd0, 1'b0);
      check_alignment("WORD offset 1", MEM_STORE, MEM_WORD, 2'd1, 1'b1);
      check_alignment("WORD offset 2", MEM_STORE, MEM_WORD, 2'd2, 1'b1);
      check_alignment("WORD offset 3", MEM_STORE, MEM_WORD, 2'd3, 1'b1);
    end
  endtask

  // Check data placement, byte enables, and suppression of load results.
  task automatic check_store(
    input string       test_name,
    input mem_size_e   test_mem_size,
    input logic [1:0]  test_offset,
    input logic [31:0] expected_store_word,
    input logic [3:0]  expected_store_mask,
    input logic        expected_misaligned
  );
    begin
      mem_op = MEM_STORE;
      mem_size = test_mem_size;
      load_unsigned = 1'b0;
      addr = 32'h00001000 | test_offset;
      store_value = 32'ha1b2c3d4;
      load_word = 32'b0;
      #1;

      if (aligned_addr !== 32'h00001000 ||
          store_word !== expected_store_word ||
          store_mask !== expected_store_mask ||
          load_value !== 32'b0 ||
          misaligned !== expected_misaligned) begin
        $error("Test %s failed: expected word=%h mask=%b; got word=%h mask=%b",
               test_name, expected_store_word, expected_store_mask, store_word, store_mask);
        errors++;
      end
    end
  endtask

  task automatic test_store_formatting;
    begin
      check_store("SB offset 0", MEM_BYTE, 2'd0, 32'h000000d4, 4'b0001, 1'b0);
      check_store("SB offset 1", MEM_BYTE, 2'd1, 32'h0000d400, 4'b0010, 1'b0);
      check_store("SB offset 2", MEM_BYTE, 2'd2, 32'h00d40000, 4'b0100, 1'b0);
      check_store("SB offset 3", MEM_BYTE, 2'd3, 32'hd4000000, 4'b1000, 1'b0);

      check_store("SH offset 0", MEM_HALF, 2'd0, 32'h0000c3d4, 4'b0011, 1'b0);
      check_store("SH offset 2", MEM_HALF, 2'd2, 32'hc3d40000, 4'b1100, 1'b0);
      check_store("SH misaligned 1", MEM_HALF, 2'd1, 32'b0, 4'b0000, 1'b1);
      check_store("SH misaligned 3", MEM_HALF, 2'd3, 32'b0, 4'b0000, 1'b1);

      check_store("SW offset 0", MEM_WORD, 2'd0, 32'ha1b2c3d4, 4'b1111, 1'b0);
      check_store("SW misaligned 1", MEM_WORD, 2'd1, 32'b0, 4'b0000, 1'b1);
      check_store("SW misaligned 2", MEM_WORD, 2'd2, 32'b0, 4'b0000, 1'b1);
      check_store("SW misaligned 3", MEM_WORD, 2'd3, 32'b0, 4'b0000, 1'b1);
    end
  endtask

  // Check lane selection, signed/unsigned extension, and store suppression.
  task automatic check_load(
    input string       test_name,
    input mem_size_e   test_mem_size,
    input logic [1:0]  test_offset,
    input logic        test_unsigned,
    input logic [31:0] expected_load_value,
    input logic        expected_misaligned
  );
    begin
      mem_op = MEM_LOAD;
      mem_size = test_mem_size;
      load_unsigned = test_unsigned;
      addr = 32'h00001000 | test_offset;
      store_value = 32'ha1b2c3d4;
      load_word = 32'h80ff7f01;
      #1;

      if (aligned_addr !== 32'h00001000 ||
          load_value !== expected_load_value ||
          store_word !== 32'b0 ||
          store_mask !== 4'b0000 ||
          misaligned !== expected_misaligned) begin
        $error("Test %s failed: offset=%0d unsigned=%b expected=%h got=%h",
               test_name, test_offset, test_unsigned, expected_load_value, load_value);
        errors++;
      end
    end
  endtask

  task automatic test_load_formatting;
    begin
      check_load("LB offset 0", MEM_BYTE, 2'd0, 1'b0, 32'h00000001, 1'b0);
      check_load("LB offset 1", MEM_BYTE, 2'd1, 1'b0, 32'h0000007f, 1'b0);
      check_load("LB offset 2", MEM_BYTE, 2'd2, 1'b0, 32'hffffffff, 1'b0);
      check_load("LB offset 3", MEM_BYTE, 2'd3, 1'b0, 32'hffffff80, 1'b0);

      check_load("LBU offset 0", MEM_BYTE, 2'd0, 1'b1, 32'h00000001, 1'b0);
      check_load("LBU offset 1", MEM_BYTE, 2'd1, 1'b1, 32'h0000007f, 1'b0);
      check_load("LBU offset 2", MEM_BYTE, 2'd2, 1'b1, 32'h000000ff, 1'b0);
      check_load("LBU offset 3", MEM_BYTE, 2'd3, 1'b1, 32'h00000080, 1'b0);

      check_load("LH offset 0", MEM_HALF, 2'd0, 1'b0, 32'h00007f01, 1'b0);
      check_load("LH offset 2", MEM_HALF, 2'd2, 1'b0, 32'hffff80ff, 1'b0);
      check_load("LH misaligned 1", MEM_HALF, 2'd1, 1'b0, 32'b0, 1'b1);
      check_load("LH misaligned 3", MEM_HALF, 2'd3, 1'b0, 32'b0, 1'b1);

      check_load("LHU offset 0", MEM_HALF, 2'd0, 1'b1, 32'h00007f01, 1'b0);
      check_load("LHU offset 2", MEM_HALF, 2'd2, 1'b1, 32'h000080ff, 1'b0);
      check_load("LHU misaligned 1", MEM_HALF, 2'd1, 1'b1, 32'b0, 1'b1);
      check_load("LHU misaligned 3", MEM_HALF, 2'd3, 1'b1, 32'b0, 1'b1);

      check_load("LW offset 0", MEM_WORD, 2'd0, 1'b0, 32'h80ff7f01, 1'b0);
      check_load("LW misaligned 1", MEM_WORD, 2'd1, 1'b0, 32'b0, 1'b1);
      check_load("LW misaligned 2", MEM_WORD, 2'd2, 1'b0, 32'b0, 1'b1);
      check_load("LW misaligned 3", MEM_WORD, 2'd3, 1'b0, 32'b0, 1'b1);
    end
  endtask

  initial begin
    mem_op = MEM_NONE;
    mem_size = MEM_BYTE;
    load_unsigned = 1'b0;
    addr = 32'b0;
    store_value = 32'b0;
    load_word = 32'b0;
    errors = 0;

    check_idle_defaults();
    test_alignment();
    test_store_formatting();
    test_load_formatting();

    if (errors == 0) begin
      $display("rv32_lsu_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_lsu_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
