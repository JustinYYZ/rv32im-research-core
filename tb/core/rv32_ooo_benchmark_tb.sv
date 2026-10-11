// SPDX-License-Identifier: Apache-2.0
//
// Bare-metal benchmark harness for the OoO core and split L1 caches.

`timescale 1ns/1ps

module rv32_ooo_benchmark_tb;

  localparam logic [31:0] RESET_PC = 32'haaaa_a000;
  localparam logic [31:0] IPC_START_INST = 32'h0010_2013;
  localparam logic [31:0] IPC_STOP_INST  = 32'h0020_2013;
  localparam logic [31:0] PWR_START_INST = 32'h0030_2013;
  localparam logic [31:0] PWR_STOP_INST  = 32'h0040_2013;

  logic clk;
  logic rst;

  logic        imem_req_valid;
  logic        imem_req_ready;
  logic [31:0] imem_req_addr;
  logic        imem_resp_valid;
  logic [31:0] imem_resp_data;
  logic        imem_resp_error;

  logic        dmem_req_valid;
  logic        dmem_req_ready;
  logic [31:0] dmem_req_addr;
  logic        dmem_req_write;
  logic [31:0] dmem_req_wdata;
  logic [3:0]  dmem_req_wstrb;
  logic        dmem_resp_valid;
  logic [31:0] dmem_resp_rdata;
  logic        dmem_resp_error;

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

  string image_path;
  string trace_path;
  int trace_fd;
  logic [31:0] signature_addr;
  logic [31:0] expected_signature;
  logic signature_seen;

  logic roi_active;
  logic roi_complete;
  logic power_roi_active;

  longint unsigned roi_cycle_count;
  longint unsigned roi_commit_count;
  longint unsigned power_start_cycle;

  time power_start_time;

  int unsigned cycle_count;
  int unsigned commit_count;
  int unsigned max_cycles;
  int unsigned check_signature;

  rv32_ooo_l1_top #(
    .RESET_PC(RESET_PC)
  ) dut (
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
    .halted_o()
  );

  rv32_benchmark_memory memory (
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

  function automatic logic is_magic_halt(input logic [31:0] instr);
    return instr == 32'h0000_0063 || instr == 32'h0000_006f || instr == 32'hf000_2013;
  endfunction

  always #5 clk = ~clk;

  always @(negedge clk) begin
    if (!rst) begin
      cycle_count = cycle_count + 1;

      if (roi_active) begin
        roi_cycle_count = roi_cycle_count + 1;
      end

      if (commit_valid) begin
        commit_count = commit_count + 1;

        if (trace_fd != 0) begin
          $fdisplay(trace_fd, "%0d,%08h,%08h,%0d,%0d,%08h,%0d,%0d,%08h,%1h,%1h,%08h,%08h,%0d,%0d", commit_count, commit_pc, commit_instr, commit_rd_write, commit_rd_addr,
                    commit_rd_wdata, commit_mem_valid, commit_mem_write, commit_mem_addr, commit_mem_rmask, commit_mem_wmask, commit_mem_rdata, commit_mem_wdata, commit_trap, commit_trap_cause);
        end

        if (commit_trap) begin
          $fatal(1, "Unexpected trap at PC 0x%08h, cause=%0d", commit_pc, commit_trap_cause);
        end

        if (commit_mem_valid && commit_mem_write && commit_mem_addr == signature_addr) begin
          signature_seen = commit_mem_wmask === 4'b1111 && commit_mem_wdata === expected_signature;
        end

        if (commit_instr == IPC_START_INST) begin
          if (roi_active) begin
            $fatal(1, "Nested IPC ROI start at PC 0x%08h", commit_pc);
          end

          roi_active = 1'b1;
          roi_complete = 1'b0;
          roi_cycle_count = 0;
          roi_commit_count = 0;
        end else if (commit_instr == IPC_STOP_INST) begin
          if (!roi_active) begin
            $fatal(1, "IPC ROI stop without start at PC 0x%08h", commit_pc);
          end

          roi_commit_count = roi_commit_count + 1;
          roi_active = 1'b0;
          roi_complete = 1'b1;

          if (roi_cycle_count == 0) begin
            $fatal(1, "IPC ROI completed with zero cycles");
          end

          $display("BENCH_RESULT scope=roi cycles=%0d instructions=%0d ipc=%0f", roi_cycle_count, roi_commit_count, real'(roi_commit_count) / real'(roi_cycle_count));
        end else if (roi_active) begin
          roi_commit_count = roi_commit_count + 1;
        end

        if (commit_instr == PWR_START_INST) begin
          if (power_roi_active) begin
            $fatal(1, "Nested power ROI start at PC 0x%08h", commit_pc);
          end

          power_roi_active = 1'b1;
          power_start_cycle = cycle_count;
          power_start_time = $time;
        end else if (commit_instr == PWR_STOP_INST) begin
          if (!power_roi_active) begin
            $fatal(1, "Power ROI stop without start at PC 0x%08h", commit_pc);
          end

          power_roi_active = 1'b0;
          $display("POWER_RESULT start_cycle=%0d stop_cycle=%0d cycles=%0d start_time=%0t stop_time=%0t", power_start_cycle, cycle_count, cycle_count - power_start_cycle, power_start_time, $time);
        end

        if (is_magic_halt(commit_instr)) begin
          if (check_signature != 0 && !signature_seen) begin
            $fatal(1, "Program halted before writing the expected signature");
          end

          if (roi_active) begin
            $fatal(1, "Program halted before IPC ROI stop");
          end

          if (power_roi_active) begin
            $fatal(1, "Program halted before power ROI stop");
          end

          $display("rv32_ooo_benchmark_tb: PASS");
          $display("image:         %0s", image_path);
          $display("total_cycles:  %0d", cycle_count);
          $display("total_commits: %0d", commit_count);

          if (!roi_complete) begin
            $display("BENCH_RESULT scope=global cycles=%0d instructions=%0d ipc=%0f", cycle_count, commit_count, real'(commit_count) / real'(cycle_count));
          end

          if (trace_fd != 0) begin
            $fclose(trace_fd);
          end

          $finish;
        end
      end

      if (cycle_count >= max_cycles) begin
        $fatal(1, "Benchmark timeout after %0d cycles and %0d commits", cycle_count, commit_count);
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    cycle_count = 0;
    commit_count = 0;
    signature_seen = 1'b0;
    roi_active = 1'b0;
    roi_complete = 1'b0;
    roi_cycle_count = 0;
    roi_commit_count = 0;
    power_roi_active = 1'b0;
    power_start_cycle = 0;
    power_start_time = 0;
    trace_fd = 0;

    if (!$value$plusargs("MEMH=%s", image_path)) begin
      $fatal(1, "Missing +MEMH=<program.memh>");
    end

    if (!$value$plusargs("SIGNATURE_ADDR=%h", signature_addr)) begin
      signature_addr = 32'haaaa_b004;
    end

    if (!$value$plusargs("SIGNATURE_VALUE=%h", expected_signature)) begin
      expected_signature = 32'd55;
    end

    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles)) begin
      max_cycles = 100000;
    end

    if (!$value$plusargs("CHECK_SIGNATURE=%d", check_signature)) begin
      check_signature = 1;
    end

    if ($value$plusargs("COMMIT_TRACE=%s", trace_path)) begin
      trace_fd = $fopen(trace_path, "w");
      if (trace_fd == 0) begin
        $fatal(1, "Unable to open commit trace: %0s", trace_path);
      end
      $fdisplay(trace_fd, "order,pc,instr,rd_write,rd,rd_wdata,mem_valid,mem_write,mem_addr,rmask,wmask,mem_rdata,mem_wdata,trap,cause");
    end

    memory.clear_memory();
    memory.load_memh(image_path);

    repeat (4) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
  end

endmodule