// SPDX-License-Identifier: Apache-2.0
//
// Directed tests for one ordered memory request, held completion, faults, and
// recovery. Load/store lane formatting is checked through the LSU interface.

`timescale 1ns/1ps

module rv32_ooo_lsu_tb;
  import rv32_ooo_pkg::*;

  logic                           clk;
  logic                           rst;
  logic                           flush;
  logic                           issue_valid;
  logic                           issue_ready;
  issue_uop_t                     issue_uop;
  logic [31:0]                    issue_base;
  logic [31:0]                    issue_store_value;
  logic                           dmem_req_valid;
  logic                           dmem_req_ready;
  logic [31:0]                    dmem_req_addr;
  logic                           dmem_req_write;
  logic [31:0]                    dmem_req_wdata;
  logic [3:0]                     dmem_req_wstrb;
  logic                           dmem_resp_valid;
  logic [31:0]                    dmem_resp_rdata;
  logic                           dmem_resp_error;
  logic                           completion_valid;
  logic                           completion_ready;
  completion_payload_t            completion_payload;
  logic                           completion_trap;
  rv32_core_pkg::trap_cause_e     completion_trap_cause;
  logic                           completion_mem_valid;
  logic                           completion_mem_write;
  logic [31:0]                    completion_mem_addr;
  logic [3:0]                     completion_mem_rmask;
  logic [3:0]                     completion_mem_wmask;
  logic [31:0]                    completion_mem_rdata;
  logic [31:0]                    completion_mem_wdata;
  int unsigned                    errors;

  rv32_ooo_lsu dut (
    .clk_i(clk),
    .rst_i(rst),
    .flush_i(flush),
    .issue_valid_i(issue_valid),
    .issue_ready_o(issue_ready),
    .issue_uop_i(issue_uop),
    .issue_base_i(issue_base),
    .issue_store_value_i(issue_store_value),
    .dmem_req_valid_o(dmem_req_valid),
    .dmem_req_ready_i(dmem_req_ready),
    .dmem_req_addr_o(dmem_req_addr),
    .dmem_req_write_o(dmem_req_write),
    .dmem_req_wdata_o(dmem_req_wdata),
    .dmem_req_wstrb_o(dmem_req_wstrb),
    .dmem_resp_valid_i(dmem_resp_valid),
    .dmem_resp_rdata_i(dmem_resp_rdata),
    .dmem_resp_error_i(dmem_resp_error),
    .completion_valid_o(completion_valid),
    .completion_ready_i(completion_ready),
    .completion_payload_o(completion_payload),
    .completion_trap_o(completion_trap),
    .completion_trap_cause_o(completion_trap_cause),
    .completion_mem_valid_o(completion_mem_valid),
    .completion_mem_write_o(completion_mem_write),
    .completion_mem_addr_o(completion_mem_addr),
    .completion_mem_rmask_o(completion_mem_rmask),
    .completion_mem_wmask_o(completion_mem_wmask),
    .completion_mem_rdata_o(completion_mem_rdata),
    .completion_mem_wdata_o(completion_mem_wdata)
  );

  always #5 clk = ~clk;

  task automatic drive_idle;
    begin
      flush = 1'b0;
      issue_valid = 1'b0;
      issue_uop = '0;
      issue_base = 32'b0;
      issue_store_value = 32'b0;
      dmem_req_ready = 1'b0;
      dmem_resp_valid = 1'b0;
      dmem_resp_rdata = 32'b0;
      dmem_resp_error = 1'b0;
      completion_ready = 1'b0;
    end
  endtask

  task automatic run_transaction(
    input string test_name,
    input rv32_pkg::mem_op_e mem_op,
    input rv32_pkg::mem_size_e mem_size,
    input logic load_unsigned,
    input logic [31:0] addr,
    input logic [31:0] response_word,
    input logic response_error,
    input logic [31:0] expected_result,
    input rv32_core_pkg::trap_cause_e expected_cause,
    input logic [3:0] expected_mask,
    input logic [31:0] expected_store_word
  );
    logic misaligned;
    int unsigned cycle;
    begin
      @(negedge clk);
      drive_idle();
      issue_uop.pc = 32'h0000_1000;
      issue_uop.imm = 32'd4;
      issue_uop.rob_tag.generation = 1'b1;
      issue_uop.rob_tag.index = ROB_INDEX_WIDTH'(3);
      issue_uop.phys_rd = phys_reg_idx_t'(40);
      issue_uop.rd_write = (mem_op == rv32_pkg::MEM_LOAD);
      issue_uop.mem_op = mem_op;
      issue_uop.mem_size = mem_size;
      issue_uop.load_unsigned = load_unsigned;
      issue_base = addr - 32'd4;
      issue_store_value = 32'h1234_ab80;
      issue_valid = 1'b1;
      #1;
      if (issue_ready !== 1'b1) begin
        $error("%s: LSU did not accept Issue", test_name);
        errors++;
      end

      @(posedge clk);
      #1;
      @(negedge clk);
      issue_valid = 1'b0;
      issue_uop = '0;
      issue_base = '1;
      issue_store_value = '1;
      misaligned = (expected_cause == rv32_core_pkg::CORE_TRAP_LOAD_ADDRESS_MISALIGNED || expected_cause == rv32_core_pkg::CORE_TRAP_STORE_ADDRESS_MISALIGNED);

      if (misaligned) begin
        #1;
        if (dmem_req_valid !== 1'b0) begin
          $error("%s: misaligned access issued a memory request", test_name);
          errors++;
        end
        @(posedge clk);
        #1;
      end else begin
        // No request is accepted for three cycles; identity and request fields
        // must continue to come from the saved uop rather than the Issue inputs.
        for (cycle = 0; cycle < 3; cycle++) begin
          #1;
          if (dmem_req_valid !== 1'b1 || dmem_req_addr !== {addr[31:2], 2'b00} || dmem_req_write !== (mem_op == rv32_pkg::MEM_STORE) || issue_ready !== 1'b0) begin
            $error("%s: request changed while memory was not ready", test_name);
            errors++;
          end
          if (mem_op == rv32_pkg::MEM_STORE && (dmem_req_wstrb !== expected_mask || dmem_req_wdata !== expected_store_word)) begin
            $error("%s: store mask or data mismatch", test_name);
            errors++;
          end
          @(negedge clk);
        end

        dmem_req_ready = 1'b1;
        @(posedge clk);
        #1;
        @(negedge clk);
        dmem_req_ready = 1'b0;
        repeat (2) begin
          #1;
          if (dmem_req_valid !== 1'b0 || completion_valid !== 1'b0) begin
            $error("%s: request repeated or completed before response", test_name);
            errors++;
          end
          @(negedge clk);
        end

        dmem_resp_valid = 1'b1;
        dmem_resp_rdata = response_word;
        dmem_resp_error = response_error;
        @(posedge clk);
        #1;
      end

      @(negedge clk);
      dmem_resp_valid = 1'b0;
      dmem_resp_rdata = ~response_word;
      dmem_resp_error = !response_error;
      for (cycle = 0; cycle < 3; cycle++) begin
        #1;
        if (completion_valid !== 1'b1 || completion_payload.rob_tag !== {1'b1, ROB_INDEX_WIDTH'(3)} || completion_payload.phys_rd !== phys_reg_idx_t'(40) || completion_payload.actual_next_pc !== 32'h0000_1004 || completion_payload.result !== expected_result) begin
          $error("%s: completion identity or result changed while stalled", test_name);
          errors++;
        end
        if (completion_payload.rd_write !== (mem_op == rv32_pkg::MEM_LOAD && expected_cause == rv32_core_pkg::CORE_TRAP_NONE) || completion_trap !== (expected_cause != rv32_core_pkg::CORE_TRAP_NONE) || completion_trap_cause !== expected_cause) begin
          $error("%s: writeback or trap metadata mismatch", test_name);
          errors++;
        end
        if (completion_payload.trap !== completion_trap || (completion_trap && completion_payload.trap_cause !== completion_trap_cause) || completion_payload.mem_valid !== completion_mem_valid || completion_payload.mem_write !== completion_mem_write || completion_payload.mem_addr !== completion_mem_addr || completion_payload.mem_rmask !== completion_mem_rmask || completion_payload.mem_wmask !== completion_mem_wmask || completion_payload.mem_rdata !== completion_mem_rdata || completion_payload.mem_wdata !== completion_mem_wdata) begin
          $error("%s: CDB payload lost trap or memory metadata", test_name);
          errors++;
        end
        if (expected_cause == rv32_core_pkg::CORE_TRAP_NONE) begin
          if (completion_mem_valid !== 1'b1 || completion_mem_write !== (mem_op == rv32_pkg::MEM_STORE) || completion_mem_addr !== {addr[31:2], 2'b00}) begin
            $error("%s: memory completion identity mismatch", test_name);
            errors++;
          end
          if (mem_op == rv32_pkg::MEM_LOAD) begin
            if (completion_mem_rmask !== expected_mask || completion_mem_rdata !== response_word || completion_mem_wmask !== 4'b0 || completion_mem_wdata !== 32'b0) begin
              $error("%s: Load commit data or mask mismatch", test_name);
              errors++;
            end
          end else if (completion_mem_wmask !== expected_mask || completion_mem_wdata !== expected_store_word || completion_mem_rmask !== 4'b0 || completion_mem_rdata !== 32'b0) begin
            $error("%s: Store commit data or mask mismatch", test_name);
            errors++;
          end
        end else if ({completion_mem_valid, completion_mem_write, completion_mem_addr, completion_mem_rmask, completion_mem_wmask, completion_mem_rdata, completion_mem_wdata} !== '0) begin
          $error("%s: fault produced memory commit metadata", test_name);
          errors++;
        end
        @(negedge clk);
      end

      completion_ready = 1'b1;
      @(posedge clk);
      #1;
      if (completion_valid !== 1'b0 || issue_ready !== 1'b1) begin
        $error("%s: completion was not consumed", test_name);
        errors++;
      end
    end
  endtask

  task automatic test_loads;
    begin
      run_transaction("LB", rv32_pkg::MEM_LOAD, rv32_pkg::MEM_BYTE, 1'b0, 32'h0000_2001, 32'h1234_8056, 1'b0, 32'hffff_ff80, rv32_core_pkg::CORE_TRAP_NONE, 4'b0010, 32'b0);
      run_transaction("LBU", rv32_pkg::MEM_LOAD, rv32_pkg::MEM_BYTE, 1'b1, 32'h0000_2001, 32'h1234_8056, 1'b0, 32'h0000_0080, rv32_core_pkg::CORE_TRAP_NONE, 4'b0010, 32'b0);
      run_transaction("LH", rv32_pkg::MEM_LOAD, rv32_pkg::MEM_HALF, 1'b0, 32'h0000_2002, 32'hab80_1234, 1'b0, 32'hffff_ab80, rv32_core_pkg::CORE_TRAP_NONE, 4'b1100, 32'b0);
      run_transaction("LHU", rv32_pkg::MEM_LOAD, rv32_pkg::MEM_HALF, 1'b1, 32'h0000_2002, 32'hab80_1234, 1'b0, 32'h0000_ab80, rv32_core_pkg::CORE_TRAP_NONE, 4'b1100, 32'b0);
      run_transaction("LW", rv32_pkg::MEM_LOAD, rv32_pkg::MEM_WORD, 1'b0, 32'h0000_2000, 32'hab80_1234, 1'b0, 32'hab80_1234, rv32_core_pkg::CORE_TRAP_NONE, 4'b1111, 32'b0);
    end
  endtask

  task automatic test_stores;
    begin
      run_transaction("SB", rv32_pkg::MEM_STORE, rv32_pkg::MEM_BYTE, 1'b0, 32'h0000_2001, 32'b0, 1'b0, 32'b0, rv32_core_pkg::CORE_TRAP_NONE, 4'b0010, 32'h0000_8000);
      run_transaction("SH", rv32_pkg::MEM_STORE, rv32_pkg::MEM_HALF, 1'b0, 32'h0000_2002, 32'b0, 1'b0, 32'b0, rv32_core_pkg::CORE_TRAP_NONE, 4'b1100, 32'hab80_0000);
      run_transaction("SW", rv32_pkg::MEM_STORE, rv32_pkg::MEM_WORD, 1'b0, 32'h0000_2000, 32'b0, 1'b0, 32'b0, rv32_core_pkg::CORE_TRAP_NONE, 4'b1111, 32'h1234_ab80);
    end
  endtask

  task automatic test_flush(input logic accepted_request);
    begin
      @(negedge clk);
      drive_idle();
      issue_uop.mem_op = rv32_pkg::MEM_LOAD;
      issue_uop.mem_size = rv32_pkg::MEM_WORD;
      issue_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      issue_valid = 1'b0;
      if (accepted_request) begin
        dmem_req_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        dmem_req_ready = 1'b0;
      end

      flush = 1'b1;
      #1;
      if (dmem_req_valid !== 1'b0 || completion_valid !== 1'b0 || issue_ready !== 1'b0) begin
        $error("flush: outputs were not suppressed");
        errors++;
      end
      @(posedge clk);
      @(negedge clk);
      flush = 1'b0;

      if (accepted_request) begin
        repeat (3) begin
          #1;
          if (issue_ready !== 1'b0 || completion_valid !== 1'b0 || dmem_req_valid !== 1'b0) begin
            $error("flush: old request was not drained");
            errors++;
          end
          @(negedge clk);
        end
        dmem_resp_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        dmem_resp_valid = 1'b0;
      end
      #1;
      if (issue_ready !== 1'b1 || completion_valid !== 1'b0) begin
        $error("flush: LSU did not return to idle");
        errors++;
      end
    end
  endtask

  task automatic test_faults_and_flush;
    begin
      run_transaction("misaligned LW", rv32_pkg::MEM_LOAD, rv32_pkg::MEM_WORD, 1'b0, 32'h0000_2002, 32'b0, 1'b0, 32'b0, rv32_core_pkg::CORE_TRAP_LOAD_ADDRESS_MISALIGNED, 4'b0000, 32'b0);
      run_transaction("misaligned SH", rv32_pkg::MEM_STORE, rv32_pkg::MEM_HALF, 1'b0, 32'h0000_2001, 32'b0, 1'b0, 32'b0, rv32_core_pkg::CORE_TRAP_STORE_ADDRESS_MISALIGNED, 4'b0000, 32'b0);
      run_transaction("Load access fault", rv32_pkg::MEM_LOAD, rv32_pkg::MEM_WORD, 1'b0, 32'h0000_2000, 32'hffff_ffff, 1'b1, 32'b0, rv32_core_pkg::CORE_TRAP_LOAD_ACCESS_FAULT, 4'b1111, 32'b0);
      run_transaction("Store access fault", rv32_pkg::MEM_STORE, rv32_pkg::MEM_WORD, 1'b0, 32'h0000_2000, 32'hffff_ffff, 1'b1, 32'b0, rv32_core_pkg::CORE_TRAP_STORE_ACCESS_FAULT, 4'b1111, 32'h1234_ab80);
      test_flush(1'b0);
      test_flush(1'b1);
    end
  endtask

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    errors = 0;
    drive_idle();
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    #1;
    if (issue_ready !== 1'b1 || dmem_req_valid !== 1'b0 || completion_valid !== 1'b0) begin
      $error("reset: LSU did not start idle");
      errors++;
    end
    test_loads();
    test_stores();
    test_faults_and_flush();
    if (errors !== 0) $fatal(1, "rv32_ooo_lsu_tb: %0d errors", errors);
    $display("rv32_ooo_lsu_tb: loads, stores, backpressure, faults, and flush passed");
    $finish;
  end

endmodule
