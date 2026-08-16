// SPDX-License-Identifier: Apache-2.0
//
// Commit-level differential testbench for the reference and pipeline cores.
//
// Both cores execute the same program from independent memories. Their cycle
// counts are intentionally ignored; only architectural commit order is
// compared. The program covers dependencies, memory operations, taken and
// not-taken branches, RV32M execution, and trap termination.

`timescale 1ns/1ps

module rv32_core_differential_tb;

  localparam int unsigned MAX_COMMITS = 1024;
  localparam int unsigned MAX_CYCLES = 100000;
  localparam int unsigned EXPECTED_COMMITS = 12;

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

  logic pipe_imem_req_valid;
  logic pipe_imem_req_ready;
  logic [31:0] pipe_imem_req_addr;
  logic pipe_imem_resp_valid;
  logic [31:0] pipe_imem_resp_data;
  logic pipe_imem_resp_error;
  logic pipe_dmem_req_valid;
  logic pipe_dmem_req_ready;
  logic [31:0] pipe_dmem_req_addr;
  logic pipe_dmem_req_write;
  logic [31:0] pipe_dmem_req_wdata;
  logic [3:0] pipe_dmem_req_wstrb;
  logic pipe_dmem_resp_valid;
  logic [31:0] pipe_dmem_resp_rdata;
  logic pipe_dmem_resp_error;
  logic pipe_commit_valid;
  logic [31:0] pipe_commit_pc;
  logic [31:0] pipe_commit_instr;
  logic pipe_commit_rd_write;
  logic [4:0] pipe_commit_rd_addr;
  logic [31:0] pipe_commit_rd_wdata;
  logic pipe_commit_mem_valid;
  logic pipe_commit_mem_write;
  logic [31:0] pipe_commit_mem_addr;
  logic [3:0] pipe_commit_mem_rmask;
  logic [3:0] pipe_commit_mem_wmask;
  logic [31:0] pipe_commit_mem_rdata;
  logic [31:0] pipe_commit_mem_wdata;
  logic pipe_commit_trap;
  rv32_core_pkg::trap_cause_e pipe_commit_trap_cause;
  logic pipe_halted;

  commit_event_t ref_events [0:MAX_COMMITS-1];
  commit_event_t pipe_events [0:MAX_COMMITS-1];
  int unsigned ref_commit_count;
  int unsigned pipe_commit_count;
  int unsigned compared_count;
  int unsigned cycle_count;

  rv32_reference_core reference_core (
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

  rv32_pipeline_core pipeline_core (
    .clk_i(clk),
    .rst_i(rst),
    .imem_req_valid_o(pipe_imem_req_valid),
    .imem_req_ready_i(pipe_imem_req_ready),
    .imem_req_addr_o(pipe_imem_req_addr),
    .imem_resp_valid_i(pipe_imem_resp_valid),
    .imem_resp_data_i(pipe_imem_resp_data),
    .imem_resp_error_i(pipe_imem_resp_error),
    .dmem_req_valid_o(pipe_dmem_req_valid),
    .dmem_req_ready_i(pipe_dmem_req_ready),
    .dmem_req_addr_o(pipe_dmem_req_addr),
    .dmem_req_write_o(pipe_dmem_req_write),
    .dmem_req_wdata_o(pipe_dmem_req_wdata),
    .dmem_req_wstrb_o(pipe_dmem_req_wstrb),
    .dmem_resp_valid_i(pipe_dmem_resp_valid),
    .dmem_resp_rdata_i(pipe_dmem_resp_rdata),
    .dmem_resp_error_i(pipe_dmem_resp_error),
    .commit_valid_o(pipe_commit_valid),
    .commit_pc_o(pipe_commit_pc),
    .commit_instr_o(pipe_commit_instr),
    .commit_rd_write_o(pipe_commit_rd_write),
    .commit_rd_addr_o(pipe_commit_rd_addr),
    .commit_rd_wdata_o(pipe_commit_rd_wdata),
    .commit_mem_valid_o(pipe_commit_mem_valid),
    .commit_mem_write_o(pipe_commit_mem_write),
    .commit_mem_addr_o(pipe_commit_mem_addr),
    .commit_mem_rmask_o(pipe_commit_mem_rmask),
    .commit_mem_wmask_o(pipe_commit_mem_wmask),
    .commit_mem_rdata_o(pipe_commit_mem_rdata),
    .commit_mem_wdata_o(pipe_commit_mem_wdata),
    .commit_trap_o(pipe_commit_trap),
    .commit_trap_cause_o(pipe_commit_trap_cause),
    .halted_o(pipe_halted)
  );

  rv32_simple_memory reference_memory (
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

  rv32_simple_memory pipeline_memory (
    .clk_i(clk),
    .rst_i(rst),
    .imem_req_valid_i(pipe_imem_req_valid),
    .imem_req_ready_o(pipe_imem_req_ready),
    .imem_req_addr_i(pipe_imem_req_addr),
    .imem_resp_valid_o(pipe_imem_resp_valid),
    .imem_resp_data_o(pipe_imem_resp_data),
    .imem_resp_error_o(pipe_imem_resp_error),
    .dmem_req_valid_i(pipe_dmem_req_valid),
    .dmem_req_ready_o(pipe_dmem_req_ready),
    .dmem_req_addr_i(pipe_dmem_req_addr),
    .dmem_req_write_i(pipe_dmem_req_write),
    .dmem_req_wdata_i(pipe_dmem_req_wdata),
    .dmem_req_wstrb_i(pipe_dmem_req_wstrb),
    .dmem_resp_valid_o(pipe_dmem_resp_valid),
    .dmem_resp_rdata_o(pipe_dmem_resp_rdata),
    .dmem_resp_error_o(pipe_dmem_resp_error)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  task automatic write_word_both(input logic [31:0] byte_addr, input logic [31:0] data);
    begin
      reference_memory.write_word(byte_addr, data);
      pipeline_memory.write_word(byte_addr, data);
    end
  endtask

  task automatic load_program;
    begin
      reference_memory.clear_memory();
      pipeline_memory.clear_memory();

      // Both cores start from identical program and data images but update
      // independent memories while they execute.
      write_word_both(32'h0000_0000, 32'h0050_0093); // ADDI x1, x0, 5
      write_word_both(32'h0000_0004, 32'h0030_8113); // ADDI x2, x1, 3
      write_word_both(32'h0000_0008, 32'h1000_0193); // ADDI x3, x0, 0x100
      write_word_both(32'h0000_000c, 32'h0021_a023); // SW x2, 0(x3)
      write_word_both(32'h0000_0010, 32'h0001_a203); // LW x4, 0(x3)
      write_word_both(32'h0000_0014, 32'h0022_0463); // BEQ x4, x2, +8
      write_word_both(32'h0000_0018, 32'h0010_0293); // ADDI x5, x0, 1
      write_word_both(32'h0000_001c, 32'h0022_1463); // BNE x4, x2, +8
      write_word_both(32'h0000_0020, 32'h0070_0293); // ADDI x5, x0, 7
      write_word_both(32'h0000_0024, 32'h0241_0333); // MUL x6, x2, x4
      write_word_both(32'h0000_0028, 32'h0053_03b3); // ADD x7, x6, x5
      write_word_both(32'h0000_002c, 32'h0071_9223); // SW x7, 4(x3)
      write_word_both(32'h0000_0030, 32'h0010_0073); // EBREAK
    end
  endtask

  function automatic commit_event_t sample_reference_commit;
    begin
      // Array occupancy records validity, so commit_valid is not stored in the event.
      sample_reference_commit = '0;
      sample_reference_commit.pc = ref_commit_pc;
      sample_reference_commit.instr = ref_commit_instr;
      sample_reference_commit.rd_write = ref_commit_rd_write;
      sample_reference_commit.rd_addr = ref_commit_rd_addr;
      sample_reference_commit.rd_wdata = ref_commit_rd_wdata;
      sample_reference_commit.mem_valid = ref_commit_mem_valid;
      sample_reference_commit.mem_write = ref_commit_mem_write;
      sample_reference_commit.mem_addr = ref_commit_mem_addr;
      sample_reference_commit.mem_rmask = ref_commit_mem_rmask;
      sample_reference_commit.mem_wmask = ref_commit_mem_wmask;
      sample_reference_commit.mem_rdata = ref_commit_mem_rdata;
      sample_reference_commit.mem_wdata = ref_commit_mem_wdata;
      sample_reference_commit.trap = ref_commit_trap;
      sample_reference_commit.trap_cause = ref_commit_trap_cause;
    end
  endfunction

  function automatic commit_event_t sample_pipeline_commit;
    begin
      // Keep this mapping symmetric with sample_reference_commit().
      sample_pipeline_commit = '0;
      sample_pipeline_commit.pc = pipe_commit_pc;
      sample_pipeline_commit.instr = pipe_commit_instr;
      sample_pipeline_commit.rd_write = pipe_commit_rd_write;
      sample_pipeline_commit.rd_addr = pipe_commit_rd_addr;
      sample_pipeline_commit.rd_wdata = pipe_commit_rd_wdata;
      sample_pipeline_commit.mem_valid = pipe_commit_mem_valid;
      sample_pipeline_commit.mem_write = pipe_commit_mem_write;
      sample_pipeline_commit.mem_addr = pipe_commit_mem_addr;
      sample_pipeline_commit.mem_rmask = pipe_commit_mem_rmask;
      sample_pipeline_commit.mem_wmask = pipe_commit_mem_wmask;
      sample_pipeline_commit.mem_rdata = pipe_commit_mem_rdata;
      sample_pipeline_commit.mem_wdata = pipe_commit_mem_wdata;
      sample_pipeline_commit.trap = pipe_commit_trap;
      sample_pipeline_commit.trap_cause = pipe_commit_trap_cause;
    end
  endfunction

  task automatic compare_commit_events(input commit_event_t expected, input commit_event_t actual, input int unsigned index);
    begin
      // Control fields are always compared. Register, memory, and trap payloads
      // are compared only when their corresponding valid condition is asserted.
      if (expected.pc !== actual.pc) begin
        $fatal(1, "Commit %0d: PC mismatch. Expected: 0x%08x, Actual: 0x%08x", index, expected.pc, actual.pc);
      end
      if (expected.instr !== actual.instr) begin
        $fatal(1, "Commit %0d: Instruction mismatch. Expected: 0x%08x, Actual: 0x%08x", index, expected.instr, actual.instr);
      end
      if (expected.rd_write !== actual.rd_write) begin
        $fatal(1, "Commit %0d: RD write mismatch. Expected: %0d, Actual: %0d", index, expected.rd_write, actual.rd_write);
      end
      if (expected.mem_valid !== actual.mem_valid) begin
        $fatal(1, "Commit %0d: MEM valid mismatch. Expected: %0d, Actual: %0d", index, expected.mem_valid, actual.mem_valid);
      end
      if (expected.trap !== actual.trap) begin
        $fatal(1, "Commit %0d: Trap mismatch. Expected: %0d, Actual: %0d", index, expected.trap, actual.trap);
      end
      if (expected.rd_write) begin
        if (expected.rd_addr !== actual.rd_addr) begin
          $fatal(1, "Commit %0d: RD address mismatch. Expected: 0x%02x, Actual: 0x%02x", index, expected.rd_addr, actual.rd_addr);
        end
        if (expected.rd_wdata !== actual.rd_wdata) begin
          $fatal(1, "Commit %0d: RD write data mismatch. Expected: 0x%08x, Actual: 0x%08x", index, expected.rd_wdata, actual.rd_wdata);
        end
      end
      if (expected.mem_valid) begin
        if (expected.mem_write !== actual.mem_write) begin
          $fatal(1, "Commit %0d: MEM write mismatch. Expected: %0d, Actual: %0d", index, expected.mem_write, actual.mem_write);
        end
        if (expected.mem_addr !== actual.mem_addr) begin
          $fatal(1, "Commit %0d: MEM address mismatch. Expected: 0x%08x, Actual: 0x%08x", index, expected.mem_addr, actual.mem_addr);
        end
        if (expected.mem_rmask !== actual.mem_rmask) begin
          $fatal(1, "Commit %0d: MEM read mask mismatch. Expected: 0x%01x, Actual: 0x%01x", index, expected.mem_rmask, actual.mem_rmask);
        end
        if (expected.mem_wmask !== actual.mem_wmask) begin
          $fatal(1, "Commit %0d: MEM write mask mismatch. Expected: 0x%01x, Actual: 0x%01x", index, expected.mem_wmask, actual.mem_wmask);
        end
        if (expected.mem_write) begin
          if (expected.mem_wdata !== actual.mem_wdata) begin
            $fatal(1, "Commit %0d: MEM write data mismatch. Expected: 0x%08x, Actual: 0x%08x", index, expected.mem_wdata, actual.mem_wdata);
          end
        end else begin
          if (expected.mem_rdata !== actual.mem_rdata) begin
            $fatal(1, "Commit %0d: MEM read data mismatch. Expected: 0x%08x, Actual: 0x%08x", index, expected.mem_rdata, actual.mem_rdata);
          end
        end
      end
      if (expected.trap && expected.trap_cause !== actual.trap_cause) begin
        $fatal(1, "Commit %0d: Trap cause mismatch. Expected: %0d, Actual: %0d", index, expected.trap_cause, actual.trap_cause);
      end
    end
  endtask

  // Sampling at the falling edge observes values after the cores' rising-edge
  // nonblocking assignments have settled and avoids a testbench/DUT race.
  always @(negedge clk) begin
    if (!rst) begin
      cycle_count = cycle_count + 1;

      // Capture each core independently because their commit cycles need not align.
      if (ref_commit_valid) begin
        if (ref_commit_count >= MAX_COMMITS) begin
          $fatal(1, "rv32_core_differential_tb: Reference commit overflow");
        end
        ref_events[ref_commit_count] = sample_reference_commit();
        ref_commit_count = ref_commit_count + 1;
      end

      if (pipe_commit_valid) begin
        if (pipe_commit_count >= MAX_COMMITS) begin
          $fatal(1, "rv32_core_differential_tb: Pipeline commit overflow");
        end
        pipe_events[pipe_commit_count] = sample_pipeline_commit();
        pipe_commit_count = pipe_commit_count + 1;
      end

      // Consume only retirement indices already produced by both cores.
      while (compared_count < ref_commit_count && compared_count < pipe_commit_count) begin
        compare_commit_events(ref_events[compared_count], pipe_events[compared_count], compared_count);
        compared_count++;
      end

      // Completion requires matching trace lengths, full comparison, the known
      // program signature, and normal trap termination by both cores.
      if (ref_halted && pipe_halted) begin
        if (ref_commit_count !== pipe_commit_count) begin
          $fatal(1, "Commit count mismatch: reference=%0d pipeline=%0d", ref_commit_count, pipe_commit_count);
        end
        if (compared_count !== ref_commit_count) begin
          $fatal(1, "Not all commits were compared: compared=%0d reference=%0d", compared_count, ref_commit_count);
        end
        if (ref_commit_count !== EXPECTED_COMMITS) begin
          $fatal(1, "Unexpected commit count: expected=%0d actual=%0d", EXPECTED_COMMITS, ref_commit_count);
        end
        if (reference_memory.read_word(32'h0000_0100) !== 32'd8 ||
            pipeline_memory.read_word(32'h0000_0100) !== 32'd8) begin
          $fatal(1, "Memory result at 0x100 is incorrect");
        end
        if (reference_memory.read_word(32'h0000_0104) !== 32'd71 ||
            pipeline_memory.read_word(32'h0000_0104) !== 32'd71) begin
          $fatal(1, "Signature result at 0x104 is incorrect");
        end
        $display("rv32_core_differential_tb: PASS - %0d commits compared in %0d cycles", compared_count, cycle_count);
        $finish;
      end else if (cycle_count >= MAX_CYCLES) begin
        $fatal(1, "Differential test timed out: reference commits=%0d pipeline commits=%0d compared=%0d", ref_commit_count, pipe_commit_count, compared_count);
      end
    end
  end

  initial begin
    rst = 1'b1;
    ref_commit_count = 0;
    pipe_commit_count = 0;
    compared_count = 0;
    cycle_count = 0;
    load_program();
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
  end

endmodule
