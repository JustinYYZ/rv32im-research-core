// SPDX-License-Identifier: Apache-2.0
//
// Self-checking testbench for reference-core traps and halt behavior. Each
// case loads a short program, observes one trap commit, checks that the core
// enters HALT without architectural side effects, and resets before the next
// case. A sticky request monitor distinguishes pre-request misalignment from
// access faults reported by a memory response.

`timescale 1ns/1ps

module rv32_reference_core_trap_tb;

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
  logic saw_dmem_request;

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


  logic [31:0] test_program [0:15];
  int unsigned program_words;
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
    $fatal(1, "rv32_reference_core_trap_tb: timeout");
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      saw_dmem_request <= 1'b0;
    end else if (dmem_req_valid) begin
      saw_dmem_request <= 1'b1;
    end
  end

  task automatic reset_and_load;
    integer i;
    begin
      // Reset clears both the halted core and any pending memory-model response.
      // Programs are loaded while reset remains asserted.
      rst = 1'b1;
      memory_model.clear_memory();
      for (i = 0; i < program_words; i++) begin
        memory_model.write_word(i*4, test_program[i]);
      end
      repeat (2) @(posedge clk);
      #1;
      assert(!imem_req_valid && !dmem_req_valid && !commit_valid && !halted)
        else $fatal(1, "reset_and_load: request/commit/halt active during reset");
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
      // A finite wait makes a missing retirement fail at the expected PC rather
      // than relying on the testbench-wide timeout.
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 100) begin
        @(posedge clk);
        #1;
        cycles++;
      end
      if (commit_valid !== 1'b1) begin
        $fatal(1, "normal commit timeout: expected PC=%h, instr=%h", expected_pc, expected_instr);
      end
      if (commit_pc !== expected_pc) begin
        $error("normal commit PC mismatch: expected %h, got %h", expected_pc, commit_pc);
        errors++;
      end
      if (commit_instr !== expected_instr) begin
        $error("normal commit instruction mismatch: expected %h, got %h", expected_instr, commit_instr);
        errors++;
      end
      if (commit_rd_write !== expected_rd_write) begin
        $error("normal commit rd_write mismatch: expected %b, got %b", expected_rd_write, commit_rd_write);
        errors++;
      end
      if (commit_rd_addr !== expected_rd_addr) begin
        $error("normal commit rd_addr mismatch: expected %d, got %d", expected_rd_addr, commit_rd_addr);
        errors++;
      end
      if (commit_rd_wdata !== expected_rd_wdata) begin
        $error("normal commit rd_wdata mismatch: expected %h, got %h", expected_rd_wdata, commit_rd_wdata);
        errors++;
      end
      if (commit_trap !== 1'b0) begin
        $error("normal commit trap mismatch: expected 0, got %b", commit_trap);
        errors++;
      end
      if (halted !== 1'b0) begin
        $error("normal commit halted mismatch: expected 0, got %b", halted);
        errors++;
      end
      if (commit_mem_valid !== 1'b0) begin
        $error("normal commit mem_valid mismatch: expected 0, got %b", commit_mem_valid);
        errors++;
      end
      @(posedge clk);
      #1;
      if (commit_valid !== 1'b0) begin
        $error("normal commit valid pulse not one cycle");
        errors++;
      end
    end
  endtask

  task automatic expect_trap(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input rv32_core_pkg::trap_cause_e expected_cause
  );
    int cycles;
    begin
      // Trap retirement carries no register or memory side effect. The checker
      // also proves the trap pulse is followed by a persistent inactive HALT.
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 100) begin
        @(posedge clk);
        #1;
        cycles++;
      end
      if (commit_valid !== 1'b1) begin
        $fatal(1, "trap commit timeout: expected PC=%h, instr=%h", expected_pc, expected_instr);
      end
      if (commit_trap !== 1'b1) begin
        $error("trap commit trap mismatch: expected 1, got %b", commit_trap);
        errors++;
      end
      if (commit_pc !== expected_pc) begin
        $error("trap commit PC mismatch: expected %h, got %h", expected_pc, commit_pc);
        errors++;
      end
      if (commit_instr !== expected_instr) begin
        $error("trap commit instruction mismatch: expected %h, got %h", expected_instr, commit_instr);
        errors++;
      end
      if (commit_trap_cause !== expected_cause) begin
        $error("trap commit cause mismatch: expected %d, got %d", expected_cause, commit_trap_cause);
        errors++;
      end
      if (commit_rd_write !== 1'b0) begin
        $error("trap commit rd_write mismatch: expected 0, got %b", commit_rd_write);
        errors++;
      end
      if (commit_mem_valid !== 1'b0) begin
        $error("trap commit mem_valid mismatch: expected 0, got %b", commit_mem_valid);
        errors++;
      end
      @(posedge clk);
      #1;
      if (commit_valid !== 1'b0) begin
        $error("trap commit valid pulse not one cycle");
        errors++;
      end
      if (commit_trap !== 1'b0) begin
        $error("trap commit trap mismatch: expected 0, got %b", commit_trap);
        errors++;
      end
      if (halted !== 1'b1) begin
        $error("trap commit halted mismatch: expected 1, got %b", halted);
        errors++;
      end
      if (imem_req_valid !== 1'b0 || dmem_req_valid !== 1'b0) begin
        $error("trap commit request mismatch: expected 0, got imem=%b dmem=%b", imem_req_valid, dmem_req_valid);
        errors++;
      end
      repeat (3) begin
        @(posedge clk);
        #1;
        if (halted !== 1'b1 ||
            imem_req_valid !== 1'b0 ||
            dmem_req_valid !== 1'b0 ||
            commit_valid !== 1'b0 ||
            commit_trap !== 1'b0) begin
          $error("halted core changed state after trap commit");
          errors++;
        end
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    errors = 0;
    program_words = 0;

    // Illegal instruction after a legal dependent-state update.
    program_words = 2;
    test_program[0] = 32'h0050_0093; // ADDI x1, x0, 5
    test_program[1] = 32'hffff_ffff; // Illegal instruction (trap)
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h0050_0093, 1'b1, 5'd1, 32'd5);
    expect_trap(32'h0000_0004, 32'hffff_ffff, rv32_core_pkg::CORE_TRAP_ILLEGAL_INSTRUCTION);

    // Environment events trap; FENCE retires normally and continues execution.
    program_words = 1;
    test_program[0] = 32'h0000_0073; // ECALL
    reset_and_load();
    expect_trap(32'h0000_0000, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);

    program_words = 1;
    test_program[0] = 32'h0010_0073; // EBREAK
    reset_and_load();
    expect_trap(32'h0000_0000, 32'h0010_0073, rv32_core_pkg::CORE_TRAP_BREAKPOINT);

    program_words = 2;
    test_program[0] = 32'h0ff0_000f; // FENCE
    test_program[1] = 32'h0070_0093; // ADDI x1, x0, 7
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h0ff0_000f, 1'b0, 5'd0, 32'd0);
    expect_normal_commit(32'h0000_0004, 32'h0070_0093, 1'b1, 5'd1, 32'd7);

    // Misaligned taken branch/JAL/JALR targets trap. A not-taken branch ignores
    // its encoded target and advances to PC+4 normally.
    program_words = 1;
    test_program[0] = 32'h0020_00ef; // JAL x1, +2 (misaligned)
    reset_and_load();
    expect_trap(32'h0000_0000, 32'h0020_00ef, rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED);

    program_words = 1;
    test_program[0] = 32'h0000_0163; // BEQ x0, x0, +2 (taken, misaligned)
    reset_and_load();
    expect_trap(32'h0000_0000, 32'h0000_0163, rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED);

    program_words = 2;
    test_program[0] = 32'h0000_1163; // BNE x0, x0, +2 (not taken)
    test_program[1] = 32'h0090_0093; // ADDI x1, x0, 9
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h0000_1163, 1'b0, 5'd0, 32'd0);
    expect_normal_commit(32'h0000_0004, 32'h0090_0093, 1'b1, 5'd1, 32'd9);

    program_words = 2;
    test_program[0] = 32'h0030_0093; // ADDI x1, x0, 3
    test_program[1] = 32'h0000_8167; // JALR x2, x1, 0
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h0030_0093, 1'b1, 5'd1, 32'd3);
    expect_trap(32'h0000_0004, 32'h0000_8167, rv32_core_pkg::CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED);

    // An aligned out-of-range fetch reports the requested PC and no instruction.
    program_words = 2;
    test_program[0] = 32'h0000_40b7; // LUI x1, 0x4
    test_program[1] = 32'h0000_8167; // JALR x2, x1, 0
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h0000_40b7, 1'b1, 5'd1, 32'h0000_4000);
    expect_normal_commit(32'h0000_0004, 32'h0000_8167, 1'b1, 5'd2, 32'h0000_0008);
    expect_trap(32'h0000_4000, 32'h0000_0000, rv32_core_pkg::CORE_TRAP_INSTRUCTION_ACCESS_FAULT);

    // Misaligned LH/LW/SH/SW trap before any data-memory request or side effect.
    program_words = 2;
    test_program[0] = 32'h1000_0093; // ADDI x1, x0, 0x100
    test_program[1] = 32'h0020_a103; // LW x2, 2(x1)
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h1000_0093, 1'b1, 5'd1, 32'h0000_0100);
    expect_trap(32'h0000_0004, 32'h0020_a103, rv32_core_pkg::CORE_TRAP_LOAD_ADDRESS_MISALIGNED);
    if (saw_dmem_request !== 1'b0) begin
      $error("misaligned LW sent a data-memory request");
      errors++;
    end
    if (dut.regfile.registers[2] !== 32'd0) begin
      $error("misaligned LW modified register x2");
      errors++;
    end

    program_words = 2;
    test_program[0] = 32'h1000_0093; // ADDI x1, x0, 0x100
    test_program[1] = 32'h0010_9103; // LH x2, 1(x1)
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h1000_0093, 1'b1, 5'd1, 32'h0000_0100);
    expect_trap(32'h0000_0004, 32'h0010_9103, rv32_core_pkg::CORE_TRAP_LOAD_ADDRESS_MISALIGNED);
    if (saw_dmem_request !== 1'b0) begin
      $error("misaligned LH sent a data-memory request");
      errors++;
    end
    if (dut.regfile.registers[2] !== 32'd0) begin
      $error("misaligned LH modified register x2");
      errors++;
    end

    program_words = 3;
    test_program[0] = 32'h1000_0093; // ADDI x1, x0, 0x100
    test_program[1] = 32'h0550_0113; // ADDI x2, x0, 0x55
    test_program[2] = 32'h0020_a123; // SW x2, 2(x1)
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h1000_0093, 1'b1, 5'd1, 32'h0000_0100);
    expect_normal_commit(32'h0000_0004, 32'h0550_0113, 1'b1, 5'd2, 32'h0000_0055);
    expect_trap(32'h0000_0008, 32'h0020_a123, rv32_core_pkg::CORE_TRAP_STORE_ADDRESS_MISALIGNED);
    if (saw_dmem_request !== 1'b0) begin
      $error("misaligned SW sent a data-memory request");
      errors++;
    end
    if (memory_model.read_word(32'h0000_0100) !== 32'd0) begin
      $error("misaligned SW modified memory at 0x00000100");
      errors++;
    end

    program_words = 3;
    test_program[0] = 32'h1000_0093; // ADDI x1, x0, 0x100
    test_program[1] = 32'h0550_0113; // ADDI x2, x0, 0x55
    test_program[2] = 32'h0020_90a3; // SH x2, 1(x1)
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h1000_0093, 1'b1, 5'd1, 32'h0000_0100);
    expect_normal_commit(32'h0000_0004, 32'h0550_0113, 1'b1, 5'd2, 32'h0000_0055);
    expect_trap(32'h0000_0008, 32'h0020_90a3, rv32_core_pkg::CORE_TRAP_STORE_ADDRESS_MISALIGNED);
    if (saw_dmem_request !== 1'b0) begin
      $error("misaligned SH sent a data-memory request");
      errors++;
    end
    if (memory_model.read_word(32'h0000_0100) !== 32'd0) begin
      $error("misaligned SH modified memory at 0x00000100");
      errors++;
    end

    // Aligned out-of-range loads and stores issue a request and trap only after
    // the memory model returns an error response.
    program_words = 2;
    test_program[0] = 32'h0000_40b7; // LUI x1, 0x4, x1=0x4000
    test_program[1] = 32'h0000_a103; // LW x2, 0(x1)
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h0000_40b7, 1'b1, 5'd1, 32'h0000_4000);
    expect_trap(32'h0000_0004, 32'h0000_a103, rv32_core_pkg::CORE_TRAP_LOAD_ACCESS_FAULT);
    if (saw_dmem_request !== 1'b1) begin
      $error("out-of-range LW did not send a data-memory request");
      errors++;
    end
    if (dut.regfile.registers[2] !== 32'd0) begin
      $error("out-of-range LW modified register x2");
      errors++;
    end

    program_words = 3;
    test_program[0] = 32'h0000_40b7; // LUI x1, 0x4, x1=0x4000
    test_program[1] = 32'h0550_0113; // ADDI x2, x0, 0x55
    test_program[2] = 32'h0020_a023; // SW x2, 0(x1)
    reset_and_load();
    expect_normal_commit(32'h0000_0000, 32'h0000_40b7, 1'b1, 5'd1, 32'h0000_4000);
    expect_normal_commit(32'h0000_0004, 32'h0550_0113, 1'b1, 5'd2, 32'h0000_0055);
    expect_trap(32'h0000_0008, 32'h0020_a023, rv32_core_pkg::CORE_TRAP_STORE_ACCESS_FAULT);
    if (saw_dmem_request !== 1'b1) begin
      $error("out-of-range SW did not send a data-memory request");
      errors++;
    end
    if (dut.regfile.registers[2] !== 32'h0000_0055) begin
      $error("out-of-range SW modified register x2");
      errors++;
    end

    // Every case above calls reset_and_load so reset recovery from HALT remains
    // part of the permanent regression.
    if (errors != 0) begin
      $fatal(1, "rv32_reference_core_trap_tb: %0d errors detected", errors);
    end
    $display("rv32_reference_core_trap_tb: PASS");
    $finish;
  end

endmodule
