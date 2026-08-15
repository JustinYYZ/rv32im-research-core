// SPDX-License-Identifier: Apache-2.0
//
// Directed trap and halt tests for the five-stage pipeline core.
//
// The test covers illegal instructions, ECALL, EBREAK, FENCE, control-flow and
// data alignment, instruction/data access faults, precise flushing, and sticky halt.

`timescale 1ns/1ps

module rv32_pipeline_trap_tb;

  logic clk;
  logic rst;

  logic imem_req_valid;
  logic imem_req_ready;
  logic [31:0] imem_req_addr;
  logic imem_resp_valid;
  logic [31:0] imem_resp_data;
  logic [31:0] imem_data_q;
  logic imem_resp_error;

  logic imem_error_enable;
  logic [31:0] imem_error_addr;

  logic dmem_req_valid;
  logic dmem_req_ready;
  logic [31:0] dmem_req_addr;
  logic dmem_req_write;
  logic [31:0] dmem_req_wdata;
  logic [3:0] dmem_req_wstrb;
  logic dmem_resp_valid;
  logic [31:0] dmem_resp_rdata;
  logic dmem_resp_error;

  logic dmem_pending_tb_q;
  logic dmem_error_enable;

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
  logic [31:0] test_program [0:15];
  int unsigned program_words;
  int unsigned errors;
  int unsigned trap_commit_count;
  int unsigned dmem_request_count;

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
      if (byte_addr[31:6] == 26'd0 && byte_addr[5:2] < program_words) begin
        instruction_at = test_program[byte_addr[5:2]];
      end else begin
        instruction_at = 32'h0000_0013;
      end
    end
  endfunction

  assign imem_req_ready = !imem_pending_q;
  assign imem_resp_valid = imem_pending_q;
  assign imem_resp_data = imem_data_q;
  assign imem_resp_error = imem_pending_q && imem_error_enable && (imem_addr_q == imem_error_addr);
  assign dmem_req_ready = !dmem_pending_tb_q;
  assign dmem_resp_valid = dmem_pending_tb_q;
  assign dmem_resp_rdata = 32'd0;
  assign dmem_resp_error = dmem_pending_tb_q && dmem_error_enable;

  always_ff @(posedge clk) begin
    if (rst) begin
      imem_pending_q <= 1'b0;
      imem_addr_q <= 32'd0;
      imem_data_q <= 32'd0;
      trap_commit_count <= 0;
      dmem_request_count <= 0;
      dmem_pending_tb_q <= 1'b0;
    end else begin
      if (imem_pending_q) begin
        imem_pending_q <= 1'b0;
      end else if (imem_req_valid && imem_req_ready) begin
        imem_pending_q <= 1'b1;
        imem_addr_q <= imem_req_addr;
        imem_data_q <= instruction_at(imem_req_addr);
      end
      if (commit_valid && commit_trap) begin
        trap_commit_count <= trap_commit_count + 1;
      end
      if (dmem_req_valid && dmem_req_ready) begin
        dmem_request_count <= dmem_request_count + 1;
      end
      if (dmem_pending_tb_q) begin
        dmem_pending_tb_q <= 1'b0;
      end else if (dmem_req_valid && dmem_req_ready) begin
        dmem_pending_tb_q <= 1'b1;
      end
    end
  end

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    #10000;
    $fatal(1, "rv32_pipeline_trap_tb: timeout");
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

  task automatic expect_normal_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic expected_rd_write,
    input logic [4:0] expected_rd_addr,
    input logic [31:0] expected_rd_wdata
  );
    int cycles;
    begin
      // Compare a non-memory, non-trap commit and consume its pulse.
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 100) begin
        @(posedge clk);
        #1;
        cycles++;
      end
      if (commit_valid !== 1'b1) begin
        $error("rv32_pipeline_trap_tb: expected normal commit but did not see commit_valid after %0d cycles", cycles);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("rv32_pipeline_trap_tb: expected PC=0x%08h but got 0x%08h", expected_pc, commit_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("rv32_pipeline_trap_tb: expected instruction=0x%08h but got 0x%08h", expected_instr, commit_instr);
          errors++;
        end
        if (commit_rd_write !== expected_rd_write) begin
          $error("rv32_pipeline_trap_tb: expected rd_write=%b but got %b", expected_rd_write, commit_rd_write);
          errors++;
        end
        if (commit_rd_addr !== expected_rd_addr) begin
          $error("rv32_pipeline_trap_tb: expected rd_addr=%d but got %d", expected_rd_addr, commit_rd_addr);
          errors++;
        end
        if (commit_rd_wdata !== expected_rd_wdata) begin
          $error("rv32_pipeline_trap_tb: expected rd_wdata=0x%08h but got 0x%08h", expected_rd_wdata, commit_rd_wdata);
          errors++;
        end
        if (commit_mem_valid !== 1'b0) begin
          $error("rv32_pipeline_trap_tb: expected commit_mem_valid=0 but got 1");
          errors++;
        end
        if (commit_trap !== 1'b0) begin
          $error("rv32_pipeline_trap_tb: expected commit_trap=0 but got 1");
          errors++;
        end
        if (commit_trap_cause !== rv32_core_pkg::CORE_TRAP_NONE) begin
          $error("rv32_pipeline_trap_tb: expected commit_trap_cause=CORE_TRAP_NONE but got %0d", commit_trap_cause);
          errors++;
        end
        if (halted !== 1'b0) begin
          $error("rv32_pipeline_trap_tb: expected halted=0 but got 1");
          errors++;
        end
      end
      @(posedge clk);
      #1;
    end
  endtask

  task automatic expect_trap_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input rv32_core_pkg::trap_cause_e expected_cause
  );
    int cycles;
    begin
      // A trap commit carries the expected identity and cause with no register
      // or memory side effects. The next task observes the following cycle.
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 100) begin
        @(posedge clk);
        #1;
        cycles++;
      end
      if (commit_valid !== 1'b1) begin
        $error("rv32_pipeline_trap_tb: expected trap commit but did not see commit_valid after %0d cycles", cycles);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("rv32_pipeline_trap_tb: expected trap PC=0x%08h but got 0x%08h", expected_pc, commit_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("rv32_pipeline_trap_tb: expected trap instruction=0x%08h but got 0x%08h", expected_instr, commit_instr);
          errors++;
        end
        if (commit_trap !== 1'b1) begin
          $error("rv32_pipeline_trap_tb: expected commit_trap=1 but got 0");
          errors++;
        end
        if (commit_trap_cause !== expected_cause) begin
          $error("rv32_pipeline_trap_tb: expected commit_trap_cause=%0d but got %0d", expected_cause, commit_trap_cause);
          errors++;
        end
        if (commit_rd_write !== 1'b0 ||
            commit_rd_addr !== 5'd0 ||
            commit_rd_wdata !== 32'd0) begin
          $error("rv32_pipeline_trap_tb: trap had register side effects");
          errors++;
        end
        if (commit_mem_valid !== 1'b0 ||
            commit_mem_write !== 1'b0 ||
            commit_mem_addr !== 32'd0 ||
            commit_mem_rmask !== 4'b0000 ||
            commit_mem_wmask !== 4'b0000 ||
            commit_mem_rdata !== 32'd0 ||
            commit_mem_wdata !== 32'd0) begin
          $error("rv32_pipeline_trap_tb: trap had memory side effects");
          errors++;
        end
        if (halted !== 1'b0) begin
          $error("rv32_pipeline_trap_tb: expected halted=0 after trap but got 1");
          errors++;
        end
      end
    end
  endtask

  task automatic check_halt_sticky;
    begin
      // Halt begins after the single trap-commit cycle and remains asserted
      // without further commits or memory requests.
      @(posedge clk);
      #1;
      if (halted !== 1'b1 ||
          commit_valid !== 1'b0 ||
          commit_trap !== 1'b0 ||
          imem_req_valid !== 1'b0 ||
          dmem_req_valid !== 1'b0) begin
        $error("rv32_pipeline_trap_tb: expected sticky halt conditions not met");
        errors++;
      end
      if (commit_trap_cause !== rv32_core_pkg::CORE_TRAP_NONE) begin
        $error("rv32_pipeline_trap_tb: expected commit_trap_cause=CORE_TRAP_NONE after trap but got %0d", commit_trap_cause);
        errors++;
      end
      repeat (3) begin
        @(posedge clk);
        #1;
        if (halted !== 1'b1 ||
            commit_valid !== 1'b0 ||
            commit_trap !== 1'b0 ||
            imem_req_valid !== 1'b0 ||
            dmem_req_valid !== 1'b0) begin
          $error("rv32_pipeline_trap_tb: expected sticky halt conditions not met");
          errors++;
        end
      end
      if (trap_commit_count !== 1) begin
        $error("rv32_pipeline_trap_tb: expected trap_commit_count=1 but got %0d", trap_commit_count);
        errors++;
      end
    end
  endtask

  initial begin
    integer i;
    rst = 1'b1;
    errors = 0;
    program_words = 0;
    for (i = 0; i < 16; i++) begin
      test_program[i] = 32'h0000_0013;
    end
    imem_error_enable = 1'b0;
    imem_error_addr = 32'd0;
    dmem_error_enable = 1'b0;

    // ID-stage system and illegal-instruction cases, resetting between them:
    // 1. ADDI x1,5; illegal; ADDI x2,7. Check the ADDI commit, illegal trap,
    //    sticky HALT, x1=5, and x2=0.
    // 2. ECALL (00000073) -> CORE_TRAP_ECALL.
    // 3. EBREAK (00100073) -> CORE_TRAP_BREAKPOINT.
    // 4. FENCE (0000000f); ADDI x3,9. FENCE must commit normally with no
    //    register write, the following ADDI must commit, and halted must stay 0.
    program_words = 3;
    test_program[0] = 32'h0050_0093; // ADDI x1, x0, 5
    test_program[1] = 32'hffff_ffff; // illegal instruction
    test_program[2] = 32'h0070_0113; // ADDI x2, x0, 7
    reset_core();
    expect_normal_commit(32'h0000_0000, 32'h0050_0093, 1'b1, 5'd1, 32'd5);
    expect_trap_commit(32'h0000_0004, 32'hffff_ffff, rv32_core_pkg::CORE_TRAP_ILLEGAL_INSTRUCTION);
    check_halt_sticky();
    if (dut.regfile.registers[1] !== 32'h0000_0005) begin
      $error("rv32_pipeline_trap_tb: expected x1=5 after illegal instruction but got 0x%08h", dut.regfile.registers[1]);
      errors++;
    end
    if (dut.regfile.registers[2] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: expected x2=0 after illegal instruction but got 0x%08h", dut.regfile.registers[2]);
      errors++;
    end

    program_words = 1;
    test_program[0] = 32'h0000_0073; // ECALL
    reset_core();
    if (halted !== 1'b0) begin
      $error("rv32_pipeline_trap_tb: expected halted=0 after reset before ECALL but got 1");
      errors++;
    end
    expect_trap_commit(32'h0000_0000, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);
    check_halt_sticky();

    program_words = 1;
    test_program[0] = 32'h0010_0073; // EBREAK
    reset_core();
    if (halted !== 1'b0) begin
      $error("rv32_pipeline_trap_tb: expected halted=0 after reset before EBREAK but got 1");
      errors++;
    end
    expect_trap_commit(32'h0000_0000, 32'h0010_0073, rv32_core_pkg::CORE_TRAP_BREAKPOINT);
    check_halt_sticky();

    program_words = 2;
    test_program[0] = 32'h0000_000f; // FENCE
    test_program[1] = 32'h0090_0193; // ADDI x3, x0, 9
    reset_core();
    if (halted !== 1'b0) begin
      $error("rv32_pipeline_trap_tb: expected halted=0 after reset before FENCE but got 1");
      errors++;
    end
    expect_normal_commit(32'h0000_0000, 32'h0000_000f, 1'b0, 5'd0, 32'd0);
    expect_normal_commit(32'h0000_0004, 32'h0090_0193, 1'b1, 5'd3, 32'd9);
    if (halted !== 1'b0) begin
      $error("rv32_pipeline_trap_tb: expected halted=0 after FENCE and ADDI but got 1");
      errors++;
    end
    if (trap_commit_count !== 0) begin
      $error("rv32_pipeline_trap_tb: expected trap_commit_count=0 after FENCE and ADDI but got %0d", trap_commit_count);
      errors++;
    end
    if (dut.regfile.registers[3] !== 32'h0000_0009) begin
      $error("rv32_pipeline_trap_tb: expected x3=9 after FENCE and ADDI but got 0x%08h", dut.regfile.registers[3]);
      errors++;
    end

    program_words = 2;
    test_program[0] = 32'h0000_0163; // BEQ x0, x0, +2
    test_program[1] = 32'h00b0_0213; // ADDI x4, x0, 11
    reset_core();
    if (halted !== 1'b0) begin
      $error("rv32_pipeline_trap_tb: expected halted=0 after reset before BEQ but got 1");
      errors++;
    end
    expect_trap_commit(32'h0000_0000, 32'h0000_0163, rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED);
    check_halt_sticky();
    if (dut.regfile.registers[4] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: expected x4=0 after misaligned branch but got 0x%08h", dut.regfile.registers[4]);
      errors++;
    end

    program_words = 2;
    test_program[0] = 32'h0000_1163; // BNE x0, x0, +2
    test_program[1] = 32'h00b0_0213; // ADDI x4, x0, 11
    reset_core();
    if (halted !== 1'b0) begin
      $error("rv32_pipeline_trap_tb: expected halted=0 after reset before misaligned BNE but got 1");
      errors++;
    end
    expect_normal_commit(32'h0000_0000, 32'h0000_1163, 1'b0, 5'd0, 32'd0);
    expect_normal_commit(32'h0000_0004, 32'h00b0_0213, 1'b1, 5'd4, 32'd11);
    if (trap_commit_count !== 0) begin
      $error("rv32_pipeline_trap_tb: expected trap_commit_count=0 after misaligned BNE and ADDI but got %0d", trap_commit_count);
      errors++;
    end
    if (halted !== 1'b0) begin
      $error("rv32_pipeline_trap_tb: expected halted=0 after misaligned BNE and ADDI but got 1");
      errors++;
    end
    if (dut.regfile.registers[4] !== 32'h0000_000b) begin
      $error("rv32_pipeline_trap_tb: expected x4=11 after misaligned BNE and ADDI but got 0x%08h", dut.regfile.registers[4]);
      errors++;
    end

    program_words = 2;
    test_program[0] = 32'h0020_00ef; // JAL x1, +2
    test_program[1] = 32'h00d0_0293; // ADDI x5, x0, 13
    reset_core();
    if (halted !== 1'b0) begin
      $error("rv32_pipeline_trap_tb: expected halted=0 after reset before misaligned JAL but got 1");
      errors++;
    end
    expect_trap_commit(32'h0000_0000, 32'h0020_00ef, rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED);
    check_halt_sticky();
    if (dut.regfile.registers[1] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: misaligned JAL wrote its link register");
      errors++;
    end
    if (dut.regfile.registers[5] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: younger instruction executed after misaligned JAL");
      errors++;
    end

    program_words = 3;
    test_program[0] = 32'h0020_0093; // ADDI x1, x0, 2
    test_program[1] = 32'h0000_8367; // JALR x6, 0(x1)
    test_program[2] = 32'h00f0_0393; // ADDI x7, x0, 15
    reset_core();
    expect_normal_commit(32'h0000_0000, 32'h0020_0093, 1'b1, 5'd1, 32'd2);
    expect_trap_commit(32'h0000_0004, 32'h0000_8367, rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED);
    check_halt_sticky();
    if (dut.regfile.registers[6] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: misaligned JALR wrote its link register");
      errors++;
    end
    if (dut.regfile.registers[7] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: younger instruction executed after misaligned JALR");
      errors++;
    end

    program_words = 3;
    test_program[0] = 32'h0010_0093; // ADDI x1, x0, 1
    test_program[1] = 32'h0000_a103; // LW x2, 0(x1)
    test_program[2] = 32'h0110_0193; // ADDI x3, x0, 17
    reset_core();
    expect_normal_commit(32'h0000_0000, 32'h0010_0093, 1'b1, 5'd1, 32'd1);
    expect_trap_commit(32'h0000_0004, 32'h0000_a103, rv32_core_pkg::CORE_TRAP_LOAD_ADDRESS_MISALIGNED);
    check_halt_sticky();
    if (dut.regfile.registers[2] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: misaligned load wrote its destination register");
      errors++;
    end
    if (dut.regfile.registers[3] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: younger instruction executed after misaligned LW");
      errors++;
    end
    if (dmem_request_count !== 0) begin
      $error("rv32_pipeline_trap_tb: misaligned LW issued %0d dmem requests", dmem_request_count);
      errors++;
    end

    program_words = 4;
    test_program[0] = 32'h0020_0093; // ADDI x1, x0, 2
    test_program[1] = 32'h0550_0113; // ADDI x2, x0, 85
    test_program[2] = 32'h0020_a023; // SW x2, 0(x1)
    test_program[3] = 32'h0130_0193; // ADDI x3, x0, 19
    reset_core();
    expect_normal_commit(32'h0000_0000, 32'h0020_0093, 1'b1, 5'd1, 32'd2);
    expect_normal_commit(32'h0000_0004, 32'h0550_0113, 1'b1, 5'd2, 32'd85);
    expect_trap_commit(32'h0000_0008, 32'h0020_a023, rv32_core_pkg::CORE_TRAP_STORE_ADDRESS_MISALIGNED);
    check_halt_sticky();
    if (dut.regfile.registers[3] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: younger instruction executed after misaligned SW");
      errors++;
    end
    if (dmem_request_count !== 0) begin
      $error("rv32_pipeline_trap_tb: misaligned SW issued %0d dmem requests", dmem_request_count);
      errors++;
    end

    program_words = 2;
    test_program[0] = 32'h0000_40b7; // LUI x1, 0x4
    test_program[1] = 32'h0000_8167; // JALR x2, 0(x1)
    imem_error_enable = 1'b1;
    imem_error_addr = 32'h0000_4000;
    reset_core();
    expect_normal_commit(32'h0000_0000, 32'h0000_40b7, 1'b1, 5'd1, 32'h0000_4000);
    expect_normal_commit(32'h0000_0004, 32'h0000_8167, 1'b1, 5'd2, 32'h0000_0008);
    expect_trap_commit(32'h0000_4000, 32'h0000_0000, rv32_core_pkg::CORE_TRAP_INSTRUCTION_ACCESS_FAULT);
    check_halt_sticky();
    if (dut.regfile.registers[2] !== 32'h0000_0008) begin
      $error("rv32_pipeline_trap_tb: instruction access fault corrupted JALR link register");
      errors++;
    end
    imem_error_enable = 1'b0;

    program_words = 3;
    test_program[0] = 32'h0000_40b7; // LUI x1, 0x4
    test_program[1] = 32'h0000_a103; // LW x2, 0(x1)
    test_program[2] = 32'h0110_0193; // ADDI x3, x0, 17
    dmem_error_enable = 1'b1;
    reset_core();
    expect_normal_commit(32'h0000_0000, 32'h0000_40b7, 1'b1, 5'd1, 32'h0000_4000);
    expect_trap_commit(32'h0000_0004, 32'h0000_a103, rv32_core_pkg::CORE_TRAP_LOAD_ACCESS_FAULT);
    check_halt_sticky();
    if (dut.regfile.registers[2] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: load access fault wrote its destination register");
      errors++;
    end
    if (dut.regfile.registers[3] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: younger instruction executed after load access fault");
      errors++;
    end
    if (dmem_request_count !== 1) begin
      $error("rv32_pipeline_trap_tb: load access fault expected one dmem request but saw %0d", dmem_request_count);
      errors++;
    end
    dmem_error_enable = 1'b0;

    program_words = 4;
    test_program[0] = 32'h0000_40b7; // LUI x1, 0x4
    test_program[1] = 32'h0550_0113; // ADDI x2, x0, 85
    test_program[2] = 32'h0020_a023; // SW x2, 0(x1)
    test_program[3] = 32'h0130_0193; // ADDI x3, x0, 19
    dmem_error_enable = 1'b1;
    reset_core();
    expect_normal_commit(32'h0000_0000, 32'h0000_40b7, 1'b1, 5'd1, 32'h0000_4000);
    expect_normal_commit(32'h0000_0004, 32'h0550_0113, 1'b1, 5'd2, 32'h0000_0055);
    expect_trap_commit(32'h0000_0008, 32'h0020_a023, rv32_core_pkg::CORE_TRAP_STORE_ACCESS_FAULT);
    check_halt_sticky();
    if (dut.regfile.registers[2] !== 32'h0000_0055) begin
      $error("rv32_pipeline_trap_tb: store access fault corrupted its source register");
      errors++;
    end
    if (dut.regfile.registers[3] !== 32'h0000_0000) begin
      $error("rv32_pipeline_trap_tb: younger instruction executed after store access fault");
      errors++;
    end
    if (dmem_request_count !== 1) begin
      $error("rv32_pipeline_trap_tb: store access fault expected one dmem request but saw %0d", dmem_request_count);
      errors++;
    end
    dmem_error_enable = 1'b0;

    if (errors == 0) begin
      $display("rv32_pipeline_trap_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_pipeline_trap_tb: FAIL with %0d errors", errors);
    end
  end
endmodule
