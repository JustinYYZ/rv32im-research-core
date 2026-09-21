// SPDX-License-Identifier: Apache-2.0
//
// Directed core-level MUL/DIV integration checks: dependency wakeup, out-of-order
// completion with ordered retirement, shared-CDB contention, and cancellation
// of an active wrong-path divide. Arithmetic variants remain in unit regressions.

`timescale 1ns/1ps

module rv32_ooo_rv32m_tb;

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
  int unsigned                errors;

  rv32_ooo_core dut (
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

  always #5 clk = ~clk;

  // Drive reset away from the DUT's active edge to avoid sampling races.
  task automatic reset_dut;
    begin
      @(negedge clk);
      rst = 1'b1;
      repeat (2) @(posedge clk);
      @(negedge clk);
      rst = 1'b0;
    end
  endtask

  task automatic expect_commit(
    input string test_name,
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input logic expected_rd_write,
    input logic [4:0] expected_rd,
    input logic [31:0] expected_result
  );
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (commit_valid !== 1'b1 && timeout_cycles < 200) begin
        @(negedge clk);
        timeout_cycles++;
      end
      if (commit_valid !== 1'b1) begin
        $error("%s: timeout waiting for commit", test_name);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("%s: commit PC mismatch: expected 0x%08x, got 0x%08x", test_name, expected_pc, commit_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("%s: commit instruction mismatch: expected 0x%08x, got 0x%08x", test_name, expected_instr, commit_instr);
          errors++;
        end
        if (commit_rd_write !== expected_rd_write) begin
          $error("%s: commit rd_write mismatch: expected %b, got %b", test_name, expected_rd_write, commit_rd_write);
          errors++;
        end
        if (commit_rd_write) begin
          if (commit_rd_addr !== expected_rd) begin
            $error("%s: commit rd mismatch: expected %d, got %d", test_name, expected_rd, commit_rd_addr);
            errors++;
          end
          if (commit_rd_wdata !== expected_result) begin
            $error("%s: commit result mismatch: expected 0x%08x, got 0x%08x", test_name, expected_result, commit_rd_wdata);
            errors++;
          end
        end
        if (commit_mem_valid !== 1'b0 || commit_trap !== 1'b0) begin
          $error("%s: commit should not have memory or trap signals asserted", test_name);
          errors++;
        end
        @(posedge clk);
        #1;
      end
    end
  endtask

  task automatic expect_trap(
    input string test_name,
    input logic [31:0] expected_pc,
    input logic [31:0] expected_instr,
    input rv32_core_pkg::trap_cause_e expected_cause
  );
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (commit_valid !== 1'b1 && timeout_cycles < 200) begin
        @(negedge clk);
        timeout_cycles++;
      end
      if (commit_valid !== 1'b1) begin
        $error("%s: timeout waiting for commit", test_name);
        errors++;
      end else begin
        if (commit_pc !== expected_pc) begin
          $error("%s: commit PC mismatch: expected 0x%08x, got 0x%08x", test_name, expected_pc, commit_pc);
          errors++;
        end
        if (commit_instr !== expected_instr) begin
          $error("%s: commit instruction mismatch: expected 0x%08x, got 0x%08x", test_name, expected_instr, commit_instr);
          errors++;
        end
        if (commit_trap !== 1'b1) begin
          $error("%s: expected trap, but commit_trap is not asserted", test_name);
          errors++;
        end else if (commit_trap_cause !== expected_cause) begin
          $error("%s: trap cause mismatch: expected %0d, got %0d", test_name, expected_cause, commit_trap_cause);
          errors++;
        end
        if (commit_mem_valid !== 1'b0 || commit_rd_write !== 1'b0) begin
          $error("%s: commit should not have memory or rd_write signals asserted", test_name);
          errors++;
        end
      end
      @(posedge clk);
      #1;

      if (halted !== 1'b1) begin
        $error("%s: expected core to halt after trap, but halted signal is not asserted", test_name);
        errors++;
      end
      repeat (5) begin
        @(negedge clk);
        if (commit_valid !== 1'b0) begin
          $error("%s: commit should not be valid after trap and halt", test_name);
          errors++;
        end
        if (imem_req_valid !== 1'b0) begin
          $error("%s: imem_req_valid should not be asserted after trap and halt", test_name);
          errors++;
        end
      end
    end
  endtask

  task automatic test_mul_dependency;
    begin
      // A dependent ADD must consume the multiplier result through PRF/CDB
      // wakeup. Check each architectural Commit before the terminating ECALL.
      @(negedge clk);
      rst = 1'b1;
      memory.clear_memory();
      memory.write_word(32'h0000_0000, 32'h0060_0093); // ADDI x1, x0, 6
      memory.write_word(32'h0000_0004, 32'h0070_0113); // ADDI x2, x0, 7
      memory.write_word(32'h0000_0008, 32'h0220_81b3); // MUL x3, x1, x2
      memory.write_word(32'h0000_000c, 32'h0011_8233); // ADD x4, x3, x1
      memory.write_word(32'h0000_0010, 32'h0000_0073); // ECALL
      reset_dut();

      expect_commit("test_mul_dependency: ADDI x1", 32'h0000_0000, 32'h0060_0093, 1'b1, 5'd1, 32'd6);
      expect_commit("test_mul_dependency: ADDI x2", 32'h0000_0004, 32'h0070_0113, 1'b1, 5'd2, 32'd7);
      expect_commit("test_mul_dependency: MUL x3", 32'h0000_0008, 32'h0220_81b3, 1'b1, 5'd3, 32'd42);
      expect_commit("test_mul_dependency: ADD x4", 32'h0000_000c, 32'h0011_8233, 1'b1, 5'd4, 32'd48);
      expect_trap("ECALL", 32'h0000_0010, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);
    end
  endtask

  task automatic test_div_out_of_order_completion;
    begin
      // An independent ADDI completes before DIV, while retirement remains
      // ordered. The final ADD requires both results.
      @(negedge clk);
      rst = 1'b1;
      memory.clear_memory();
      memory.write_word(32'h0000_0000, 32'h00a0_0093); // ADDI x1, x0, 10
      memory.write_word(32'h0000_0004, 32'h0020_0113); // ADDI x2, x0, 2
      memory.write_word(32'h0000_0008, 32'h0220_c1b3); // DIV x3, x1, x2
      memory.write_word(32'h0000_000c, 32'h0090_0213); // ADDI x4, x0, 9
      memory.write_word(32'h0000_0010, 32'h0041_82b3); // ADD x5, x3, x4
      memory.write_word(32'h0000_0014, 32'h0000_0073); // ECALL
      reset_dut();

      fork
        begin
          expect_commit("test_div_out_of_order_completion: ADDI x1", 32'h0000_0000, 32'h00a0_0093, 1'b1, 5'd1, 32'd10);
          expect_commit("test_div_out_of_order_completion: ADDI x2", 32'h0000_0004, 32'h0020_0113, 1'b1, 5'd2, 32'd2);
          expect_commit("test_div_out_of_order_completion: DIV x3", 32'h0000_0008, 32'h0220_c1b3, 1'b1, 5'd3, 32'd5);
          expect_commit("test_div_out_of_order_completion: ADDI x4", 32'h0000_000c, 32'h0090_0213, 1'b1, 5'd4, 32'd9);
          expect_commit("test_div_out_of_order_completion: ADD x5", 32'h0000_0010, 32'h0041_82b3, 1'b1, 5'd5, 32'd14);
          expect_trap("ECALL", 32'h0000_0014, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);
        end

        // Results 9 and 5 uniquely identify ADDI and DIV in this fixed program.
        // Monitor alongside Commit checks so early broadcasts are not missed.
        begin : monitor_completion
          bit independent_seen;
          bit div_seen;
          int unsigned cycles;

          independent_seen = 1'b0;
          div_seen = 1'b0;
          cycles = 0;

          while (!div_seen && cycles < 200) begin
            @(posedge clk);
            cycles++;

            if (dut.backend.cdb_valid && dut.backend.cdb_rd_write) begin
              case (dut.backend.cdb_result)
                32'd9: independent_seen = 1'b1;
                32'd5: begin
                  div_seen = 1'b1;
                  if (!independent_seen) begin
                    $error("test_div_out_of_order_completion: DIV completed before independent ADDI x4");
                    errors++;
                  end
                end
              endcase
            end
          end
          if (!div_seen) begin
            $error("test_div_out_of_order_completion: DIV did not complete within 200 cycles");
            errors++;
          end
        end
      join
    end
  endtask

  task automatic test_completion_contention;
    begin
      // DIV holds dependent MUL/ADDI work in the IQ. Once released, the mixed
      // latencies produce ALU/MUL contention; Commit checks cover every result.
      @(negedge clk);
      rst = 1'b1;
      memory.clear_memory();
      memory.write_word(32'h0000_0000, 32'h00a0_0093); // ADDI x1, x0, 10
      memory.write_word(32'h0000_0004, 32'h0020_0113); // ADDI x2, x0, 2
      memory.write_word(32'h0000_0008, 32'h0220_c1b3); // DIV x3, x1, x2
      memory.write_word(32'h0000_000c, 32'h0231_8233); // MUL x4, x3, x3
      memory.write_word(32'h0000_0010, 32'h0011_8293); // ADDI x5, x3, 1
      memory.write_word(32'h0000_0014, 32'h0021_8313); // ADDI x6, x3, 2
      memory.write_word(32'h0000_0018, 32'h0031_8393); // ADDI x7, x3, 3
      memory.write_word(32'h0000_001c, 32'h0041_8413); // ADDI x8, x3, 4
      memory.write_word(32'h0000_0020, 32'h0000_0073); // ECALL
      reset_dut();

      fork
        begin
          expect_commit("test_completion_contention: ADDI x1", 32'h0000_0000, 32'h00a0_0093, 1'b1, 5'd1, 32'd10);
          expect_commit("test_completion_contention: ADDI x2", 32'h0000_0004, 32'h0020_0113, 1'b1, 5'd2, 32'd2);
          expect_commit("test_completion_contention: DIV x3", 32'h0000_0008, 32'h0220_c1b3, 1'b1, 5'd3, 32'd5);
          expect_commit("test_completion_contention: MUL x4", 32'h0000_000c, 32'h0231_8233, 1'b1, 5'd4, 32'd25);
          expect_commit("test_completion_contention: ADDI x5", 32'h0000_0010, 32'h0011_8293, 1'b1, 5'd5, 32'd6);
          expect_commit("test_completion_contention: ADDI x6", 32'h0000_0014, 32'h0021_8313, 1'b1, 5'd6, 32'd7);
          expect_commit("test_completion_contention: ADDI x7", 32'h0000_0018, 32'h0031_8393, 1'b1, 5'd7, 32'd8);
          expect_commit("test_completion_contention: ADDI x8", 32'h0000_001c, 32'h0041_8413, 1'b1, 5'd8, 32'd9);
          expect_trap("ECALL", 32'h0000_0020, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);
        end
        begin : monitor_completion
          bit contention_seen;
          bit alu_held;
          bit mul_held;
          int unsigned cycles;
          int unsigned writeback_count;
          rv32_ooo_pkg::completion_payload_t held_alu;
          rv32_ooo_pkg::completion_payload_t held_mul;

          contention_seen = 1'b0;
          alu_held = 1'b0;
          mul_held = 1'b0;
          cycles = 0;
          writeback_count = 0;

          while (!halted && cycles < 200) begin
            @(posedge clk);
            cycles++;
            // Check the previous stalled payload before recording this edge.
            if (alu_held && (dut.backend.alu_completion_valid !== 1'b1 || dut.backend.alu_completion_payload !== held_alu)) begin
              $error("test_completion_contention: stalled ALU completion changed");
              errors++;
            end
            if (mul_held && (dut.backend.mul_completion_valid !== 1'b1 || dut.backend.mul_completion_payload !== held_mul)) begin
              $error("test_completion_contention: stalled MUL completion changed");
              errors++;
            end

            alu_held = dut.backend.alu_completion_valid && !dut.backend.alu_completion_ready;
            mul_held = dut.backend.mul_completion_valid && !dut.backend.mul_completion_ready;
            if (alu_held) begin
              held_alu = dut.backend.alu_completion_payload;
            end
            if (mul_held) begin
              held_mul = dut.backend.mul_completion_payload;
            end

            // DIV has finished by this point; exactly one ALU/MUL source wins.
            if (dut.backend.alu_completion_valid && dut.backend.mul_completion_valid) begin
              contention_seen = 1'b1;
              if ((dut.backend.alu_completion_ready ^ dut.backend.mul_completion_ready) !== 1'b1) begin
                $error("test_completion_contention: expected exactly one ALU/MUL grant");
                errors++;
              end
            end

            // Ignore non-register completions such as ECALL and younger traps.
            if (dut.backend.cdb_valid && dut.backend.cdb_rd_write) begin
              writeback_count++;
            end
          end

          if (!halted) begin
            $error("test_completion_contention: core did not halt within 200 cycles");
            errors++;
          end

          if (!contention_seen) begin
            $error("test_completion_contention: no contention observed between ALU and MUL completions");
            errors++;
          end
          if (writeback_count !== 8) begin
            $error("test_completion_contention: expected 8 writebacks, but observed %0d", writeback_count);
            errors++;
          end
        end
      join
    end
  endtask

  task automatic test_wrong_path_div_flush;
    begin
      // MUL delays the branch until a younger wrong-path DIV can start before
      // retirement-time recovery. A new DIV then checks reuse on the correct path.
      @(negedge clk);
      rst = 1'b1;
      memory.clear_memory();
      memory.write_word(32'h0000_0000, 32'h00a0_0093); // ADDI x1, x0, 10
      memory.write_word(32'h0000_0004, 32'h0020_0113); // ADDI x2, x0, 2
      memory.write_word(32'h0000_0008, 32'h0220_81b3); // MUL x3, x1, x2
      memory.write_word(32'h0000_000c, 32'h0031_8663); // BEQ x3, x3, +12
      memory.write_word(32'h0000_0010, 32'h0220_c233); // DIV x4, x1, x2: wrong path
      memory.write_word(32'h0000_0014, 32'h0630_0213); // ADDI x4, x0, 99: wrong path
      memory.write_word(32'h0000_0018, 32'h0070_0213); // ADDI x4, x0, 7
      memory.write_word(32'h0000_001c, 32'h0221_c2b3); // DIV x5, x3, x2
      memory.write_word(32'h0000_0020, 32'h0052_0333); // ADD x6, x4, x5
      memory.write_word(32'h0000_0024, 32'h0000_0073); // ECALL
      reset_dut();

      fork
        begin
          expect_commit("test_wrong_path_div_flush: ADDI x1", 32'h0000_0000, 32'h00a0_0093, 1'b1, 5'd1, 32'd10);
          expect_commit("test_wrong_path_div_flush: ADDI x2", 32'h0000_0004, 32'h0020_0113, 1'b1, 5'd2, 32'd2);
          expect_commit("test_wrong_path_div_flush: MUL x3", 32'h0000_0008, 32'h0220_81b3, 1'b1, 5'd3, 32'd20);
          expect_commit("test_wrong_path_div_flush: BEQ x3, x3, +12", 32'h0000_000c, 32'h0031_8663, 1'b0, 5'd0, 32'd0);
          expect_commit("test_wrong_path_div_flush: ADDI x4", 32'h0000_0018, 32'h0070_0213, 1'b1, 5'd4, 32'd7);
          expect_commit("test_wrong_path_div_flush: DIV x5", 32'h0000_001c, 32'h0221_c2b3, 1'b1, 5'd5, 32'd10);
          expect_commit("test_wrong_path_div_flush: ADD x6", 32'h0000_0020, 32'h0052_0333, 1'b1, 5'd6, 32'd17);
          expect_trap("ECALL", 32'h0000_0024, 32'h0000_0073, rv32_core_pkg::CORE_TRAP_ECALL);
        end

        begin : monitor_div_flush
          bit wrong_started;
          bit redirect_seen;
          bit correct_started;
          int unsigned cycles;
          rv32_ooo_pkg::rob_tag_t wrong_tag;

          wrong_started = 1'b0;
          redirect_seen = 1'b0;
          correct_started = 1'b0;
          cycles = 0;
          wrong_tag = '0;

          while (!halted && cycles < 200) begin
            @(posedge clk);
            cycles++;

            // Save the full generation-tagged identity only on Issue acceptance.
            if (dut.backend.div_issue_valid && dut.backend.div_issue_ready) begin
              if (dut.backend.issue_uop.pc == 32'h0000_0010) begin
                wrong_started = 1'b1;
                wrong_tag = dut.backend.issue_uop.rob_tag;
              end
              if (redirect_seen && dut.backend.issue_uop.pc == 32'h0000_001c) begin
                correct_started = 1'b1;
              end
            end

            // Sample before NBA updates: recovery clears active state on this edge.
            if (dut.redirect_valid) begin
              if (!wrong_started || dut.backend.divider.request_active_q !== 1'b1 || dut.redirect_pc !== 32'h0000_0018) begin
                $error("test_wrong_path_div_flush: expected active wrong-path DIV at recovery to PC 0x18");
                errors++;
              end
              redirect_seen = 1'b1;
            end

            // Keep watching through correct-path execution for a late old result.
            if (redirect_seen && wrong_started && dut.backend.cdb_valid && dut.backend.cdb_rob_tag === wrong_tag) begin
              $error("test_wrong_path_div_flush: wrong-path DIV completion was not flushed after redirect");
              errors++;
            end
          end
          if (!halted) begin
            $error("test_wrong_path_div_flush: timeout after %0d cycles, wrong_started=%b, redirect_seen=%b, correct_started=%b", cycles, wrong_started, redirect_seen, correct_started);
            errors++;
          end

          if (!wrong_started || !redirect_seen || !correct_started) begin
            $error("test_wrong_path_div_flush: missing events after %0d cycles, wrong_started=%b, redirect_seen=%b, correct_started=%b", cycles, wrong_started, redirect_seen, correct_started);
            errors++;
          end
        end
      join
    end
  endtask

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    errors = 0;
    test_mul_dependency();
    test_div_out_of_order_completion();
    test_completion_contention();
    test_wrong_path_div_flush();

    if (errors !== 0) begin
      $fatal(1, "rv32_ooo_rv32m_tb: %0d errors", errors);
    end
    $display("rv32_ooo_rv32m_tb: dependency, arbitration, and recovery tests passed");
    $finish;
  end

endmodule
