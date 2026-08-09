// SPDX-License-Identifier: Apache-2.0
//
// Self-checking directed-program testbench for the multi-cycle reference core.
// It checks fetch/response timing, architectural commits, control flow, memory
// side effects, RV32M integration, final register state, and final memory state.

`timescale 1ns/1ps

module rv32_reference_core_tb;

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

  rv32_reference_core dut (
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
    #9999;
    $fatal(1, "rv32_reference_core_tb: timeout");
  end

  // Normal and memory commits use separate checkers so every architecturally
  // meaningful field is compared without giving non-memory instructions a long
  // list of unused expected values.
  task automatic check_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic expected_rd_write,
    input logic [4:0] expected_rd_addr,
    input logic [31:0] expected_rd_wdata
  );
    int cycles;
    begin
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 50) begin
        @(posedge clk);
        #1;
        cycles++;
      end
      if (commit_valid !== 1'b1) begin
        $fatal(1, "commit timeout: expected PC %h", expected_pc);
      end
      if (commit_pc !== expected_pc) begin
        $error("wrong commit PC: expected %h, got %h", expected_pc, commit_pc);
        errors++;
      end
      if (commit_instr !== expected_instr) begin
        $error("wrong commit instruction: expected %h, got %h", expected_instr, commit_instr);
        errors++;
      end
      if (commit_rd_write !== expected_rd_write) begin
        $error("wrong commit rd_write: expected %b, got %b", expected_rd_write, commit_rd_write);
        errors++;
      end
      if (commit_rd_addr !== expected_rd_addr) begin
        $error("wrong commit rd_addr: expected %d, got %d", expected_rd_addr, commit_rd_addr);
        errors++;
      end
      if (commit_rd_wdata !== expected_rd_wdata) begin
        $error("wrong commit rd_wdata: expected %h, got %h", expected_rd_wdata, commit_rd_wdata);
        errors++;
      end
      if (commit_mem_valid !== 1'b0 || commit_trap !== 1'b0) begin
        $error("unexpected commit memory operation or trap side effect during ALU commit");
        errors++;
      end
      @(posedge clk);
      #1;

      if (commit_valid !== 1'b0) begin
        $error("commit lasted more than one cycle");
        errors++;
      end
      if (commit_rd_write !== 1'b0) begin
        $error("commit rd write remained active outside COMMIT");
        errors++;
      end
    end
  endtask

  task automatic check_memory_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic expected_rd_write,
    input logic [4:0] expected_rd_addr,
    input logic [31:0] expected_rd_wdata,
    input logic expected_mem_write,
    input logic [31:0] expected_mem_addr,
    input logic [3:0] expected_mem_rmask,
    input logic [3:0] expected_mem_wmask,
    input logic [31:0] expected_mem_rdata,
    input logic [31:0] expected_mem_wdata
  );
    int cycles;
    begin
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 50) begin
        @(posedge clk);
        #1;
        cycles++;
      end
      if (commit_valid !== 1'b1) begin
        $fatal(1, "commit timeout: expected PC %h", expected_pc);
      end
      if (commit_pc !== expected_pc) begin
        $error("wrong commit PC: expected %h, got %h", expected_pc, commit_pc);
        errors++;
      end
      if (commit_instr !== expected_instr) begin
        $error("wrong commit instruction: expected %h, got %h", expected_instr, commit_instr);
        errors++;
      end
      if (commit_rd_write !== expected_rd_write) begin
        $error("wrong commit rd_write: expected %b, got %b", expected_rd_write, commit_rd_write);
        errors++;
      end
      if (commit_rd_addr !== expected_rd_addr) begin
        $error("wrong commit rd_addr: expected %d, got %d", expected_rd_addr, commit_rd_addr);
        errors++;
      end
      if (commit_rd_wdata !== expected_rd_wdata) begin
        $error("wrong commit rd_wdata: expected %h, got %h", expected_rd_wdata, commit_rd_wdata);
        errors++;
      end
      if (commit_mem_valid !== 1'b1) begin
        $error("memory commit is not valid");
        errors++;
      end
      if (commit_trap !== 1'b0) begin
        $error("unexpected trap during memory commit");
        errors++;
      end
      if (commit_mem_write !== expected_mem_write) begin
        $error("wrong commit mem_write: expected %b, got %b", expected_mem_write, commit_mem_write);
        errors++;
      end
      if (commit_mem_addr !== expected_mem_addr) begin
        $error("wrong memory address");
        errors++;
      end
      if (commit_mem_rmask !== expected_mem_rmask) begin
        $error("wrong memory read mask");
        errors++;
      end
      if (commit_mem_wmask !== expected_mem_wmask) begin
        $error("wrong memory write mask");
        errors++;
      end
      if (commit_mem_rdata !== expected_mem_rdata) begin
        $error("wrong memory read data");
        errors++;
      end
      if (commit_mem_wdata !== expected_mem_wdata) begin
        $error("wrong memory write data");
        errors++;
      end

      @(posedge clk);
      #1;

      if (commit_valid !== 1'b0) begin
        $error("commit lasted more than one cycle");
        errors++;
      end
      if (commit_rd_write !== 1'b0) begin
        $error("commit rd write remained active outside COMMIT");
        errors++;
      end
      if (commit_mem_valid !== 1'b0) begin
        $error("commit memory valid remained active outside COMMIT");
        errors++;
      end

    end
  endtask

  initial begin
    rst = 1'b1;
    errors = 0;
    #1;
    memory_model.clear_memory();
    memory_model.write_word(32'h0000_0000, 32'h0050_0093); // ADDI x1, x0, 5
    memory_model.write_word(32'h0000_0004, 32'h0030_8113); // ADDI x2, x1, 3
    memory_model.write_word(32'h0000_0008, 32'h0020_81b3); // ADD  x3, x1, x2
    memory_model.write_word(32'h0000_000c, 32'h0010_8463); // BEQ x1, x1, 8
    memory_model.write_word(32'h0000_0010, 32'h0630_0213); // ADDI x4, x0, 99
    memory_model.write_word(32'h0000_0014, 32'h0010_9463); // BNE x1, x1, 8
    memory_model.write_word(32'h0000_0018, 32'h0080_02ef); // JAL x5, 8
    memory_model.write_word(32'h0000_001c, 32'h0580_0213); // ADDI x4, x0, 88
    memory_model.write_word(32'h0000_0020, 32'h02d0_0313); // ADDI x6, x0, 45
    memory_model.write_word(32'h0000_0024, 32'h0003_03e7); // JALR x7, x6, 0
    memory_model.write_word(32'h0000_0028, 32'h04d0_0213); // ADDI x4, x0, 77
    memory_model.write_word(32'h0000_002c, 32'h0080_0413); // ADDI x8, x0, 8
    memory_model.write_word(32'h0000_0030, 32'h0000_0493); // ADDI x9, x0, 0
    memory_model.write_word(32'h0000_0034, 32'h0014_8493); // ADDI x9, x9, 1
    memory_model.write_word(32'h0000_0038, 32'h0020_0513); // ADDI x10, x0, 2
    memory_model.write_word(32'h0000_003c, 32'hfea4_cce3); // BLT x9, x10, -8
    memory_model.write_word(32'h0000_0040, 32'h00b0_0593); // ADDI x11, x0, 11
    memory_model.write_word(32'h0000_0044, 32'h1000_0613); // ADDI x12, x0, 256
    memory_model.write_word(32'h0000_0048, 32'h1230_0693); // ADDI x13, x0, 0x123
    memory_model.write_word(32'h0000_004c, 32'h00d6_2023); // SW x13, 0(x12)
    memory_model.write_word(32'h0000_0050, 32'h0006_2703); // LW x14, 0(x12)
    memory_model.write_word(32'h0000_0054, 32'h0017_0793); // ADDI x15, x14, 1
    memory_model.write_word(32'h0000_0058, 32'hf800_0813); // ADDI x16, x0, -128
    memory_model.write_word(32'h0000_005c, 32'h0106_00a3); // SB x16, 1(x12)
    memory_model.write_word(32'h0000_0060, 32'h0016_0883); // LB x17, 1(x12)
    memory_model.write_word(32'h0000_0064, 32'h0016_4903); // LBU x18, 1(x12)
    memory_model.write_word(32'h0000_0068, 32'h0128_89b3); // ADD x19, x17, x18
    memory_model.write_word(32'h0000_006c, 32'h0000_8a37); // LUI x20, 0x8
    memory_model.write_word(32'h0000_0070, 32'h001a_0a13); // ADDI x20, x20, 1
    memory_model.write_word(32'h0000_0074, 32'h0146_1123); // SH x20, 2(x12)
    memory_model.write_word(32'h0000_0078, 32'h0026_1a83); // LH x21, 2(x12)
    memory_model.write_word(32'h0000_007c, 32'h0026_5b03); // LHU x22, 2(x12)
    memory_model.write_word(32'h0000_0080, 32'h016a_8bb3); // ADD x23, x21, x22
    memory_model.write_word(32'h0000_0084, 32'h0231_0c33); // MUL x24, x2, x3
    memory_model.write_word(32'h0000_0088, 32'h0211_ccb3); // DIV x25, x3, x1
    memory_model.write_word(32'h0000_008c, 32'h0211_ed33); // REM x26, x3, x1
    memory_model.write_word(32'h0000_0090, 32'h01ac_8db3); // ADD x27, x25, x26

    repeat (2) @(posedge clk);
    #1;
    if (imem_req_valid !== 1'b0) begin
      $error("instruction request active during reset");
      errors++;
    end
    if (commit_valid !== 1'b0) begin
      $error("commit active during reset");
      errors++;
    end
    @(negedge clk);
    #1;
    rst = 1'b0;
    wait (imem_req_valid === 1'b1);
    #1;

    if (imem_req_addr !== 32'h0000_0000) begin
      $error("wrong fetch address: expected 0x00000000, got %h", imem_req_addr);
      errors++;
    end
    if (commit_valid !== 1'b0) begin
      $error("commit active during first fetch");
      errors++;
    end

    @(posedge clk);
    #1;
    if (imem_req_valid !== 1'b0) begin
      $error("instruction request active during fetch wait");
      errors++;
    end

    wait (imem_resp_valid === 1'b1);
    #1;
    if (imem_resp_error !== 1'b0) begin
      $error("unexpected instruction response error");
      errors++;
    end
    if (imem_resp_data !== 32'h0050_0093) begin
      $error("wrong instruction response data: expected 0x00500093, got %h", imem_resp_data);
      errors++;
    end

    @(posedge clk);
    #1;
    if (imem_req_valid !== 1'b0) begin
      $error("instruction request active during execute");
      errors++;
    end
    if (dut.instr_q !== 32'h0050_0093) begin
      $error("wrong instruction in execute: expected 0x00500093, got %h", dut.instr_q);
      errors++;
    end
    if (dut.rs1_addr !== 5'd0) begin
      $error("wrong rs1 address");
      errors++;
    end
    if (dut.rd_addr !== 5'd1) begin
      $error("wrong rd address");
      errors++;
    end
    if (dut.rs1_used !== 1'b1 || dut.rs2_used !== 1'b0) begin
      $error("wrong source-use flags");
      errors++;
    end
    if (dut.alu_op !== rv32_pkg::ALU_ADD) begin
      $error("wrong ALU operation");
      errors++;
    end
    if (dut.operand_a_sel !== rv32_pkg::OP_A_RS1) begin
      $error("wrong operand A selection");
      errors++;
    end
    if (dut.operand_b_sel !== rv32_pkg::OP_B_IMM) begin
      $error("wrong operand B selection");
      errors++;
    end
    if (dut.imm_kind !== rv32_pkg::IMM_I || dut.imm !== 32'd5) begin
      $error("wrong immediate");
      errors++;
    end
    if (dut.alu_lhs !== 32'd0 || dut.alu_rhs !== 32'd5) begin
      $error("wrong ALU operands");
      errors++;
    end
    if (dut.alu_result !== 32'd5) begin
      $error("wrong ALU result");
      errors++;
    end
    if (dut.reg_write !== 1'b1 || dut.illegal !== 1'b0) begin
      $error("wrong decoder control outputs");
      errors++;
    end
    if (commit_valid !== 1'b0) begin
      $error("commit active during execute");
      errors++;
    end
    if (imem_resp_valid !== 1'b0) begin
      $error("instruction response lasted more than one cycle");
      errors++;
    end

    check_commit(32'h0000_0000, 32'h0050_0093, 1'b1, 5'd1, 32'h0000_0005);
    check_commit(32'h0000_0004, 32'h0030_8113, 1'b1, 5'd2, 32'h0000_0008);
    check_commit(32'h0000_0008, 32'h0020_81b3, 1'b1, 5'd3, 32'h0000_000d);
    check_commit(32'h0000_000c, 32'h0010_8463, 1'b0, 5'd0, 32'h0000_0000);
    check_commit(32'h0000_0014, 32'h0010_9463, 1'b0, 5'd0, 32'h0000_0000);
    check_commit(32'h0000_0018, 32'h0080_02ef, 1'b1, 5'd5, 32'h0000_001c);
    check_commit(32'h0000_0020, 32'h02d0_0313, 1'b1, 5'd6, 32'h0000_002d);
    check_commit(32'h0000_0024, 32'h0003_03e7, 1'b1, 5'd7, 32'h0000_0028);
    check_commit(32'h0000_002c, 32'h0080_0413, 1'b1, 5'd8, 32'h0000_0008);
    check_commit(32'h0000_0030, 32'h0000_0493, 1'b1, 5'd9, 32'h0000_0000);
    check_commit(32'h0000_0034, 32'h0014_8493, 1'b1, 5'd9, 32'h0000_0001);
    check_commit(32'h0000_0038, 32'h0020_0513, 1'b1, 5'd10, 32'h0000_0002);
    check_commit(32'h0000_003c, 32'hfea4_cce3, 1'b0, 5'd0, 32'h0000_0000);
    check_commit(32'h0000_0034, 32'h0014_8493, 1'b1, 5'd9, 32'h0000_0002);
    check_commit(32'h0000_0038, 32'h0020_0513, 1'b1, 5'd10, 32'h0000_0002);
    check_commit(32'h0000_003c, 32'hfea4_cce3, 1'b0, 5'd0, 32'h0000_0000);
    check_commit(32'h0000_0040, 32'h00b0_0593, 1'b1, 5'd11, 32'h0000_000b);
    check_commit(32'h0000_0044, 32'h1000_0613, 1'b1, 5'd12, 32'h0000_0100);
    check_commit(32'h0000_0048, 32'h1230_0693, 1'b1, 5'd13, 32'h0000_0123);
    check_memory_commit(32'h0000_004c, 32'h00d6_2023, 1'b0, 5'd0, 32'h0000_0000, 1'b1, 32'h0000_0100, 4'b0000, 4'b1111, 32'h0000_0000, 32'h0000_0123);
    check_memory_commit(32'h0000_0050, 32'h0006_2703, 1'b1, 5'd14, 32'h0000_0123, 1'b0, 32'h0000_0100, 4'b1111, 4'b0000, 32'h0000_0123, 32'h0000_0000);
    check_commit(32'h0000_0054, 32'h0017_0793, 1'b1, 5'd15, 32'h0000_0124);
    check_commit(32'h0000_0058, 32'hf800_0813, 1'b1, 5'd16, 32'hffff_ff80);
    check_memory_commit(32'h0000_005c, 32'h0106_00a3, 1'b0, 5'd0, 32'h0000_0000, 1'b1, 32'h0000_0100, 4'b0000, 4'b0010, 32'h0000_0000, 32'h0000_8000);
    check_memory_commit(32'h0000_0060, 32'h0016_0883, 1'b1, 5'd17, 32'hffff_ff80, 1'b0, 32'h0000_0100, 4'b0010, 4'b0000, 32'h0000_8023, 32'h0000_0000);
    check_memory_commit(32'h0000_0064, 32'h0016_4903, 1'b1, 5'd18, 32'h0000_0080, 1'b0, 32'h0000_0100, 4'b0010, 4'b0000, 32'h0000_8023, 32'h0000_0000);
    check_commit(32'h0000_0068, 32'h0128_89b3, 1'b1, 5'd19, 32'h0000_0000);
    check_commit(32'h0000_006c, 32'h0000_8a37, 1'b1, 5'd20, 32'h0000_8000);
    check_commit(32'h0000_0070, 32'h001a_0a13, 1'b1, 5'd20, 32'h0000_8001);
    check_memory_commit(32'h0000_0074, 32'h0146_1123, 1'b0, 5'd0, 32'h0000_0000, 1'b1, 32'h0000_0100, 4'b0000, 4'b1100, 32'h0000_0000, 32'h8001_0000);
    check_memory_commit(32'h0000_0078, 32'h0026_1a83, 1'b1, 5'd21, 32'hffff_8001, 1'b0, 32'h0000_0100, 4'b1100, 4'b0000, 32'h8001_8023, 32'h0000_0000);
    check_memory_commit(32'h0000_007c, 32'h0026_5b03, 1'b1, 5'd22, 32'h0000_8001, 1'b0, 32'h0000_0100, 4'b1100, 4'b0000, 32'h8001_8023, 32'h0000_0000);
    check_commit(32'h0000_0080, 32'h016a_8bb3, 1'b1, 5'd23, 32'h0000_0002);
    check_commit(32'h0000_0084, 32'h0231_0c33, 1'b1, 5'd24, 32'h0000_0068);
    check_commit(32'h0000_0088, 32'h0211_ccb3, 1'b1, 5'd25, 32'h0000_0002);
    check_commit(32'h0000_008c, 32'h0211_ed33, 1'b1, 5'd26, 32'h0000_0003);
    check_commit(32'h0000_0090, 32'h01ac_8db3, 1'b1, 5'd27, 32'h0000_0005);

    if (dut.regfile.registers[1] !== 32'd5) begin
      $error("wrong final x1 value");
      errors++;
    end
    if (dut.regfile.registers[2] !== 32'd8) begin
      $error("wrong final x2 value");
      errors++;
    end
    if (dut.regfile.registers[3] !== 32'd13) begin
      $error("wrong final x3 value");
      errors++;
    end
    if (dut.regfile.registers[4] !== 32'd0) begin
      $error("wrong final x4 value");
      errors++;
    end
    if (dut.regfile.registers[5] !== 32'd28) begin
      $error("wrong final x5 value");
      errors++;
    end
    if (dut.regfile.registers[6] !== 32'd45) begin
      $error("wrong final x6 value");
      errors++;
    end
    if (dut.regfile.registers[7] !== 32'd40) begin
      $error("wrong final x7 value");
      errors++;
    end
    if (dut.regfile.registers[8] !== 32'd8) begin
      $error("wrong final x8 value");
      errors++;
    end
    if (dut.regfile.registers[9] !== 32'd2) begin
      $error("wrong final x9 value");
      errors++;
    end
    if (dut.regfile.registers[10] !== 32'd2) begin
      $error("wrong final x10 value");
      errors++;
    end
    if (dut.regfile.registers[11] !== 32'd11) begin
      $error("wrong final x11 value");
      errors++;
    end
    if (dut.regfile.registers[12] !== 32'h0000_0100) begin
      $error("wrong final x12 value");
      errors++;
    end
    if (dut.regfile.registers[13] !== 32'h0000_0123) begin
      $error("wrong final x13 value");
      errors++;
    end
    if (dut.regfile.registers[14] !== 32'h0000_0123) begin
      $error("wrong final x14 value");
      errors++;
    end
    if (dut.regfile.registers[15] !== 32'h0000_0124) begin
      $error("wrong final x15 value");
      errors++;
    end
    if (dut.regfile.registers[16] !== 32'hffff_ff80) begin
      $error("wrong x16 value");
      errors++;
    end
    if (dut.regfile.registers[17] !== 32'hffff_ff80) begin
      $error("wrong x17 value");
      errors++;
    end
    if (dut.regfile.registers[18] !== 32'h0000_0080) begin
      $error("wrong x18 value");
      errors++;
    end
    if (dut.regfile.registers[19] !== 32'h0000_0000) begin
      $error("wrong x19 value");
      errors++;
    end
    if (dut.regfile.registers[20] !== 32'h0000_8001) begin
      $error("wrong final x20 value");
      errors++;
    end
    if (dut.regfile.registers[21] !== 32'hffff_8001) begin
      $error("wrong final x21 value");
      errors++;
    end
    if (dut.regfile.registers[22] !== 32'h0000_8001) begin
      $error("wrong final x22 value");
      errors++;
    end
    if (dut.regfile.registers[23] !== 32'h0000_0002) begin
      $error("wrong final x23 value");
      errors++;
    end
    if (dut.regfile.registers[24] !== 32'h0000_0068) begin
      $error("wrong final x24 value");
      errors++;
    end
    if (dut.regfile.registers[25] !== 32'h0000_0002) begin
      $error("wrong final x25 value");
      errors++;
    end
    if (dut.regfile.registers[26] !== 32'h0000_0003) begin
      $error("wrong final x26 value");
      errors++;
    end
    if (dut.regfile.registers[27] !== 32'h0000_0005) begin
      $error("wrong final x27 value");
      errors++;
    end

    if (memory_model.read_word(32'h0000_0100) !== 32'h8001_8023)
    begin
      $error("wrong final memory value at 0x00000100");
      errors++;
    end

    if (errors != 0) begin
      $fatal(1, "rv32_reference_core_tb: %0d errors detected", errors);
    end
    $display("rv32_reference_core_tb: PASS");
    $finish;

  end

endmodule
