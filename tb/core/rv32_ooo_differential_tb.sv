// SPDX-License-Identifier: Apache-2.0
//
// Commit-level differential testbench for the reference and OoO cores.
//
// The two cores will execute identical program/data images in independent
// memories. Their cycle timing is allowed to differ; only retirement order and
// architectural effects are compared. The same testbench can exercise either
// the raw OoO memory ports or the OoO core behind split L1 caches.

`timescale 1ns/1ps

module rv32_ooo_differential_tb;

  localparam int unsigned MAX_COMMITS = 1024;
  localparam int unsigned MAX_CYCLES = 100000;

  typedef struct packed {
    logic [31:0] pc;
    logic [31:0] instr;
    logic rd_write;
    logic [4:0] rd_addr;
    logic [31:0] rd_wdata;
    logic mem_valid;
    logic mem_write;
    logic [31:0] mem_addr;
    logic [3:0] mem_rmask;
    logic [3:0] mem_wmask;
    logic [31:0] mem_rdata;
    logic [31:0] mem_wdata;
    logic trap;
    rv32_core_pkg::trap_cause_e trap_cause;
  } commit_event_t;

  logic clk;
  logic rst;

  logic ref_imem_req_valid;
  logic ref_imem_req_ready;
  logic [31:0] ref_imem_req_addr;
  logic ref_imem_resp_valid;
  logic [31:0] ref_imem_resp_data;
  logic ref_imem_resp_error;
  logic ref_dmem_req_valid;
  logic ref_dmem_req_ready;
  logic [31:0] ref_dmem_req_addr;
  logic ref_dmem_req_write;
  logic [31:0] ref_dmem_req_wdata;
  logic [3:0] ref_dmem_req_wstrb;
  logic ref_dmem_resp_valid;
  logic [31:0] ref_dmem_resp_rdata;
  logic ref_dmem_resp_error;
  logic ref_commit_valid;
  logic [31:0] ref_commit_pc;
  logic [31:0] ref_commit_instr;
  logic ref_commit_rd_write;
  logic [4:0] ref_commit_rd_addr;
  logic [31:0] ref_commit_rd_wdata;
  logic ref_commit_mem_valid;
  logic ref_commit_mem_write;
  logic [31:0] ref_commit_mem_addr;
  logic [3:0] ref_commit_mem_rmask;
  logic [3:0] ref_commit_mem_wmask;
  logic [31:0] ref_commit_mem_rdata;
  logic [31:0] ref_commit_mem_wdata;
  logic ref_commit_trap;
  rv32_core_pkg::trap_cause_e ref_commit_trap_cause;
  logic ref_halted;

  logic ooo_imem_req_valid;
  logic ooo_imem_req_ready;
  logic [31:0] ooo_imem_req_addr;
  logic ooo_imem_resp_valid;
  logic [31:0] ooo_imem_resp_data;
  logic ooo_imem_resp_error;
  logic ooo_dmem_req_valid;
  logic ooo_dmem_req_ready;
  logic [31:0] ooo_dmem_req_addr;
  logic ooo_dmem_req_write;
  logic [31:0] ooo_dmem_req_wdata;
  logic [3:0] ooo_dmem_req_wstrb;
  logic ooo_dmem_resp_valid;
  logic [31:0] ooo_dmem_resp_rdata;
  logic ooo_dmem_resp_error;
  logic ooo_commit_valid;
  logic [31:0] ooo_commit_pc;
  logic [31:0] ooo_commit_instr;
  logic ooo_commit_rd_write;
  logic [4:0] ooo_commit_rd_addr;
  logic [31:0] ooo_commit_rd_wdata;
  logic ooo_commit_mem_valid;
  logic ooo_commit_mem_write;
  logic [31:0] ooo_commit_mem_addr;
  logic [3:0] ooo_commit_mem_rmask;
  logic [3:0] ooo_commit_mem_wmask;
  logic [31:0] ooo_commit_mem_rdata;
  logic [31:0] ooo_commit_mem_wdata;
  logic ooo_commit_trap;
  rv32_core_pkg::trap_cause_e ooo_commit_trap_cause;
  logic ooo_halted;

  commit_event_t ref_events [0:MAX_COMMITS-1];
  commit_event_t ooo_events [0:MAX_COMMITS-1];
  commit_event_t final_ref_event;
  int unsigned ref_commit_count;
  int unsigned ooo_commit_count;
  int unsigned compared_count;
  int unsigned cycle_count;
  logic [255:0] test_name;
  int unsigned expected_commits;
  rv32_core_pkg::trap_cause_e expected_trap_cause;

  // Each core has independent memory channels so execution-speed differences
  // cannot expose one core to the other core's speculative or committed state.
  rv32_reference_core ref_core (
    .clk_i(clk),
    .rst_i(rst),
    .imem_req_valid_o(ref_imem_req_valid),
    .imem_req_ready_i(ref_imem_req_ready),
    .imem_req_addr_o(ref_imem_req_addr),
    .imem_resp_valid_i(ref_imem_resp_valid),
    .imem_resp_data_i(ref_imem_resp_data),
    .imem_resp_error_i(ref_imem_resp_error),
    .dmem_req_valid_o(ref_dmem_req_valid),
    .dmem_req_ready_i(ref_dmem_req_ready),
    .dmem_req_addr_o(ref_dmem_req_addr),
    .dmem_req_write_o(ref_dmem_req_write),
    .dmem_req_wdata_o(ref_dmem_req_wdata),
    .dmem_req_wstrb_o(ref_dmem_req_wstrb),
    .dmem_resp_valid_i(ref_dmem_resp_valid),
    .dmem_resp_rdata_i(ref_dmem_resp_rdata),
    .dmem_resp_error_i(ref_dmem_resp_error),
    .commit_valid_o(ref_commit_valid),
    .commit_pc_o(ref_commit_pc),
    .commit_instr_o(ref_commit_instr),
    .commit_rd_write_o(ref_commit_rd_write),
    .commit_rd_addr_o(ref_commit_rd_addr),
    .commit_rd_wdata_o(ref_commit_rd_wdata),
    .commit_mem_valid_o(ref_commit_mem_valid),
    .commit_mem_write_o(ref_commit_mem_write),
    .commit_mem_addr_o(ref_commit_mem_addr),
    .commit_mem_rmask_o(ref_commit_mem_rmask),
    .commit_mem_wmask_o(ref_commit_mem_wmask),
    .commit_mem_rdata_o(ref_commit_mem_rdata),
    .commit_mem_wdata_o(ref_commit_mem_wdata),
    .commit_trap_o(ref_commit_trap),
    .commit_trap_cause_o(ref_commit_trap_cause),
    .halted_o(ref_halted)
  );

  `ifdef RV32_OOO_DIFF_L1
    rv32_ooo_l1_top #(
      .ICACHE_BYTES(64),
      .ICACHE_LINE_BYTES(16),
      .DCACHE_BYTES(64),
      .DCACHE_LINE_BYTES(16)
    )
  `else
    rv32_ooo_core
  `endif
  ooo_core (
    .clk_i(clk),
    .rst_i(rst),
    .imem_req_valid_o(ooo_imem_req_valid),
    .imem_req_ready_i(ooo_imem_req_ready),
    .imem_req_addr_o(ooo_imem_req_addr),
    .imem_resp_valid_i(ooo_imem_resp_valid),
    .imem_resp_data_i(ooo_imem_resp_data),
    .imem_resp_error_i(ooo_imem_resp_error),
    .dmem_req_valid_o(ooo_dmem_req_valid),
    .dmem_req_ready_i(ooo_dmem_req_ready),
    .dmem_req_addr_o(ooo_dmem_req_addr),
    .dmem_req_write_o(ooo_dmem_req_write),
    .dmem_req_wdata_o(ooo_dmem_req_wdata),
    .dmem_req_wstrb_o(ooo_dmem_req_wstrb),
    .dmem_resp_valid_i(ooo_dmem_resp_valid),
    .dmem_resp_rdata_i(ooo_dmem_resp_rdata),
    .dmem_resp_error_i(ooo_dmem_resp_error),
    .commit_valid_o(ooo_commit_valid),
    .commit_pc_o(ooo_commit_pc),
    .commit_instr_o(ooo_commit_instr),
    .commit_rd_write_o(ooo_commit_rd_write),
    .commit_rd_addr_o(ooo_commit_rd_addr),
    .commit_rd_wdata_o(ooo_commit_rd_wdata),
    .commit_mem_valid_o(ooo_commit_mem_valid),
    .commit_mem_write_o(ooo_commit_mem_write),
    .commit_mem_addr_o(ooo_commit_mem_addr),
    .commit_mem_rmask_o(ooo_commit_mem_rmask),
    .commit_mem_wmask_o(ooo_commit_mem_wmask),
    .commit_mem_rdata_o(ooo_commit_mem_rdata),
    .commit_mem_wdata_o(ooo_commit_mem_wdata),
    .commit_trap_o(ooo_commit_trap),
    .commit_trap_cause_o(ooo_commit_trap_cause),
    .halted_o(ooo_halted)
  );

  // Independent memory instances start from the same image and are compared
  // only after both cores have reached their terminating trap.
  rv32_simple_memory ref_mem (
    .clk_i(clk),
    .rst_i(rst),
    .imem_req_valid_i(ref_imem_req_valid),
    .imem_req_ready_o(ref_imem_req_ready),
    .imem_req_addr_i(ref_imem_req_addr),
    .imem_resp_valid_o(ref_imem_resp_valid),
    .imem_resp_data_o(ref_imem_resp_data),
    .imem_resp_error_o(ref_imem_resp_error),
    .dmem_req_valid_i(ref_dmem_req_valid),
    .dmem_req_ready_o(ref_dmem_req_ready),
    .dmem_req_addr_i(ref_dmem_req_addr),
    .dmem_req_write_i(ref_dmem_req_write),
    .dmem_req_wdata_i(ref_dmem_req_wdata),
    .dmem_req_wstrb_i(ref_dmem_req_wstrb),
    .dmem_resp_valid_o(ref_dmem_resp_valid),
    .dmem_resp_rdata_o(ref_dmem_resp_rdata),
    .dmem_resp_error_o(ref_dmem_resp_error)
  );

  rv32_simple_memory ooo_mem (
    .clk_i(clk),
    .rst_i(rst),
    .imem_req_valid_i(ooo_imem_req_valid),
    .imem_req_ready_o(ooo_imem_req_ready),
    .imem_req_addr_i(ooo_imem_req_addr),
    .imem_resp_valid_o(ooo_imem_resp_valid),
    .imem_resp_data_o(ooo_imem_resp_data),
    .imem_resp_error_o(ooo_imem_resp_error),
    .dmem_req_valid_i(ooo_dmem_req_valid),
    .dmem_req_ready_o(ooo_dmem_req_ready),
    .dmem_req_addr_i(ooo_dmem_req_addr),
    .dmem_req_write_i(ooo_dmem_req_write),
    .dmem_req_wdata_i(ooo_dmem_req_wdata),
    .dmem_req_wstrb_i(ooo_dmem_req_wstrb),
    .dmem_resp_valid_o(ooo_dmem_resp_valid),
    .dmem_resp_rdata_o(ooo_dmem_resp_rdata),
    .dmem_resp_error_o(ooo_dmem_resp_error)
  );

  // Program loaders write identical instruction and data words to both models.
  initial clk = 1'b0;
  always #5 clk = ~clk;

  task automatic write_word_both(
    input logic [31:0] byte_addr,
    input logic [31:0] word_data
  );
    begin
      ref_mem.write_word(byte_addr, word_data);
      ooo_mem.write_word(byte_addr, word_data);
    end
  endtask

  task automatic load_mixed_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0140, 32'haabb_ccdd);
      write_word_both(32'h0000_0000, 32'h0060_0093); // ADDI x1, x0, 6
      write_word_both(32'h0000_0004, 32'h0030_8113); // ADDI x2, x1, 3
      write_word_both(32'h0000_0008, 32'h1000_0193); // ADDI x3, x0, 0x100
      write_word_both(32'h0000_000c, 32'h0021_a023); // SW x2, 0(x3)
      write_word_both(32'h0000_0010, 32'h0001_a203); // LW x4, 0(x3)
      write_word_both(32'h0000_0014, 32'h0022_0463); // BEQ x4, x2, +8
      write_word_both(32'h0000_0018, 32'h0010_0293); // ADDI x5, x0, 1 (skipped)
      write_word_both(32'h0000_001c, 32'h0022_1463); // BNE x4, x2, +8
      write_word_both(32'h0000_0020, 32'h0070_0293); // ADDI x5, x0, 7
      write_word_both(32'h0000_0024, 32'h0241_0333); // MUL x6, x2, x4
      write_word_both(32'h0000_0028, 32'h0213_43b3); // DIV x7, x6, x1
      write_word_both(32'h0000_002c, 32'h0053_8433); // ADD x8, x7, x5
      write_word_both(32'h0000_0030, 32'h0081_a223); // SW x8, 4(x3)
      write_word_both(32'h0000_0034, 32'h0401_a483); // LW x9, 64(x3), reads 0x140
      write_word_both(32'h0000_0038, 32'h0010_0073); // EBREAK
    end
  endtask

  task automatic load_control_flow_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0140, 32'haabb_ccdd);
      write_word_both(32'h0000_0000, 32'h1000_0193); // ADDI x3, x0, 0x100
      write_word_both(32'h0000_0004, 32'h0240_0093); // ADDI x1, x0, 0x24
      write_word_both(32'h0000_0008, 32'h00c0_02ef); // JAL x5, +12 -> 0x14
      write_word_both(32'h0000_000c, 32'h0010_0513); // ADDI x10, x0, 1 (skipped)
      write_word_both(32'h0000_0010, 32'h0020_0513); // ADDI x10, x0, 2 (skipped)
      write_word_both(32'h0000_0014, 32'h0042_8313); // ADDI x6, x5, 4
      write_word_both(32'h0000_0018, 32'h0000_83e7); // JALR x7, 0(x1) -> 0x24
      write_word_both(32'h0000_001c, 32'h0030_0593); // ADDI x11, x0, 3 (skipped)
      write_word_both(32'h0000_0020, 32'h0040_0593); // ADDI x11, x0, 4 (skipped)
      write_word_both(32'h0000_0024, 32'h0073_0433); // ADD x8, x6, x7
      write_word_both(32'h0000_0028, 32'h0081_a023); // SW x8, 0(x3)
      write_word_both(32'h0000_002c, 32'h0001_a483); // LW x9, 0(x3)
      write_word_both(32'h0000_0030, 32'h0401_a603); // LW x12, 64(x3), force dirty eviction
      write_word_both(32'h0000_0034, 32'h0010_0073); // EBREAK
    end
  endtask

  task automatic load_memory_widths_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0100, 32'h80ff_7f01);
      write_word_both(32'h0000_0140, 32'haabb_ccdd);
      write_word_both(32'h0000_0000, 32'h1000_0093); // ADDI x1, x0, 0x100
      write_word_both(32'h0000_0004, 32'h0000_8103); // LB   x2, 0(x1)
      write_word_both(32'h0000_0008, 32'h0010_8183); // LB   x3, 1(x1)
      write_word_both(32'h0000_000c, 32'h0020_8203); // LB   x4, 2(x1)
      write_word_both(32'h0000_0010, 32'h0020_c283); // LBU  x5, 2(x1)
      write_word_both(32'h0000_0014, 32'h0000_9303); // LH   x6, 0(x1)
      write_word_both(32'h0000_0018, 32'h0020_9383); // LH   x7, 2(x1)
      write_word_both(32'h0000_001c, 32'h0020_d403); // LHU  x8, 2(x1)
      write_word_both(32'h0000_0020, 32'hfff0_0493); // ADDI x9, x0, -1
      write_word_both(32'h0000_0024, 32'h0090_80a3); // SB   x9, 1(x1)
      write_word_both(32'h0000_0028, 32'h0050_9123); // SH   x5, 2(x1)
      write_word_both(32'h0000_002c, 32'h0000_a503); // LW   x10, 0(x1)
      write_word_both(32'h0000_0030, 32'h0400_a583); // LW   x11, 64(x1), evict
      write_word_both(32'h0000_0034, 32'h0010_0073); // EBREAK
    end
  endtask

  task automatic load_rv32m_edges_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0140, 32'haabb_ccdd);
      write_word_both(32'h0000_0000, 32'h1000_0a13); // ADDI x20, x0, 0x100
      write_word_both(32'h0000_0004, 32'hff90_0093); // ADDI x1, x0, -7
      write_word_both(32'h0000_0008, 32'h0030_0113); // ADDI x2, x0, 3
      write_word_both(32'h0000_000c, 32'h0220_91b3); // MULH   x3, x1, x2
      write_word_both(32'h0000_0010, 32'h0220_a233); // MULHSU x4, x1, x2
      write_word_both(32'h0000_0014, 32'h0220_b2b3); // MULHU  x5, x1, x2
      write_word_both(32'h0000_0018, 32'h0220_c333); // DIV    x6, x1, x2
      write_word_both(32'h0000_001c, 32'h0220_d3b3); // DIVU   x7, x1, x2
      write_word_both(32'h0000_0020, 32'h0220_e433); // REM    x8, x1, x2
      write_word_both(32'h0000_0024, 32'h0220_f4b3); // REMU   x9, x1, x2
      write_word_both(32'h0000_0028, 32'h0000_0513); // ADDI x10, x0, 0
      write_word_both(32'h0000_002c, 32'h02a0_c5b3); // DIV  x11, x1, x10
      write_word_both(32'h0000_0030, 32'h02a0_d633); // DIVU x12, x1, x10
      write_word_both(32'h0000_0034, 32'h02a0_e6b3); // REM  x13, x1, x10
      write_word_both(32'h0000_0038, 32'h02a0_f733); // REMU x14, x1, x10
      write_word_both(32'h0000_003c, 32'h8000_07b7); // LUI x15, 0x80000
      write_word_both(32'h0000_0040, 32'hfff0_0813); // ADDI x16, x0, -1
      write_word_both(32'h0000_0044, 32'h0307_c8b3); // DIV x17, x15, x16
      write_word_both(32'h0000_0048, 32'h0307_e933); // REM x18, x15, x16
      write_word_both(32'h0000_004c, 32'h005a_2023); // SW x5, 0(x20)
      write_word_both(32'h0000_0050, 32'h007a_2223); // SW x7, 4(x20)
      write_word_both(32'h0000_0054, 32'h00ba_2423); // SW x11, 8(x20)
      write_word_both(32'h0000_0058, 32'h011a_2623); // SW x17, 12(x20)
      write_word_both(32'h0000_005c, 32'h040a_2983); // LW x19, 64(x20), evict
      write_word_both(32'h0000_0060, 32'h0010_0073); // EBREAK
    end
  endtask

  task automatic load_illegal_instruction_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0100, 32'hdead_beef);
      write_word_both(32'h0000_0000, 32'h1000_0093); // ADDI x1, x0, 0x100
      write_word_both(32'h0000_0004, 32'hffff_ffff); // Illegal instruction
      write_word_both(32'h0000_0008, 32'h0010_0113); // ADDI x2, x0, 1 (must not retire)
      write_word_both(32'h0000_000c, 32'h0020_a023); // SW x2, 0(x1) (must not execute)
    end
  endtask

  task automatic load_misaligned_load_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0100, 32'hdead_beef);
      write_word_both(32'h0000_0000, 32'h1000_0093); // ADDI x1, x0, 0x100
      write_word_both(32'h0000_0004, 32'h0010_a103); // LW x2, 1(x1), address 0x101
      write_word_both(32'h0000_0008, 32'h0010_0193); // ADDI x3, x0, 1 (must not retire)
      write_word_both(32'h0000_000c, 32'h0030_a023); // SW x3, 0(x1) (must not execute)
    end
  endtask

  task automatic load_store_misaligned_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0100, 32'hdead_beef);
      write_word_both(32'h0000_0000, 32'h1000_0093); // ADDI x1, x0, 0x100
      write_word_both(32'h0000_0004, 32'h0550_0113); // ADDI x2, x0, 0x55
      write_word_both(32'h0000_0008, 32'h0020_a0a3); // SW x2, 1(x1), address 0x101
      write_word_both(32'h0000_000c, 32'h0010_0193); // ADDI x3, x0, 1 (must not retire)
      write_word_both(32'h0000_0010, 32'h0030_a023); // SW x3, 0(x1) (must not execute)
    end
  endtask

  task automatic load_access_fault_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0100, 32'hdead_beef);
      write_word_both(32'h0000_0000, 32'h1000_0193); // ADDI x3, x0, 0x100
      write_word_both(32'h0000_0004, 32'h0000_40b7); // LUI x1, 0x4 -> 0x4000
      write_word_both(32'h0000_0008, 32'h0000_a103); // LW x2, 0(x1), out of range
      write_word_both(32'h0000_000c, 32'h0010_0213); // ADDI x4, x0, 1 (must not retire)
      write_word_both(32'h0000_0010, 32'h0041_a023); // SW x4, 0(x3) (must not execute)
    end
  endtask

  task automatic load_store_access_fault_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0100, 32'hdead_beef);
      write_word_both(32'h0000_0000, 32'h1000_0193); // ADDI x3, x0, 0x100
      write_word_both(32'h0000_0004, 32'h0000_40b7); // LUI x1, 0x4 -> 0x4000
      write_word_both(32'h0000_0008, 32'h0550_0113); // ADDI x2, x0, 0x55
      write_word_both(32'h0000_000c, 32'h0020_a023); // SW x2, 0(x1), out of range
      write_word_both(32'h0000_0010, 32'h0010_0213); // ADDI x4, x0, 1 (must not retire)
      write_word_both(32'h0000_0014, 32'h0041_a023); // SW x4, 0(x3) (must not execute)
    end
  endtask

  task automatic load_rv32i_alu_edges_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0000, 32'h1000_0a13); // ADDI x20, x0, 0x100
      write_word_both(32'h0000_0004, 32'h8000_00b7); // LUI x1, 0x80000
      write_word_both(32'h0000_0008, 32'hfff0_0113); // ADDI x2, x0, -1
      write_word_both(32'h0000_000c, 32'h0010_0193); // ADDI x3, x0, 1
      write_word_both(32'h0000_0010, 32'h4021_8233); // SUB x4, x3, x2
      write_word_both(32'h0000_0014, 32'h0031_92b3); // SLL x5, x3, x3
      write_word_both(32'h0000_0018, 32'h0030_a333); // SLT x6, x1, x3
      write_word_both(32'h0000_001c, 32'h0030_b3b3); // SLTU x7, x1, x3
      write_word_both(32'h0000_0020, 32'h0020_c433); // XOR x8, x1, x2
      write_word_both(32'h0000_0024, 32'h0030_d4b3); // SRL x9, x1, x3
      write_word_both(32'h0000_0028, 32'h4030_d533); // SRA x10, x1, x3
      write_word_both(32'h0000_002c, 32'h0030_e5b3); // OR x11, x1, x3
      write_word_both(32'h0000_0030, 32'h0020_f633); // AND x12, x1, x2
      write_word_both(32'h0000_0034, 32'h01f1_9693); // SLLI x13, x3, 31
      write_word_both(32'h0000_0038, 32'h0000_a713); // SLTI x14, x1, 0
      write_word_both(32'h0000_003c, 32'h0011_3793); // SLTIU x15, x2, 1
      write_word_both(32'h0000_0040, 32'hfff0_c813); // XORI x16, x1, -1
      write_word_both(32'h0000_0044, 32'h01f0_d893); // SRLI x17, x1, 31
      write_word_both(32'h0000_0048, 32'h41f0_d913); // SRAI x18, x1, 31
      write_word_both(32'h0000_004c, 32'h0550_6993); // ORI x19, x0, 0x55
      write_word_both(32'h0000_0050, 32'h0ff1_7a93); // ANDI x21, x2, 0xff
      write_word_both(32'h0000_0054, 32'h0000_0b17); // AUIPC x22, 0
      write_word_both(32'h0000_0058, 32'h004a_2023); // SW x4, 0(x20)
      write_word_both(32'h0000_005c, 32'h006a_2223); // SW x6, 4(x20)
      write_word_both(32'h0000_0060, 32'h00aa_2423); // SW x10, 8(x20)
      write_word_both(32'h0000_0064, 32'h012a_2623); // SW x18, 12(x20)
      write_word_both(32'h0000_0068, 32'h040a_2b83); // LW x23, 64(x20), evict dirty line
      write_word_both(32'h0000_006c, 32'h0010_0073); // EBREAK
    end
  endtask

  task automatic load_branch_dependency_edges_program;
    begin
      ref_mem.clear_memory();
      ooo_mem.clear_memory();

      write_word_both(32'h0000_0000, 32'h1000_0a13); // ADDI x20, x0, 0x100
      write_word_both(32'h0000_0004, 32'hfff0_0093); // ADDI x1, x0, -1
      write_word_both(32'h0000_0008, 32'h0010_0113); // ADDI x2, x0, 1
      write_word_both(32'h0000_000c, 32'h0020_c463); // BLT x1, x2, +8 (taken)
      write_word_both(32'h0000_0010, 32'h001a_2023); // SW x1, 0(x20) (skipped)
      write_word_both(32'h0000_0014, 32'h0011_5463); // BGE x2, x1, +8 (taken)
      write_word_both(32'h0000_0018, 32'h001a_2023); // SW x1, 0(x20) (skipped)
      write_word_both(32'h0000_001c, 32'h0020_e463); // BLTU x1, x2, +8 (not taken)
      write_word_both(32'h0000_0020, 32'h0330_0613); // ADDI x12, x0, 0x33
      write_word_both(32'h0000_0024, 32'h0020_f463); // BGEU x1, x2, +8 (taken)
      write_word_both(32'h0000_0028, 32'h001a_2023); // SW x1, 0(x20) (skipped)
      write_word_both(32'h0000_002c, 32'h0050_0193); // ADDI x3, x0, 5
      write_word_both(32'h0000_0030, 32'h0071_8213); // ADDI x4, x3, 7
      write_word_both(32'h0000_0034, 32'h0232_02b3); // MUL x5, x4, x3
      write_word_both(32'h0000_0038, 32'h0232_c333); // DIV x6, x5, x3
      write_word_both(32'h0000_003c, 32'h0090_0393); // ADDI x7, x0, 9
      write_word_both(32'h0000_0040, 32'h0023_8433); // ADD x8, x7, x2
      write_word_both(32'h0000_0044, 32'h0083_04b3); // ADD x9, x6, x8
      write_word_both(32'h0000_0048, 32'h00ca_2023); // SW x12, 0(x20)
      write_word_both(32'h0000_004c, 32'h009a_2223); // SW x9, 4(x20)
      write_word_both(32'h0000_0050, 32'h040a_2a83); // LW x21, 64(x20), evict dirty line
      write_word_both(32'h0000_0054, 32'h0010_0073); // EBREAK
    end
  endtask

  // Each sampling function snapshots one valid Commit payload. Valid itself is
  // not stored because insertion into an event array already records the event.
  function automatic commit_event_t sample_ref_commit;
    begin
      sample_ref_commit = '0;
      sample_ref_commit.pc = ref_commit_pc;
      sample_ref_commit.instr = ref_commit_instr;
      sample_ref_commit.rd_write = ref_commit_rd_write;
      sample_ref_commit.rd_addr = ref_commit_rd_addr;
      sample_ref_commit.rd_wdata = ref_commit_rd_wdata;
      sample_ref_commit.mem_valid = ref_commit_mem_valid;
      sample_ref_commit.mem_write = ref_commit_mem_write;
      sample_ref_commit.mem_addr = ref_commit_mem_addr;
      sample_ref_commit.mem_rmask = ref_commit_mem_rmask;
      sample_ref_commit.mem_wmask = ref_commit_mem_wmask;
      sample_ref_commit.mem_rdata = ref_commit_mem_rdata;
      sample_ref_commit.mem_wdata = ref_commit_mem_wdata;
      sample_ref_commit.trap = ref_commit_trap;
      sample_ref_commit.trap_cause = ref_commit_trap_cause;
    end
  endfunction

  function automatic commit_event_t sample_ooo_commit;
    begin
      sample_ooo_commit = '0;
      sample_ooo_commit.pc = ooo_commit_pc;
      sample_ooo_commit.instr = ooo_commit_instr;
      sample_ooo_commit.rd_write = ooo_commit_rd_write;
      sample_ooo_commit.rd_addr = ooo_commit_rd_addr;
      sample_ooo_commit.rd_wdata = ooo_commit_rd_wdata;
      sample_ooo_commit.mem_valid = ooo_commit_mem_valid;
      sample_ooo_commit.mem_write = ooo_commit_mem_write;
      sample_ooo_commit.mem_addr = ooo_commit_mem_addr;
      sample_ooo_commit.mem_rmask = ooo_commit_mem_rmask;
      sample_ooo_commit.mem_wmask = ooo_commit_mem_wmask;
      sample_ooo_commit.mem_rdata = ooo_commit_mem_rdata;
      sample_ooo_commit.mem_wdata = ooo_commit_mem_wdata;
      sample_ooo_commit.trap = ooo_commit_trap;
      sample_ooo_commit.trap_cause = ooo_commit_trap_cause;
    end
  endfunction

  // Commit events are compared field by field so a mismatch identifies the
  // first architectural effect on which the implementations disagree.
  task automatic check_event(
    input int unsigned index,
    input commit_event_t ref_event,
    input commit_event_t ooo_event
  );
    begin
      if (ref_event.pc !== ooo_event.pc) begin
        $fatal(1, "Commit %0d: PC mismatch: ref=0x%08x, ooo=0x%08x", index, ref_event.pc, ooo_event.pc);
      end
      if (ref_event.instr !== ooo_event.instr) begin
        $fatal(1, "Commit %0d: Instruction mismatch: ref=0x%08x, ooo=0x%08x", index, ref_event.instr, ooo_event.instr);
      end
      if (ref_event.rd_write !== ooo_event.rd_write) begin
        $fatal(1, "Commit %0d: RD write mismatch: ref=%b, ooo=%b", index, ref_event.rd_write, ooo_event.rd_write);
      end
      if (ref_event.mem_valid !== ooo_event.mem_valid) begin
        $fatal(1, "Commit %0d: Memory valid mismatch: ref=%b, ooo=%b", index, ref_event.mem_valid, ooo_event.mem_valid);
      end
      if (ref_event.trap !== ooo_event.trap) begin
        $fatal(1, "Commit %0d: Trap mismatch: ref=%b, ooo=%b", index, ref_event.trap, ooo_event.trap);
      end
      if (ref_event.rd_write) begin
        if (ref_event.rd_addr !== ooo_event.rd_addr) begin
          $fatal(1, "Commit %0d: RD address mismatch: ref=%0d, ooo=%0d", index, ref_event.rd_addr, ooo_event.rd_addr);
        end
        if (ref_event.rd_wdata !== ooo_event.rd_wdata) begin
          $fatal(1, "Commit %0d: RD write data mismatch: ref=0x%08x, ooo=0x%08x", index, ref_event.rd_wdata, ooo_event.rd_wdata);
        end
      end
      if (ref_event.mem_valid) begin
        if (ref_event.mem_write !== ooo_event.mem_write) begin
          $fatal(1, "Commit %0d: Memory write mismatch: ref=%b, ooo=%b", index, ref_event.mem_write, ooo_event.mem_write);
        end
        if (ref_event.mem_addr !== ooo_event.mem_addr) begin
          $fatal(1, "Commit %0d: Memory address mismatch: ref=0x%08x, ooo=0x%08x", index, ref_event.mem_addr, ooo_event.mem_addr);
        end
        if (ref_event.mem_rmask !== ooo_event.mem_rmask) begin
          $fatal(1, "Commit %0d: Memory read mask mismatch: ref=0x%01x, ooo=0x%01x", index, ref_event.mem_rmask, ooo_event.mem_rmask);
        end
        if (ref_event.mem_wmask !== ooo_event.mem_wmask) begin
          $fatal(1, "Commit %0d: Memory write mask mismatch: ref=0x%01x, ooo=0x%01x", index, ref_event.mem_wmask, ooo_event.mem_wmask);
        end
        if (ref_event.mem_write) begin
          if (ref_event.mem_wdata !== ooo_event.mem_wdata) begin
            $fatal(1, "Commit %0d: Memory write data mismatch: ref=0x%08x, ooo=0x%08x", index, ref_event.mem_wdata, ooo_event.mem_wdata);
          end
        end else begin
          if (ref_event.mem_rdata !== ooo_event.mem_rdata) begin
            $fatal(1, "Commit %0d: Memory read data mismatch: ref=0x%08x, ooo=0x%08x", index, ref_event.mem_rdata, ooo_event.mem_rdata);
          end
        end
      end
      if (ref_event.trap && ref_event.trap_cause !== ooo_event.trap_cause) begin
        $fatal(1, "Commit %0d: Trap cause mismatch: ref=%0d, ooo=%0d", index, ref_event.trap_cause, ooo_event.trap_cause);
      end
    end
  endtask

  task automatic check_memory_signature;
    begin
      case (test_name)
        "mixed": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'd9 || ooo_mem.read_word(32'h0000_0100) !== 32'd9)
            $fatal(1, "mixed result at 0x100 is incorrect");
          if (ref_mem.read_word(32'h0000_0104) !== 32'd20 || ooo_mem.read_word(32'h0000_0104) !== 32'd20)
            $fatal(1, "mixed result at 0x104 is incorrect");
        end
        "control_flow": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'd44 || ooo_mem.read_word(32'h0000_0100) !== 32'd44)
            $fatal(1, "control_flow result at 0x100 is incorrect");
        end
        "memory_widths": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'h00ff_ff01 ||
              ooo_mem.read_word(32'h0000_0100) !== 32'h00ff_ff01) begin
            $fatal(1, "memory_widths result at 0x100 is incorrect");
          end
        end
        "rv32m_edges": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'h0000_0002 ||
              ooo_mem.read_word(32'h0000_0100) !== 32'h0000_0002 ||
              ref_mem.read_word(32'h0000_0104) !== 32'h5555_5553 ||
              ooo_mem.read_word(32'h0000_0104) !== 32'h5555_5553 ||
              ref_mem.read_word(32'h0000_0108) !== 32'hffff_ffff ||
              ooo_mem.read_word(32'h0000_0108) !== 32'hffff_ffff ||
              ref_mem.read_word(32'h0000_010c) !== 32'h8000_0000 ||
              ooo_mem.read_word(32'h0000_010c) !== 32'h8000_0000) begin
            $fatal(1, "rv32m_edges memory signature is incorrect");
          end
        end
        "illegal_instructions": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'hdead_beef ||
              ooo_mem.read_word(32'h0000_0100) !== 32'hdead_beef) begin
            $fatal(1, "illegal_instructions memory signature is incorrect");
          end
        end
        "load_misaligned": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'hdead_beef ||
              ooo_mem.read_word(32'h0000_0100) !== 32'hdead_beef) begin
            $fatal(1, "load_misaligned memory signature is incorrect");
          end
        end
        "store_misaligned": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'hdead_beef ||
              ooo_mem.read_word(32'h0000_0100) !== 32'hdead_beef) begin
            $fatal(1, "store_misaligned memory signature is incorrect");
          end
        end
        "load_access_fault": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'hdead_beef ||
              ooo_mem.read_word(32'h0000_0100) !== 32'hdead_beef) begin
            $fatal(1, "load_access_fault memory signature is incorrect");
          end
        end
        "store_access_fault": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'hdead_beef ||
              ooo_mem.read_word(32'h0000_0100) !== 32'hdead_beef) begin
            $fatal(1, "store_access_fault memory signature is incorrect");
          end
        end
        "rv32i_alu_edges": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'h0000_0002 ||
              ooo_mem.read_word(32'h0000_0100) !== 32'h0000_0002 ||
              ref_mem.read_word(32'h0000_0104) !== 32'h0000_0001 ||
              ooo_mem.read_word(32'h0000_0104) !== 32'h0000_0001 ||
              ref_mem.read_word(32'h0000_0108) !== 32'hc000_0000 ||
              ooo_mem.read_word(32'h0000_0108) !== 32'hc000_0000 ||
              ref_mem.read_word(32'h0000_010c) !== 32'hffff_ffff ||
              ooo_mem.read_word(32'h0000_010c) !== 32'hffff_ffff) begin
            $fatal(1, "rv32i_alu_edges memory signature is incorrect");
          end
        end
        "branch_dependency_edges": begin
          if (ref_mem.read_word(32'h0000_0100) !== 32'h0000_0033 ||
              ooo_mem.read_word(32'h0000_0100) !== 32'h0000_0033 ||
              ref_mem.read_word(32'h0000_0104) !== 32'h0000_0016 ||
              ooo_mem.read_word(32'h0000_0104) !== 32'h0000_0016) begin
            $fatal(1, "branch_dependency_edges memory signature is incorrect");
          end
        end
        default: $fatal(1, "No signature checker for test: %0s", test_name);
      endcase
    end
  endtask

  // Misaligned accesses must trap inside the LSU without reaching either data
  // memory interface.
  always @(posedge clk) begin
    if (!rst && (test_name == "load_misaligned" || test_name == "store_misaligned")) begin
      if (ref_dmem_req_valid || ooo_dmem_req_valid) begin
        $fatal(1, "Misaligned access issued a data-memory request");
      end
    end
  end

  // Commit events are queued independently and compared by retirement order,
  // never by cycle. The negative edge observes settled one-cycle Commit pulses.
  always @(negedge clk) begin
    if (!rst) begin
      cycle_count = cycle_count + 1;

      if (ref_commit_valid) begin
        if (ref_commit_count >= MAX_COMMITS) begin
          $fatal(1, "Reference commit array overflow");
        end else begin
          ref_events[ref_commit_count] = sample_ref_commit();
          ref_commit_count = ref_commit_count + 1;
        end
      end

      if (ooo_commit_valid) begin
        if (ooo_commit_count >= MAX_COMMITS) begin
          $fatal(1, "OoO commit array overflow");
        end else begin
          ooo_events[ooo_commit_count] = sample_ooo_commit();
          ooo_commit_count = ooo_commit_count + 1;
        end
      end

      while (compared_count < ref_commit_count && compared_count < ooo_commit_count) begin
        check_event(compared_count, ref_events[compared_count], ooo_events[compared_count]);
        compared_count = compared_count + 1;
      end

      if (ref_halted && ooo_halted) begin
        if (ref_commit_count !== ooo_commit_count) begin
          $fatal(1, "Commit count mismatch: ref=%0d ooo=%0d", ref_commit_count, ooo_commit_count);
        end
        if (compared_count !== ref_commit_count) begin
          $fatal(1, "Not all commits compared: compared=%0d ref=%0d", compared_count, ref_commit_count);
        end
        if (ref_commit_count !== expected_commits) begin
          $fatal(1, "Unexpected commit count: expected=%0d actual=%0d", expected_commits, ref_commit_count);
        end
        final_ref_event = ref_events[ref_commit_count-1];
        if (!final_ref_event.trap || final_ref_event.trap_cause !== expected_trap_cause) begin
          $fatal(1, "Program did not terminate with the expected trap");
        end
        check_memory_signature();
        $display("rv32_ooo_differential_tb: %0s PASS - %0d commits compared in %0d cycles", test_name, compared_count, cycle_count);
        $finish;
      end else if (cycle_count >= MAX_CYCLES) begin
        $fatal(1, "Differential timeout: ref=%0d ooo=%0d compared=%0d", ref_commit_count, ooo_commit_count, compared_count);
      end
    end
  end

  initial begin
    rst = 1'b1;
    ref_commit_count = 0;
    ooo_commit_count = 0;
    compared_count = 0;
    cycle_count = 0;

    if (!$value$plusargs("TEST=%s", test_name)) begin
      test_name = "mixed";
    end

    expected_trap_cause = rv32_core_pkg::CORE_TRAP_BREAKPOINT;

    case (test_name)
      "mixed": begin
        expected_commits = 14;
        load_mixed_program();
      end
      "control_flow": begin
        expected_commits = 10;
        load_control_flow_program();
      end
      "memory_widths": begin
        expected_commits = 14;
        load_memory_widths_program();
      end
      "rv32m_edges": begin
        expected_commits = 25;
        load_rv32m_edges_program();
      end
      "illegal_instructions": begin
        expected_commits = 2;
        expected_trap_cause = rv32_core_pkg::CORE_TRAP_ILLEGAL_INSTRUCTION;
        load_illegal_instruction_program();
      end
      "load_misaligned": begin
        expected_commits = 2;
        expected_trap_cause = rv32_core_pkg::CORE_TRAP_LOAD_ADDRESS_MISALIGNED;
        load_misaligned_load_program();
      end
      "store_misaligned": begin
        expected_commits = 3;
        expected_trap_cause = rv32_core_pkg::CORE_TRAP_STORE_ADDRESS_MISALIGNED;
        load_store_misaligned_program();
      end
      "load_access_fault": begin
        expected_commits = 3;
        expected_trap_cause = rv32_core_pkg::CORE_TRAP_LOAD_ACCESS_FAULT;
        load_access_fault_program();
      end
      "store_access_fault": begin
        expected_commits = 4;
        expected_trap_cause = rv32_core_pkg::CORE_TRAP_STORE_ACCESS_FAULT;
        load_store_access_fault_program();
      end
      "rv32i_alu_edges": begin
        expected_commits = 28;
        load_rv32i_alu_edges_program();
      end
      "branch_dependency_edges": begin
        expected_commits = 19;
        load_branch_dependency_edges_program();
      end
      default: begin
        $fatal(1, "Unknown differential test: %s", test_name);
      end
    endcase

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
  end

endmodule
