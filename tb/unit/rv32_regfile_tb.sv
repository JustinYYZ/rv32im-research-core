// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for rv32_regfile.
//
// Clocked inputs are driven on a falling edge and sampled by the DUT on the
// next rising edge. This gives the inputs half a clock period to settle and
// avoids a race between the testbench and the DUT.

`timescale 1ns/1ps

module rv32_regfile_tb;

  logic        clk;
  logic        rst;
  logic [4:0]  raddr1;
  logic [31:0] rdata1;
  logic [4:0]  raddr2;
  logic [31:0] rdata2;
  logic        we;
  logic [4:0]  waddr;
  logic [31:0] wdata;

  int unsigned errors;

  rv32_regfile dut (
    .clk_i    (clk),
    .rst_i    (rst),
    .raddr1_i (raddr1),
    .rdata1_o (rdata1),
    .raddr2_i (raddr2),
    .rdata2_o (rdata2),
    .we_i     (we),
    .waddr_i  (waddr),
    .wdata_i  (wdata)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Reads are combinational, so no clock edge is needed here. The #1 delay
  // gives both output ports time to react to their new addresses.
  task automatic check_dual(
    input string       test_name,
    input logic [4:0]  addr1,
    input logic [31:0] expected1,
    input logic [4:0]  addr2,
    input logic [31:0] expected2
  );
    begin
      raddr1 = addr1;
      raddr2 = addr2;
      #1;

      if (rdata1 !== expected1) begin
        $error(
          "Test %s port 1 failed: addr=%0d, expected=%h, got=%h",
          test_name, addr1, expected1, rdata1
        );
        errors++;
      end

      if (rdata2 !== expected2) begin
        $error(
          "Test %s port 2 failed: addr=%0d, expected=%h, got=%h",
          test_name, addr2, expected2, rdata2
        );
        errors++;
      end
    end
  endtask

  // Reset is synchronous. rst must therefore stay high across a rising edge;
  // setting it high for an arbitrary #1 delay would not guarantee a reset.
  task automatic reset_dut;
    begin
      @(negedge clk);
      rst = 1'b1;
      we  = 1'b0;

      @(posedge clk);
      #1;  // Wait for the DUT's nonblocking assignments to update storage.
      rst = 1'b0;
    end
  endtask

  // Set the write request at a falling edge so it is stable before the DUT
  // samples it at the following rising edge.
  task automatic write_reg(
    input logic [4:0]  addr,
    input logic [31:0] data
  );
    begin
      @(negedge clk);
      we    = 1'b1;
      waddr = addr;
      wdata = data;

      @(posedge clk);
      #1;
      we    = 1'b0;
      waddr = 5'd0;
      wdata = 32'd0;
    end
  endtask

  initial begin
    rst     = 1'b0;
    raddr1  = 5'd0;
    raddr2  = 5'd0;
    we      = 1'b0;
    waddr   = 5'd0;
    wdata   = 32'd0;
    errors  = 0;

    reset_dut();
    check_dual(
      "reset",
      5'd0,  32'd0,
      5'd31, 32'd0
    );

    write_reg(5'd1, 32'h1234_5678);
    write_reg(5'd2, 32'hcafe_babe);
    check_dual(
      "two independent read ports",
      5'd1, 32'h1234_5678,
      5'd2, 32'hcafe_babe
    );

    // Keep we low for a complete rising edge. If the DUT accidentally ignores
    // we, this attempted write would corrupt x1 and the following check fails.
    @(negedge clk);
    we    = 1'b0;
    waddr = 5'd1;
    wdata = 32'hdead_beef;
    @(posedge clk);
    #1;
    check_dual(
      "write enable low",
      5'd1, 32'h1234_5678,
      5'd2, 32'hcafe_babe
    );

    write_reg(5'd0, 32'hffff_ffff);
    check_dual(
      "x0 ignores writes",
      5'd0, 32'd0,
      5'd1, 32'h1234_5678
    );

    write_reg(5'd1, 32'h8765_4321);
    check_dual(
      "overwrite an existing register",
      5'd1, 32'h8765_4321,
      5'd2, 32'hcafe_babe
    );

    // Assert reset and write together before the same rising edge. Reading
    // zero afterwards proves that reset wins over the attempted write.
    @(negedge clk);
    rst   = 1'b1;
    we    = 1'b1;
    waddr = 5'd1;
    wdata = 32'h1111_1111;
    @(posedge clk);
    #1;
    rst = 1'b0;
    we  = 1'b0;
    check_dual(
      "reset priority and register clearing",
      5'd1, 32'd0,
      5'd2, 32'd0
    );

    if (errors == 0) begin
      $display("rv32_regfile_tb: PASS");
      $finish;
    end else begin
      $fatal(1, "rv32_regfile_tb: FAIL - %0d errors", errors);
    end
  end

endmodule
