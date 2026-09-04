// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for the out-of-order physical register file. The
// regression covers ready-state allocation, completion writeback, dual-port
// reads, p0 invariants, and same-register allocation/writeback priority.

`timescale 1ns/1ps

module rv32_phys_regfile_tb;
  import rv32_ooo_pkg::*;

  int unsigned errors;

  logic           clk;
  logic           rst;
  phys_reg_idx_t  raddr1;
  logic [31:0]    rdata1;
  logic           rready1;
  phys_reg_idx_t  raddr2;
  logic [31:0]    rdata2;
  logic           rready2;
  logic           alloc_valid;
  phys_reg_idx_t  alloc_addr;
  logic           wb_valid;
  phys_reg_idx_t  wb_addr;
  logic [31:0]    wb_data;

  rv32_phys_regfile dut (
    .clk_i(clk),
    .rst_i(rst),
    .raddr1_i(raddr1),
    .rdata1_o(rdata1),
    .rready1_o(rready1),
    .raddr2_i(raddr2),
    .rdata2_o(rdata2),
    .rready2_o(rready2),
    .alloc_valid_i(alloc_valid),
    .alloc_addr_i(alloc_addr),
    .wb_valid_i(wb_valid),
    .wb_addr_i(wb_addr),
    .wb_data_i(wb_data)
  );

  initial begin
    clk = 0;
    forever #5 clk = ~clk; // 10 ns clock period
  end

  task automatic reset_dut;
    begin
      // Drive synchronous controls before the active edge and sample state after
      // nonblocking assignments have settled.
      @(negedge clk);
      rst = 1'b1;
      alloc_valid = 1'b0;
      wb_valid = 1'b0;
      @(posedge clk);
      #1;
      rst = 1'b0;
    end
  endtask

  task automatic check_dual(
    input string test_name,
    input phys_reg_idx_t addr1,
    input logic [31:0] expected_data1,
    input logic expected_ready1,
    input phys_reg_idx_t addr2,
    input logic [31:0] expected_data2,
    input logic expected_ready2
  );
    begin
      // A not-ready entry has no consumable data, so only ready is checked until
      // a writeback publishes the value.
      raddr1 = addr1;
      raddr2 = addr2;
      #1;
      if (rready1 !== expected_ready1) begin
        $display("%s: ERROR - port 1 ready=%0b, expected %0b", test_name, rready1, expected_ready1);
        errors++;
      end
      if (expected_ready1 && rdata1 !== expected_data1) begin
        $display("%s: ERROR - port 1 data=%08h, expected %08h", test_name, rdata1, expected_data1);
        errors++;
      end
      if (rready2 !== expected_ready2) begin
        $display("%s: ERROR - port 2 ready=%0b, expected %0b", test_name, rready2, expected_ready2);
        errors++;
      end
      if (expected_ready2 && rdata2 !== expected_data2) begin
        $display("%s: ERROR - port 2 data=%08h, expected %08h", test_name, rdata2, expected_data2);
        errors++;
      end
    end
  endtask

  task automatic allocate_reg(
    input phys_reg_idx_t addr
  );
    begin
      @(negedge clk);
      wb_valid = 1'b0;
      alloc_valid = 1'b1;
      alloc_addr = addr;
      @(posedge clk);
      #1;
      @(negedge clk);
      alloc_valid = 1'b0;
      alloc_addr = '0;
    end
  endtask

  task automatic writeback_reg(
    input phys_reg_idx_t addr,
    input logic [31:0] data
  );
    begin
      @(negedge clk);
      alloc_valid = 1'b0;
      wb_valid = 1'b1;
      wb_addr = addr;
      wb_data = data;
      @(posedge clk);
      #1;
      @(negedge clk);
      wb_valid = 1'b0;
      wb_addr = '0;
      wb_data = '0;
    end
  endtask

  initial begin
    rst = 1'b0;
    raddr1 = '0;
    raddr2 = '0;
    alloc_valid = 1'b0;
    alloc_addr = '0;
    wb_valid = 1'b0;
    wb_addr = '0;
    wb_data = '0;
    errors = 0;

    reset_dut();
    check_dual("reset p0 invariant", '0, 32'b0, 1'b1, '0, 32'b0, 1'b1);

    // Allocation hides stale array contents until each new result is written.
    allocate_reg(phys_reg_idx_t'(5));
    allocate_reg(phys_reg_idx_t'(17));
    check_dual("allocate registers", phys_reg_idx_t'(5), 32'b0, 1'b0, phys_reg_idx_t'(17), 32'b0, 1'b0);
    writeback_reg(phys_reg_idx_t'(5), 32'h11aa);
    check_dual("writeback reg 5", phys_reg_idx_t'(5), 32'h11aa, 1'b1, phys_reg_idx_t'(17), 32'b0, 1'b0);
    writeback_reg(phys_reg_idx_t'(17), 32'h22bb);
    check_dual("writeback reg 17", phys_reg_idx_t'(5), 32'h11aa, 1'b1, phys_reg_idx_t'(17), 32'h22bb, 1'b1);

    // Neither allocation nor writeback may alter the hardwired p0 behavior.
    allocate_reg(phys_reg_idx_t'(0));
    check_dual("allocate p0 ignore", phys_reg_idx_t'(0), 32'b0, 1'b1, phys_reg_idx_t'(5), 32'h11aa, 1'b1);
    writeback_reg(phys_reg_idx_t'(0), 32'hdead_beef);
    check_dual("writeback p0 ignore", phys_reg_idx_t'(0), 32'b0, 1'b1, phys_reg_idx_t'(17), 32'h22bb, 1'b1);

    // A same-address allocation represents a new producer, so it must override
    // writeback readiness from the value completing on the same edge.
    @(negedge clk);
    alloc_valid = 1'b1;
    alloc_addr = phys_reg_idx_t'(23);
    wb_valid = 1'b1;
    wb_addr = phys_reg_idx_t'(23);
    wb_data = 32'h33cc;
    @(posedge clk);
    #1;
    check_dual("same cycle allocation priority", phys_reg_idx_t'(23), 32'b0, 1'b0, phys_reg_idx_t'(0), 32'b0, 1'b1);
    @(negedge clk);
    alloc_valid = 1'b0;
    alloc_addr = '0;
    wb_valid = 1'b0;
    wb_addr = '0;
    wb_data = '0;

    if (errors == 0) begin
      $display("rv32_phys_regfile_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_phys_regfile_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
