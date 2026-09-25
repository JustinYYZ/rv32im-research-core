// SPDX-License-Identifier: Apache-2.0
//
// Core-level checks for ordered OoO memory execution. Every test observes
// architectural Commit; the memory handshake monitor checks the Head-only rule.

`timescale 1ns/1ps

module rv32_ooo_memory_tb;
  logic                       clk;
  logic                       rst;
  logic                       imem_req_valid;
  logic                       imem_req_ready;
  logic [31:0]                imem_req_addr;
  logic                       imem_resp_valid;
  logic [31:0]                imem_resp_data;
  logic                       imem_resp_error;
  logic                       dmem_req_valid;
  logic                       dmem_req_ready;
  logic [31:0]                dmem_req_addr;
  logic                       dmem_req_write;
  logic [31:0]                dmem_req_wdata;
  logic [3:0]                 dmem_req_wstrb;
  logic                       dmem_resp_valid;
  logic [31:0]                dmem_resp_rdata;
  logic                       dmem_resp_error;
  logic                       memory_dmem_req_ready;
  logic                       memory_dmem_resp_valid;
  logic [31:0]                memory_dmem_resp_rdata;
  logic                       memory_dmem_resp_error;
  logic                       allow_request;
  logic                       allow_response;
  logic                       response_pending_q;
  logic [31:0]                response_data_q;
  logic                       response_error_q;
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
  int unsigned                request_count;
  int unsigned                errors;

  typedef struct packed {
    logic [31:0]                pc;
    logic [31:0]                instr;
    logic                       rd_write;
    logic [4:0]                 rd;
    logic [31:0]                result;
    logic                       mem_valid;
    logic                       mem_write;
    logic [31:0]                mem_addr;
    logic [3:0]                 mem_rmask;
    logic [3:0]                 mem_wmask;
    logic [31:0]                mem_rdata;
    logic [31:0]                mem_wdata;
    logic                       trap;
    rv32_core_pkg::trap_cause_e trap_cause;
  } expected_commit_t;

  rv32_ooo_core dut (
    .clk_i(clk), .rst_i(rst),
    .imem_req_valid_o(imem_req_valid), .imem_req_ready_i(imem_req_ready), .imem_req_addr_o(imem_req_addr),
    .imem_resp_valid_i(imem_resp_valid), .imem_resp_data_i(imem_resp_data), .imem_resp_error_i(imem_resp_error),
    .dmem_req_valid_o(dmem_req_valid), .dmem_req_ready_i(dmem_req_ready), .dmem_req_addr_o(dmem_req_addr),
    .dmem_req_write_o(dmem_req_write), .dmem_req_wdata_o(dmem_req_wdata), .dmem_req_wstrb_o(dmem_req_wstrb),
    .dmem_resp_valid_i(dmem_resp_valid), .dmem_resp_rdata_i(dmem_resp_rdata), .dmem_resp_error_i(dmem_resp_error),
    .commit_valid_o(commit_valid), .commit_pc_o(commit_pc), .commit_instr_o(commit_instr),
    .commit_rd_write_o(commit_rd_write), .commit_rd_addr_o(commit_rd_addr), .commit_rd_wdata_o(commit_rd_wdata),
    .commit_mem_valid_o(commit_mem_valid), .commit_mem_write_o(commit_mem_write), .commit_mem_addr_o(commit_mem_addr),
    .commit_mem_rmask_o(commit_mem_rmask), .commit_mem_wmask_o(commit_mem_wmask),
    .commit_mem_rdata_o(commit_mem_rdata), .commit_mem_wdata_o(commit_mem_wdata),
    .commit_trap_o(commit_trap), .commit_trap_cause_o(commit_trap_cause), .halted_o(halted)
  );

  rv32_simple_memory memory (
    .clk_i(clk), .rst_i(rst),
    .imem_req_valid_i(imem_req_valid), .imem_req_ready_o(imem_req_ready), .imem_req_addr_i(imem_req_addr),
    .imem_resp_valid_o(imem_resp_valid), .imem_resp_data_o(imem_resp_data), .imem_resp_error_o(imem_resp_error),
    .dmem_req_valid_i(dmem_req_valid && allow_request), .dmem_req_ready_o(memory_dmem_req_ready),
    .dmem_req_addr_i(dmem_req_addr), .dmem_req_write_i(dmem_req_write),
    .dmem_req_wdata_i(dmem_req_wdata), .dmem_req_wstrb_i(dmem_req_wstrb),
    .dmem_resp_valid_o(memory_dmem_resp_valid), .dmem_resp_rdata_o(memory_dmem_resp_rdata),
    .dmem_resp_error_o(memory_dmem_resp_error)
  );

  assign dmem_req_ready = memory_dmem_req_ready && allow_request;
  assign dmem_resp_valid = response_pending_q && allow_response;
  assign dmem_resp_rdata = response_data_q;
  assign dmem_resp_error = response_error_q;

  always #5 clk = ~clk;


  // The memory model pulses its response. Save it until the LSU can see it.
  always_ff @(posedge clk) begin
    if (rst) begin
      response_pending_q <= 1'b0;
      response_data_q <= 32'b0;
      response_error_q <= 1'b0;
    end else if (memory_dmem_resp_valid) begin
      response_pending_q <= 1'b1;
      response_data_q <= memory_dmem_resp_rdata;
      response_error_q <= memory_dmem_resp_error;
    end else if (dmem_resp_valid) begin
      response_pending_q <= 1'b0;
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      request_count <= 0;
    end else if (dmem_req_valid && dmem_req_ready) begin
      request_count <= request_count + 1;
      if (dut.backend.rob_head_tag !== dut.backend.lsu.uop_q.rob_tag) begin
        $error("data request was not issued by the ROB Head");
        errors++;
      end
    end
  end

  function automatic logic [31:0] addi(input logic [4:0] rd, rs1, input logic [11:0] imm);
    return {imm, rs1, 3'b000, rd, 7'b0010011};
  endfunction

  function automatic logic [31:0] load(input logic [2:0] size, input logic [4:0] rd, rs1, input logic [11:0] imm);
    return {imm, rs1, size, rd, 7'b0000011};
  endfunction

  function automatic logic [31:0] store(input logic [2:0] size, input logic [4:0] rs2, rs1, input logic [11:0] imm);
    return {imm[11:5], rs2, rs1, size, imm[4:0], 7'b0100011};
  endfunction

  function automatic logic [31:0] beq(input logic [4:0] rs1, rs2, input logic [12:0] offset);
    return {offset[12], offset[10:5], rs2, rs1, 3'b000, offset[4:1], offset[11], 7'b1100011};
  endfunction

  function automatic logic [31:0] div_insn(input logic [4:0] rd, rs1, rs2);
    return {7'b0000001, rs2, rs1, 3'b100, rd, 7'b0110011};
  endfunction

  task automatic prepare_case;
    begin
      @(negedge clk);
      rst = 1'b1;
      allow_request = 1'b1;
      allow_response = 1'b1;
      memory.clear_memory();
    end
  endtask

  task automatic start_case;
    begin
      repeat (2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
    end
  endtask

  task automatic expect_commit(input string name, input expected_commit_t expected);
    int unsigned cycles;
    begin
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 300) begin
        @(negedge clk);
        cycles++;
      end
      if (commit_valid !== 1'b1) $fatal(1, "%s: timeout waiting for Commit", name);
      if (commit_pc !== expected.pc || commit_instr !== expected.instr || commit_rd_write !== expected.rd_write || commit_trap !== expected.trap || commit_trap_cause !== expected.trap_cause) begin
        $error("%s: Commit identity, write enable, or trap mismatch", name);
        errors++;
      end
      if (expected.rd_write && (commit_rd_addr !== expected.rd || commit_rd_wdata !== expected.result)) begin
        $error("%s: register result mismatch", name);
        errors++;
      end
      if (commit_mem_valid !== expected.mem_valid || commit_mem_write !== expected.mem_write || commit_mem_addr !== expected.mem_addr || commit_mem_rmask !== expected.mem_rmask || commit_mem_wmask !== expected.mem_wmask || commit_mem_rdata !== expected.mem_rdata || commit_mem_wdata !== expected.mem_wdata) begin
        $error("%s: memory Commit record mismatch", name);
        errors++;
      end
      @(posedge clk);
      #1;
    end
  endtask

  task automatic expect_reg(input string name, input logic [31:0] pc, instr, input logic [4:0] rd, input logic [31:0] value);
    expected_commit_t expected;
    begin
      expected = '0;
      expected.pc = pc;
      expected.instr = instr;
      expected.rd_write = 1'b1;
      expected.rd = rd;
      expected.result = value;
      expected.trap_cause = rv32_core_pkg::CORE_TRAP_NONE;
      expect_commit(name, expected);
    end
  endtask

  task automatic expect_control(input string name, input logic [31:0] pc, instr);
    expected_commit_t expected;
    begin
      expected = '0;
      expected.pc = pc;
      expected.instr = instr;
      expected.trap_cause = rv32_core_pkg::CORE_TRAP_NONE;
      expect_commit(name, expected);
    end
  endtask

  task automatic expect_store(input string name, input logic [31:0] pc, instr, addr, input logic [3:0] mask, input logic [31:0] data);
    expected_commit_t expected;
    begin
      expected = '0;
      expected.pc = pc;
      expected.instr = instr;
      expected.mem_valid = 1'b1;
      expected.mem_write = 1'b1;
      expected.mem_addr = addr;
      expected.mem_wmask = mask;
      expected.mem_wdata = data;
      expected.trap_cause = rv32_core_pkg::CORE_TRAP_NONE;
      expect_commit(name, expected);
    end
  endtask

  task automatic expect_load(input string name, input logic [31:0] pc, instr, input logic [4:0] rd, input logic [31:0] value, addr, input logic [3:0] mask, input logic [31:0] raw_word);
    expected_commit_t expected;
    begin
      expected = '0;
      expected.pc = pc;
      expected.instr = instr;
      expected.rd_write = 1'b1;
      expected.rd = rd;
      expected.result = value;
      expected.mem_valid = 1'b1;
      expected.mem_addr = addr;
      expected.mem_rmask = mask;
      expected.mem_rdata = raw_word;
      expected.trap_cause = rv32_core_pkg::CORE_TRAP_NONE;
      expect_commit(name, expected);
    end
  endtask

  task automatic expect_trap(input string name, input logic [31:0] pc, instr, input rv32_core_pkg::trap_cause_e cause);
    expected_commit_t expected;
    begin
      expected = '0;
      expected.pc = pc;
      expected.instr = instr;
      expected.trap = 1'b1;
      expected.trap_cause = cause;
      expect_commit(name, expected);
      if (halted !== 1'b1) begin
        $error("%s: core did not halt after the trap", name);
        errors++;
      end
      repeat (3) begin
        @(negedge clk);
        if (commit_valid !== 1'b0) begin
          $error("%s: younger instruction committed after the trap", name);
          errors++;
        end
      end
    end
  endtask

  task automatic test_word_memory;
    begin
      prepare_case();
      memory.write_word(32'h0000_0000, addi(5'd1, 5'd0, 12'h100)); // base address
      memory.write_word(32'h0000_0004, addi(5'd2, 5'd0, 12'd42));
      memory.write_word(32'h0000_0008, store(3'b010, 5'd2, 5'd1, 12'd0)); // SW
      memory.write_word(32'h0000_000c, load(3'b010, 5'd3, 5'd1, 12'd0));  // LW
      memory.write_word(32'h0000_0010, addi(5'd4, 5'd3, 12'd1));
      memory.write_word(32'h0000_0014, 32'h0000_0073); // ECALL
      start_case();

      expect_reg("word base", 32'h0000_0000, addi(5'd1, 5'd0, 12'h100), 5'd1, 32'h0000_0100);
      expect_reg("word value", 32'h0000_0004, addi(5'd2, 5'd0, 12'd42), 5'd2, 32'd42);
      expect_store("SW", 32'h0000_0008, store(3'b010, 5'd2, 5'd1, 12'd0), 32'h0000_0100, 4'b1111, 32'd42);
      expect_load("LW", 32'h0000_000c, load(3'b010, 5'd3, 5'd1, 12'd0), 5'd3, 32'd42, 32'h0000_0100, 4'b1111, 32'd42);
      expect_reg("LW consumer", 32'h0000_0010, addi(5'd4, 5'd3, 12'd1), 5'd4, 32'd43);
      expect_trap("word ECALL", 32'h0000_0014, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);
      if (memory.read_word(32'h0000_0100) !== 32'd42 || request_count !== 2) begin
        $error("word memory: final data or request count mismatch");
        errors++;
      end
    end
  endtask

  task automatic test_subword_memory;
    begin
      prepare_case();
      memory.write_word(32'h0000_0100, 32'h1122_3344);
      memory.write_word(32'h0000_0000, addi(5'd1, 5'd0, 12'h100));
      memory.write_word(32'h0000_0004, addi(5'd2, 5'd0, 12'hf80)); // -128
      memory.write_word(32'h0000_0008, store(3'b000, 5'd2, 5'd1, 12'd1)); // SB
      memory.write_word(32'h0000_000c, load(3'b000, 5'd3, 5'd1, 12'd1));  // LB
      memory.write_word(32'h0000_0010, load(3'b100, 5'd4, 5'd1, 12'd1));  // LBU
      memory.write_word(32'h0000_0014, addi(5'd5, 5'd0, 12'hffe)); // -2
      memory.write_word(32'h0000_0018, store(3'b001, 5'd5, 5'd1, 12'd2)); // SH
      memory.write_word(32'h0000_001c, load(3'b001, 5'd6, 5'd1, 12'd2));  // LH
      memory.write_word(32'h0000_0020, load(3'b101, 5'd7, 5'd1, 12'd2));  // LHU
      memory.write_word(32'h0000_0024, 32'h0000_0073);
      start_case();

      expect_reg("subword base", 32'h0000_0000, addi(5'd1, 5'd0, 12'h100), 5'd1, 32'h0000_0100);
      expect_reg("subword byte", 32'h0000_0004, addi(5'd2, 5'd0, 12'hf80), 5'd2, 32'hffff_ff80);
      expect_store("SB", 32'h0000_0008, store(3'b000, 5'd2, 5'd1, 12'd1), 32'h0000_0100, 4'b0010, 32'h0000_8000);
      expect_load("LB", 32'h0000_000c, load(3'b000, 5'd3, 5'd1, 12'd1), 5'd3, 32'hffff_ff80, 32'h0000_0100, 4'b0010, 32'h1122_8044);
      expect_load("LBU", 32'h0000_0010, load(3'b100, 5'd4, 5'd1, 12'd1), 5'd4, 32'h0000_0080, 32'h0000_0100, 4'b0010, 32'h1122_8044);
      expect_reg("subword half", 32'h0000_0014, addi(5'd5, 5'd0, 12'hffe), 5'd5, 32'hffff_fffe);
      expect_store("SH", 32'h0000_0018, store(3'b001, 5'd5, 5'd1, 12'd2), 32'h0000_0100, 4'b1100, 32'hfffe_0000);
      expect_load("LH", 32'h0000_001c, load(3'b001, 5'd6, 5'd1, 12'd2), 5'd6, 32'hffff_fffe, 32'h0000_0100, 4'b1100, 32'hfffe_8044);
      expect_load("LHU", 32'h0000_0020, load(3'b101, 5'd7, 5'd1, 12'd2), 5'd7, 32'h0000_fffe, 32'h0000_0100, 4'b1100, 32'hfffe_8044);
      expect_trap("subword ECALL", 32'h0000_0024, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);
      if (memory.read_word(32'h0000_0100) !== 32'hfffe_8044 || request_count !== 6) begin
        $error("subword memory: final data or request count mismatch");
        errors++;
      end
    end
  endtask

  task automatic test_div_before_memory;
    begin
      prepare_case();
      memory.write_word(32'h0000_0000, addi(5'd1, 5'd0, 12'h100));
      memory.write_word(32'h0000_0004, addi(5'd2, 5'd0, 12'd10));
      memory.write_word(32'h0000_0008, addi(5'd3, 5'd0, 12'd2));
      memory.write_word(32'h0000_000c, div_insn(5'd4, 5'd2, 5'd3));
      memory.write_word(32'h0000_0010, store(3'b010, 5'd4, 5'd1, 12'd0));
      memory.write_word(32'h0000_0014, load(3'b010, 5'd5, 5'd1, 12'd0));
      memory.write_word(32'h0000_0018, 32'h0000_0073);
      start_case();

      expect_reg("DIV base", 32'h0000_0000, addi(5'd1, 5'd0, 12'h100), 5'd1, 32'h0000_0100);
      expect_reg("DIV lhs", 32'h0000_0004, addi(5'd2, 5'd0, 12'd10), 5'd2, 32'd10);
      expect_reg("DIV rhs", 32'h0000_0008, addi(5'd3, 5'd0, 12'd2), 5'd3, 32'd2);
      expect_reg("DIV result", 32'h0000_000c, div_insn(5'd4, 5'd2, 5'd3), 5'd4, 32'd5);
      expect_store("DIV then SW", 32'h0000_0010, store(3'b010, 5'd4, 5'd1, 12'd0), 32'h0000_0100, 4'b1111, 32'd5);
      expect_load("DIV then LW", 32'h0000_0014, load(3'b010, 5'd5, 5'd1, 12'd0), 5'd5, 32'd5, 32'h0000_0100, 4'b1111, 32'd5);
      expect_trap("DIV ECALL", 32'h0000_0018, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);
      if (request_count !== 2) begin
        $error("DIV memory: request count mismatch");
        errors++;
      end
    end
  endtask

  task automatic test_wrong_path_store;
    begin
      prepare_case();
      memory.write_word(32'h0000_0100, 32'h1234_5678);
      memory.write_word(32'h0000_0000, addi(5'd1, 5'd0, 12'h100));
      memory.write_word(32'h0000_0004, addi(5'd2, 5'd0, 12'd99));
      memory.write_word(32'h0000_0008, beq(5'd0, 5'd0, 13'd8));
      memory.write_word(32'h0000_000c, store(3'b010, 5'd2, 5'd1, 12'd0));
      memory.write_word(32'h0000_0010, addi(5'd3, 5'd0, 12'd1));
      memory.write_word(32'h0000_0014, 32'h0000_0073);
      start_case();

      expect_reg("branch base", 32'h0000_0000, addi(5'd1, 5'd0, 12'h100), 5'd1, 32'h0000_0100);
      expect_reg("branch value", 32'h0000_0004, addi(5'd2, 5'd0, 12'd99), 5'd2, 32'd99);
      expect_control("taken BEQ", 32'h0000_0008, beq(5'd0, 5'd0, 13'd8));
      expect_reg("branch target", 32'h0000_0010, addi(5'd3, 5'd0, 12'd1), 5'd3, 32'd1);
      expect_trap("branch ECALL", 32'h0000_0014, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);
      if (request_count !== 0 || memory.read_word(32'h0000_0100) !== 32'h1234_5678) begin
        $error("wrong-path Store reached data memory");
        errors++;
      end
    end
  endtask

  task automatic test_fault(input string name, input logic [31:0] instruction, input rv32_core_pkg::trap_cause_e cause, input logic access_error);
    begin
      prepare_case();
      memory.write_word(32'h0000_0100, 32'h1234_5678);
      memory.write_word(32'h0000_0000, addi(5'd1, 5'd0, 12'h100));
      memory.write_word(32'h0000_0004, addi(5'd2, 5'd0, 12'd85));
      memory.write_word(32'h0000_0008, instruction);
      memory.write_word(32'h0000_000c, 32'h0000_0073);
      start_case();
      if (access_error) memory.set_dmem_error(32'h0000_0100, instruction[6:0] == 7'b0100011);

      expect_reg("fault base", 32'h0000_0000, addi(5'd1, 5'd0, 12'h100), 5'd1, 32'h0000_0100);
      expect_reg("fault value", 32'h0000_0004, addi(5'd2, 5'd0, 12'd85), 5'd2, 32'd85);
      expect_trap(name, 32'h0000_0008, instruction, cause);
      if (request_count !== (access_error ? 1 : 0) || memory.read_word(32'h0000_0100) !== 32'h1234_5678) begin
        $error("%s: fault request count or memory side effect mismatch", name);
        errors++;
      end
    end
  endtask

  task automatic test_backpressure;
    int unsigned cycles;
    begin
      prepare_case();
      memory.write_word(32'h0000_0100, 32'h1234_5678);
      memory.write_word(32'h0000_0000, addi(5'd1, 5'd0, 12'h100));
      memory.write_word(32'h0000_0004, load(3'b010, 5'd2, 5'd1, 12'd0));
      memory.write_word(32'h0000_0008, 32'h0000_0073);
      allow_request = 1'b0;
      allow_response = 1'b0;
      start_case();
      expect_reg("stalled base", 32'h0000_0000, addi(5'd1, 5'd0, 12'h100), 5'd1, 32'h0000_0100);

      cycles = 0;
      while (dmem_req_valid !== 1'b1 && cycles < 100) begin
        @(negedge clk);
        cycles++;
      end
      if (dmem_req_valid !== 1'b1) $fatal(1, "stalled Load never requested memory");
      repeat (3) begin
        @(negedge clk);
        if (dmem_req_valid !== 1'b1 || dmem_req_addr !== 32'h0000_0100 || dmem_req_write !== 1'b0 || commit_valid !== 1'b0) begin
          $error("stalled Load request changed before acceptance");
          errors++;
        end
      end

      allow_request = 1'b1;
      repeat (5) @(negedge clk);
      if (request_count !== 1 || commit_valid !== 1'b0 || dmem_resp_valid !== 1'b0 || response_pending_q !== 1'b1) begin
        $error("stalled response was not held without Commit");
        errors++;
      end
      allow_response = 1'b1;
      expect_load("stalled LW", 32'h0000_0004, load(3'b010, 5'd2, 5'd1, 12'd0), 5'd2, 32'h1234_5678, 32'h0000_0100, 4'b1111, 32'h1234_5678);
      expect_trap("stalled ECALL", 32'h0000_0008, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);
    end
  endtask

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    allow_request = 1'b1;
    allow_response = 1'b1;
    errors = 0;
    test_word_memory();
    test_subword_memory();
    test_div_before_memory();
    test_wrong_path_store();
    test_fault("misaligned LW", load(3'b010, 5'd3, 5'd1, 12'd2), rv32_core_pkg::CORE_TRAP_LOAD_ADDRESS_MISALIGNED, 1'b0);
    test_fault("misaligned SH", store(3'b001, 5'd2, 5'd1, 12'd1), rv32_core_pkg::CORE_TRAP_STORE_ADDRESS_MISALIGNED, 1'b0);
    test_fault("Load access fault", load(3'b010, 5'd3, 5'd1, 12'd0), rv32_core_pkg::CORE_TRAP_LOAD_ACCESS_FAULT, 1'b1);
    test_fault("Store access fault", store(3'b010, 5'd2, 5'd1, 12'd0), rv32_core_pkg::CORE_TRAP_STORE_ACCESS_FAULT, 1'b1);
    test_backpressure();
    if (errors !== 0) $fatal(1, "rv32_ooo_memory_tb: %0d errors", errors);
    $display("rv32_ooo_memory_tb: ordered memory, traps, recovery, and backpressure passed");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "rv32_ooo_memory_tb: global timeout");
  end

endmodule
