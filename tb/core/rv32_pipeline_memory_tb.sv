// SPDX-License-Identifier: Apache-2.0
//
// Pipeline load/store integration test.
//
// The test verifies instruction retirement, byte-lane formatting, load
// extension, and pipeline blocking while a data
// request is outstanding. The simple memory model provides one delayed response
// for every accepted request.

`timescale 1ns/1ps

module rv32_pipeline_memory_tb;

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

  rv32_simple_memory memory (
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
    $fatal(1, "rv32_pipeline_memory_tb: timeout");
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

  task automatic expect_alu_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [4:0] expected_rd_addr,
    input logic [31:0] expected_rd_wdata
  );
    int cycles;
    begin
      // Check an ALU commit surrounding the memory-operation sequence.
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 100) begin
        @(posedge clk);
        #1;
        cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $error("rv32_pipeline_memory_tb: timeout waiting for commit");
        errors++;
      end else if (commit_pc !== expected_pc ||
                   commit_instr !== expected_instr ||
                   commit_rd_write !== 1'b1 ||
                   commit_rd_addr !== expected_rd_addr ||
                   commit_rd_wdata !== expected_rd_wdata ||
                   commit_mem_valid !== 1'b0 ||
                   commit_trap !== 1'b0) begin
        $error("rv32_pipeline_memory_tb: commit values do not match expected");
        errors++;
      end
      @(posedge clk);
      #1;
    end
  endtask

  task automatic expect_store_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [31:0] expected_mem_addr,
    input logic [3:0] expected_mem_wmask,
    input logic [31:0] expected_mem_wdata
  );
    int cycles;
    begin
      // A store commit reports its aligned address, byte mask, and shifted data.
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 100) begin
        @(posedge clk);
        #1;
        cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $error("rv32_pipeline_memory_tb: timeout waiting for commit");
        errors++;
      end else if (commit_pc !== expected_pc ||
                   commit_instr !== expected_instr ||
                   commit_rd_write !== 1'b0 ||
                   commit_rd_addr !== 5'd0 ||
                   commit_rd_wdata !== 32'd0 ||
                   commit_mem_valid !== 1'b1 ||
                   commit_mem_write !== 1'b1 ||
                   commit_mem_addr !== expected_mem_addr ||
                   commit_mem_rmask !== 4'b0000 ||
                   commit_mem_wmask !== expected_mem_wmask ||
                   commit_mem_rdata !== 32'd0 ||
                   commit_mem_wdata !== expected_mem_wdata ||
                   commit_trap !== 1'b0) begin
        $error("rv32_pipeline_memory_tb: store commit values do not match expected");
        errors++;
      end

      @(posedge clk);
      #1;
    end
  endtask

  task automatic expect_load_commit(
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic [4:0] expected_rd_addr,
    input logic [31:0] expected_rd_wdata,
    input logic [31:0] expected_mem_addr,
    input logic [3:0] expected_mem_rmask,
    input logic [31:0] expected_mem_rdata
  );
    int cycles;
    begin
      // A load commit reports raw memory data, read mask, and extended rd value.
      cycles = 0;
      while (commit_valid !== 1'b1 && cycles < 100) begin
        @(posedge clk);
        #1;
        cycles++;
      end

      if (commit_valid !== 1'b1) begin
        $error("rv32_pipeline_memory_tb: timeout waiting for commit");
        errors++;
      end else if (commit_pc !== expected_pc ||
                   commit_instr !== expected_instr ||
                   commit_rd_write !== 1'b1 ||
                   commit_rd_addr !== expected_rd_addr ||
                   commit_rd_wdata !== expected_rd_wdata ||
                   commit_mem_valid !== 1'b1 ||
                   commit_mem_write !== 1'b0 ||
                   commit_mem_addr !== expected_mem_addr ||
                   commit_mem_rmask !== expected_mem_rmask ||
                   commit_mem_wmask !== 4'b0000 ||
                   commit_mem_rdata !== expected_mem_rdata ||
                   commit_mem_wdata !== 32'd0 ||
                   commit_trap !== 1'b0) begin
        $error("rv32_pipeline_memory_tb: load commit values do not match expected");
        errors++;
      end

      @(posedge clk);
      #1;
    end
  endtask

  task automatic check_memory_stall;
    rv32_pipeline_pkg::ex_mem_payload_t saved_ex_mem;
    rv32_pipeline_pkg::id_ex_payload_t saved_id_ex;
    rv32_pipeline_pkg::if_id_payload_t saved_if_id;
    begin
      // While a data response is outstanding, EX/MEM and all younger stages
      // remain unchanged and MEM/WB contains no new commit.
      wait (dut.mem_active === 1'b1 && dut.dmem_pending_q === 1'b1 &&  dmem_resp_valid !== 1'b1);
      #1;

      saved_ex_mem = dut.ex_mem_q;
      saved_id_ex = dut.id_ex_q;
      saved_if_id = dut.if_id_q;

      if (dmem_req_valid !== 1'b0) begin
        $error("rv32_pipeline_memory_tb: dmem_req_valid should be 0 during stall");
        errors++;
      end

      @(posedge clk);
      #1;

      if (dut.ex_mem_q !== saved_ex_mem ||
          dut.id_ex_q !== saved_id_ex ||
          dut.if_id_q !== saved_if_id ||
          dut.mem_wb_q.valid !== 1'b0) begin
        $error("rv32_pipeline_memory_tb: pipeline did not stall as expected");
        errors++;
      end
    end
  endtask

  initial begin
    errors = 0;
    rst = 1'b1;
    memory.clear_memory();

    // Directed program covering word, byte, and halfword accesses:
    //   addi x1, x0, 256
    //   addi x2, x0, 85
    //   sw   x2, 0(x1)
    //   lw   x3, 0(x1)
    // The later instructions exercise signed and unsigned loads at different lanes.
    memory.write_word(32'h0000_0000, 32'h1000_0093); // ADDI x1, x0, 256
    memory.write_word(32'h0000_0004, 32'h0550_0113); // ADDI x2, x0, 85
    memory.write_word(32'h0000_0008, 32'h0020_a023); // SW   x2, 0(x1)
    memory.write_word(32'h0000_000c, 32'h0000_a183); // LW   x3, 0(x1)
    memory.write_word(32'h0000_0010, 32'hf800_0213); // ADDI x4, x0, -128
    memory.write_word(32'h0000_0014, 32'h0040_80a3); // SB   x4, 1(x1)
    memory.write_word(32'h0000_0018, 32'h0010_8283); // LB   x5, 1(x1)
    memory.write_word(32'h0000_001c, 32'h0010_c303); // LBU  x6, 1(x1)
    memory.write_word(32'h0000_0020, 32'h0040_9123); // SH  x4, 2(x1)
    memory.write_word(32'h0000_0024, 32'h0020_9383); // LH  x7, 2(x1)
    memory.write_word(32'h0000_0028, 32'h0020_d403); // LHU x8, 2(x1)

    reset_core();

    // Check commits in program order and observe a real blocking memory stall.
    expect_alu_commit(32'h0000_0000, 32'h1000_0093, 5'd1, 32'h0000_0100);
    expect_alu_commit(32'h0000_0004, 32'h0550_0113, 5'd2, 32'h0000_0055);
    fork
      check_memory_stall();
      expect_store_commit(32'h0000_0008, 32'h0020_a023, 32'h0000_0100, 4'b1111, 32'h0000_0055);
    join

    if (memory.read_word(32'h0000_0100) !== 32'h0000_0055) begin
      $error("rv32_pipeline_memory_tb: memory content after store does not match expected");
      errors++;
    end

    expect_load_commit(32'h0000_000c, 32'h0000_a183, 5'd3, 32'h0000_0055, 32'h0000_0100, 4'b1111, 32'h0000_0055);
    expect_alu_commit(32'h0000_0010, 32'hf800_0213, 5'd4, 32'hffff_ff80);
    expect_store_commit(32'h0000_0014, 32'h0040_80a3, 32'h0000_0100, 4'b0010, 32'h0000_8000);

    if (memory.read_word(32'h0000_0100) !== 32'h0000_8055) begin
      $error("rv32_pipeline_memory_tb: memory content after SB does not match expected");
      errors++;
    end

    expect_load_commit(32'h0000_0018, 32'h0010_8283, 5'd5, 32'hffff_ff80, 32'h0000_0100, 4'b0010, 32'h0000_8055);
    expect_load_commit(32'h0000_001c, 32'h0010_c303, 5'd6, 32'h0000_0080, 32'h0000_0100, 4'b0010, 32'h0000_8055);
    expect_store_commit(32'h0000_0020, 32'h0040_9123, 32'h0000_0100, 4'b1100, 32'hff80_0000);

    if (memory.read_word(32'h0000_0100) !== 32'hff80_8055) begin
      $error("rv32_pipeline_memory_tb: memory content after SH does not match expected");
      errors++;
    end

    expect_load_commit(32'h0000_0024, 32'h0020_9383, 5'd7, 32'hffff_ff80, 32'h0000_0100, 4'b1100, 32'hff80_8055);
    expect_load_commit(32'h0000_0028, 32'h0020_d403, 5'd8, 32'h0000_ff80, 32'h0000_0100, 4'b1100, 32'hff80_8055);

    if (errors == 0) begin
      $display("rv32_pipeline_memory_tb: PASS");
    end else begin
      $fatal(1, "rv32_pipeline_memory_tb: FAIL - %0d errors", errors);
    end
    $finish;
  end

endmodule
