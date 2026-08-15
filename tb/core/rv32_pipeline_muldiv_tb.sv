// SPDX-License-Identifier: Apache-2.0
//
// Pipeline RV32M integration test.
//
// This test checks the connection between the
// decoder, forwarding paths, multicycle EX control, multiplier/divider, and
// architectural commit interface. Arithmetic corner cases remain covered by
// the standalone multiplier and divider unit tests.

`timescale 1ns/1ps

module rv32_pipeline_muldiv_tb;

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

  logic imem_pending_q;
  logic [31:0] imem_addr_q;
  int unsigned errors;
  int unsigned muldiv_request_count;
  int unsigned muldiv_complete_count;
  int unsigned muldiv_wait_cycles;

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
      // Directed program covering all eight RV32M operations and forwarding
      // into and out of multicycle execution.
      // PC   instruction           machine word   expected destination value
      // 00   addi x1, x0, 7        00700093       x1  = 00000007
      // 04   addi x2, x0, -3       ffd00113       x2  = fffffffd
      // 08   mul  x3, x1, x2       022081b3       x3  = ffffffeb
      // 0c   add  x4, x3, x1       00118233       x4  = fffffff2
      // 10   div  x5, x1, x2       0220c2b3       x5  = fffffffe
      // 14   rem  x6, x1, x2       0220e333       x6  = 00000001
      // 18   addi x7, x0, -7       ff900393       x7  = fffffff9
      // 1c   mulh x8, x7, x2       02239433       x8  = 00000000
      // 20   mulhsu x9, x7, x2     0223a4b3       x9  = fffffff9
      // 24   mulhu x10, x7, x2     0223b533       x10 = fffffff6
      // 28   divu x11, x7, x2      0223d5b3       x11 = 00000000
      // 2c   remu x12, x7, x2      0223f633       x12 = fffffff9
      case (byte_addr)
        32'h0000_0000: instruction_at = 32'h0070_0093; // addi x1, x0, 7
        32'h0000_0004: instruction_at = 32'hffd0_0113; // addi x2, x0, -3
        32'h0000_0008: instruction_at = 32'h0220_81b3; // mul  x3, x1, x2
        32'h0000_000c: instruction_at = 32'h0011_8233; // add  x4, x3, x1
        32'h0000_0010: instruction_at = 32'h0220_c2b3; // div  x5, x1, x2
        32'h0000_0014: instruction_at = 32'h0220_e333; // rem  x6, x1, x2
        32'h0000_0018: instruction_at = 32'hff90_0393; // addi x7, x0, -7
        32'h0000_001c: instruction_at = 32'h0223_9433; // mulh x8, x7, x2
        32'h0000_0020: instruction_at = 32'h0223_a4b3; // mulhsu x9, x7, x2
        32'h0000_0024: instruction_at = 32'h0223_b533; // mulhu x10, x7, x2
        32'h0000_0028: instruction_at = 32'h0223_d5b3; // divu x11, x7, x2
        32'h0000_002c: instruction_at = 32'h0223_f633; // remu x12, x7, x2
        default: instruction_at = 32'h0000_0013;
      endcase
    end
  endfunction

  assign imem_req_ready = !imem_pending_q;
  assign imem_resp_valid = imem_pending_q;
  assign imem_resp_data = instruction_at(imem_addr_q);
  assign imem_resp_error = 1'b0;
  assign dmem_req_ready = 1'b1;
  assign dmem_resp_valid = 1'b0;
  assign dmem_resp_rdata = 32'd0;
  assign dmem_resp_error = 1'b0;

  always_ff @(posedge clk) begin
    if (rst) begin
      imem_pending_q <= 1'b0;
      imem_addr_q <= 32'd0;
    end else if (imem_pending_q) begin
      imem_pending_q <= 1'b0;
    end else if (imem_req_valid && imem_req_ready) begin
      imem_pending_q <= 1'b1;
      imem_addr_q <= imem_req_addr;
    end
  end

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  initial begin
    #20000;
    $fatal(1, "rv32_pipeline_muldiv_tb: timeout");
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

  task automatic expect_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [4:0] expected_rd_addr,
    input logic [31:0] expected_rd_wdata
  );
    int cycles;
    begin
      // Compare one architectural commit with a finite multicycle timeout.
      cycles = 0;

      while (commit_valid !== 1'b1 && cycles < 200) begin
        @(posedge clk);
        #1;
        cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $error("rv32_pipeline_muldiv_tb: expected commit_valid=1 for PC=%h, instr=%h, rd_addr=%d, rd_wdata=%h but got commit_valid=0 after %0d cycles", expected_pc, expected_instr, expected_rd_addr, expected_rd_wdata, cycles);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("rv32_pipeline_muldiv_tb: expected commit_pc=%h but got commit_pc=%h", expected_pc, commit_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("rv32_pipeline_muldiv_tb: expected commit_instr=%h but got commit_instr=%h", expected_instr, commit_instr);
          errors++;
        end
        if (commit_rd_write !== (expected_rd_addr != 5'd0)) begin
          $error("rv32_pipeline_muldiv_tb: expected commit_rd_write=%b but got commit_rd_write=%b", (expected_rd_addr != 5'd0), commit_rd_write);
          errors++;
        end
        if (commit_rd_addr !== expected_rd_addr) begin
          $error("rv32_pipeline_muldiv_tb: expected commit_rd_addr=%d but got commit_rd_addr=%d", expected_rd_addr, commit_rd_addr);
          errors++;
        end
        if (commit_rd_wdata !== expected_rd_wdata) begin
          $error("rv32_pipeline_muldiv_tb: expected commit_rd_wdata=%h but got commit_rd_wdata=%h", expected_rd_wdata, commit_rd_wdata);
          errors++;
        end
        if (commit_mem_valid !== 1'b0) begin
          $error("rv32_pipeline_muldiv_tb: expected commit_mem_valid=0 but got commit_mem_valid=1");
          errors++;
        end
        if (commit_trap !== 1'b0) begin
          $error("rv32_pipeline_muldiv_tb: expected commit_trap=0 but got commit_trap=1");
          errors++;
        end
      end
      @(posedge clk);
      #1;
    end
  endtask

  always @(posedge clk) begin
    if (rst) begin
      muldiv_request_count <= 0;
      muldiv_complete_count <= 0;
      muldiv_wait_cycles <= 0;
    end else begin
      // Count accepted requests, completions, and wait cycles. During a wait,
      // fetch remains stopped and the M instruction remains resident in ID/EX.
      if ((dut.multiplier_req_valid && dut.multiplier_req_ready) || (dut.divider_req_valid && dut.divider_req_ready)) begin
        muldiv_request_count <= muldiv_request_count + 1;
      end
      if (dut.muldiv_complete) begin
        muldiv_complete_count <= muldiv_complete_count + 1;
      end
      if (dut.muldiv_active && !dut.muldiv_complete) begin
        muldiv_wait_cycles <= muldiv_wait_cycles + 1;
        if (imem_req_valid !== 1'b0) begin
          $error("rv32_pipeline_muldiv_tb: expected imem_req_valid=0 during muldiv wait cycle but got imem_req_valid=1");
          errors++;
        end
        if (dut.id_ex_q.valid !== 1'b1) begin
          $error("rv32_pipeline_muldiv_tb: ID/EX instruction disappeared during muldiv wait");
          errors++;
        end
      end
    end
  end

  initial begin
    rst = 1'b1;
    errors = 0;
    reset_core();

    // All eight M operations must issue once, complete once, and retire in order.
    expect_commit(32'h0000_0000, 32'h0070_0093, 5'd1, 32'h0000_0007);
    expect_commit(32'h0000_0004, 32'hffd0_0113, 5'd2, 32'hffff_fffd);
    expect_commit(32'h0000_0008, 32'h0220_81b3, 5'd3, 32'hffff_ffeb);
    expect_commit(32'h0000_000c, 32'h0011_8233, 5'd4, 32'hffff_fff2);
    expect_commit(32'h0000_0010, 32'h0220_c2b3, 5'd5, 32'hffff_fffe);
    expect_commit(32'h0000_0014, 32'h0220_e333, 5'd6, 32'h0000_0001);
    expect_commit(32'h0000_0018, 32'hff90_0393, 5'd7, 32'hffff_fff9);
    expect_commit(32'h0000_001c, 32'h0223_9433, 5'd8, 32'h0000_0000);
    expect_commit(32'h0000_0020, 32'h0223_a4b3, 5'd9, 32'hffff_fff9);
    expect_commit(32'h0000_0024, 32'h0223_b533, 5'd10, 32'hffff_fff6);
    expect_commit(32'h0000_0028, 32'h0223_d5b3, 5'd11, 32'h0000_0000);
    expect_commit(32'h0000_002c, 32'h0223_f633, 5'd12, 32'hffff_fff9);
    if (muldiv_request_count != 8) begin
      $error("rv32_pipeline_muldiv_tb: expected 8 accepted M request but got %0d", muldiv_request_count);
      errors++;
    end
    if (muldiv_complete_count != 8) begin
      $error("rv32_pipeline_muldiv_tb: expected 8 completed M operation but got %0d", muldiv_complete_count);
      errors++;
    end
    if (muldiv_wait_cycles == 0) begin
      $error("rv32_pipeline_muldiv_tb: expected at least 1 muldiv wait cycle but got 0");
      errors++;
    end
    if (dut.regfile.registers[1] !== 32'h0000_0007 ||
        dut.regfile.registers[2] !== 32'hffff_fffd ||
        dut.regfile.registers[3] !== 32'hffff_ffeb ||
        dut.regfile.registers[4] !== 32'hffff_fff2 ||
        dut.regfile.registers[5] !== 32'hffff_fffe ||
        dut.regfile.registers[6] !== 32'h0000_0001 ||
        dut.regfile.registers[7] !== 32'hffff_fff9 ||
        dut.regfile.registers[8] !== 32'h0000_0000 ||
        dut.regfile.registers[9] !== 32'hffff_fff9 ||
        dut.regfile.registers[10] !== 32'hffff_fff6 ||
        dut.regfile.registers[11] !== 32'h0000_0000 ||
        dut.regfile.registers[12] !== 32'hffff_fff9) begin
      $error("rv32_pipeline_muldiv_tb: final regfile values do not match expected");
      errors++;
    end
    if (errors == 0) begin
      $display("rv32_pipeline_muldiv_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_pipeline_muldiv_tb: FAIL with %0d errors", errors);
    end
  end

endmodule
