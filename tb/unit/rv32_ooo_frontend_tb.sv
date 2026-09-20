// SPDX-License-Identifier: Apache-2.0
//
// Self-checking unit test for sequential fetch requests, I-cache backpressure,
// delayed responses, Fetch Queue flow control, and redirect recovery.

`timescale 1ns/1ps

module rv32_ooo_frontend_tb;
  import rv32_ooo_pkg::*;

  localparam logic [31:0] RESET_PC = 32'h0000_1000;

  logic         clk;
  logic         rst;
  logic         redirect_valid;
  logic [31:0]  redirect_pc;
  logic         icache_req_valid;
  logic         icache_req_ready;
  logic [31:0]  icache_req_addr;
  logic         icache_resp_valid;
  logic [31:0]  icache_resp_data;
  logic         icache_resp_error;
  logic         fetch_valid;
  logic         fetch_ready;
  fetch_entry_t fetch_entry;
  int unsigned  errors;

  rv32_ooo_frontend #(
    .RESET_PC(RESET_PC)
  ) dut (
    .clk_i(clk),
    .rst_i(rst),
    .halt_i(1'b0),
    .redirect_valid_i(redirect_valid),
    .redirect_pc_i(redirect_pc),
    .icache_req_valid_o(icache_req_valid),
    .icache_req_ready_i(icache_req_ready),
    .icache_req_addr_o(icache_req_addr),
    .icache_resp_valid_i(icache_resp_valid),
    .icache_resp_data_i(icache_resp_data),
    .icache_resp_error_i(icache_resp_error),
    .fetch_valid_o(fetch_valid),
    .fetch_ready_i(fetch_ready),
    .fetch_entry_o(fetch_entry)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Shared stimulus and checking helpers.
  task automatic drive_idle;
    begin
      redirect_valid = 1'b0;
      redirect_pc = '0;
      icache_req_ready = 1'b0;
      icache_resp_valid = 1'b0;
      icache_resp_data = '0;
      icache_resp_error = 1'b0;
      fetch_ready = 1'b0;
    end
  endtask

  task automatic reset_dut;
    begin
      @(negedge clk);
      drive_idle();
      rst = 1'b1;

      @(posedge clk);
      #1;
      if (icache_req_valid !== 1'b0) begin
        $error("reset: request valid must be zero");
        errors++;
      end

      rst = 1'b0;
      #1;
    end
  endtask

  task automatic check_request(
    input string test_name,
    input logic expected_valid,
    input logic [31:0] expected_addr
  );
    begin
      if (icache_req_valid !== expected_valid) begin
        $error("%s: expected request valid %b, got %b", test_name, expected_valid, icache_req_valid);
        errors++;
      end

      if (icache_req_addr !== expected_addr) begin
        $error("%s: expected request address %08h, got %08h", test_name, expected_addr, icache_req_addr);
        errors++;
      end
    end
  endtask

  task automatic check_no_request(
    input string test_name
  );
    begin
      if (icache_req_valid !== 1'b0) begin
        $error("%s: expected no request valid, got %b", test_name, icache_req_valid);
        errors++;
      end
    end
  endtask

  task automatic check_fetch_entry(
    input string test_name,
    input fetch_entry_t expected_entry
  );
    begin
      if (fetch_valid !== 1'b1) begin
        $error("%s: expected fetch valid 1, got %b", test_name, fetch_valid);
        errors++;
      end else if (fetch_entry !== expected_entry) begin
        $error("%s: expected fetch entry %p, got %p", test_name, expected_entry, fetch_entry);
        errors++;
      end
    end
  endtask

  task automatic accept_request(
    input string test_name,
    input logic [31:0] expected_addr
  );
    begin
      @(negedge clk);
      icache_req_ready = 1'b1;
      #1;
      check_request(test_name, 1'b1, expected_addr);

      @(posedge clk);
      #1;
      icache_req_ready = 1'b0;

      if (dut.outstanding_q !== 1'b1) begin
        $error("%s: outstanding request was not recorded", test_name);
        errors++;
      end
    end
  endtask

  task automatic return_response(
    input logic [31:0] instr,
    input logic access_fault
  );
    begin
      @(negedge clk);
      icache_resp_valid = 1'b1;
      icache_resp_data = instr;
      icache_resp_error = access_fault;

      @(posedge clk);
      #1;
      icache_resp_valid = 1'b0;

      if (dut.outstanding_q !== 1'b0) begin
        $error("response: outstanding request was not cleared");
        errors++;
      end
    end
  endtask

  // Requests remain stable under I-cache backpressure and stop while one is outstanding.
  task automatic test_request_backpressure;
    integer cycle;
    begin
      for (cycle = 0; cycle < 2; cycle++) begin
        @(posedge clk);
        #1;
        check_request("request held during backpressure", 1'b1, RESET_PC);
      end

      @(negedge clk);
      icache_req_ready = 1'b1;
      #1;
      check_request("request before handshake", 1'b1, RESET_PC);

      @(posedge clk);
      #1;
      icache_req_ready = 1'b0;

      if (icache_req_valid !== 1'b0) begin
        $error("handshake: a second request must not be issued while one is outstanding");
        errors++;
      end

      if (dut.request_pc_q !== RESET_PC) begin
        $error("handshake: expected saved request PC %08h, got %08h", RESET_PC, dut.request_pc_q);
        errors++;
      end

      if (dut.pc_q !== RESET_PC + 32'd4) begin
        $error("handshake: expected next PC %08h, got %08h", RESET_PC + 32'd4, dut.pc_q);
        errors++;
      end

      if (dut.outstanding_q !== 1'b1) begin
        $error("handshake: outstanding request was not recorded");
        errors++;
      end

      @(posedge clk);
      #1;
      if (icache_req_valid !== 1'b0) begin
        $error("outstanding: request valid must remain zero before response");
        errors++;
      end
    end
  endtask

  // A delayed response retains its request PC and advances sequential fetching by four.
  task automatic test_delayed_response;
    fetch_entry_t expected_entry;
    begin
      repeat (2) begin
        @(posedge clk);
        #1;
        check_no_request("delayed response: no request while outstanding");

        if (fetch_valid !== 1'b0) begin
          $error("delayed response: fetch valid must be zero before response");
          errors++;
        end
      end

      expected_entry = '0;
      expected_entry.pc = RESET_PC;
      expected_entry.instr = 32'h0010_0093;
      expected_entry.predicted_next_pc = RESET_PC + 32'd4;
      expected_entry.access_fault = 1'b0;

      @(negedge clk);
      icache_resp_valid = 1'b1;
      icache_resp_data = 32'h0010_0093;
      icache_resp_error = 1'b0;

      @(posedge clk);
      #1;
      check_fetch_entry("delayed response", expected_entry);

      if (dut.outstanding_q !== 1'b0) begin
        $error("delayed response: outstanding request was not cleared");
        errors++;
      end

      check_request("delayed response: next request after response", 1'b1, RESET_PC + 32'd4);

      @(negedge clk);
      icache_resp_valid = 1'b0;
      fetch_ready = 1'b1;

      @(posedge clk);
      #1;
      fetch_ready = 1'b0;

      if (fetch_valid !== 1'b0) begin
        $error("delayed response: fetch valid must be zero after ready handshake");
        errors++;
      end
    end
  endtask

  // A full Fetch Queue applies backpressure to instruction requests.
  task automatic test_fetch_queue_full;
    int entry_idx;
    logic [31:0] expected_pc;
    begin
      fetch_ready = 1'b0;
      expected_pc = RESET_PC + 32'd4;

      for (entry_idx = 0; entry_idx < FETCH_QUEUE_ENTRIES; entry_idx++) begin
        accept_request("fill fetch queue", expected_pc);
        return_response(32'h0000_0013, 1'b0);
        expected_pc += 32'd4;
      end

      if (dut.queue_full !== 1'b1) begin
        $error("full queue: queue_full was not asserted");
        errors++;
      end

      if (dut.queue_count !== FETCH_QUEUE_ENTRIES) begin
        $error("full queue: queue_count %0d does not match expected depth %0d", dut.queue_count, FETCH_QUEUE_ENTRIES);
        errors++;
      end

      check_no_request("full fetch queue");
      @(posedge clk);
      #1;
      check_no_request("full fetch queue remains blocked");
    end
  endtask

  // Redirect flushes queued work and restarts fetching at the recovery PC.
  task automatic test_redirect_flush;
    logic old_epoch;
    begin
      old_epoch = dut.epoch_q;

      @(negedge clk);
      redirect_valid = 1'b1;
      redirect_pc = 32'h0000_2000;

      @(posedge clk);
      #1;

      if (dut.pc_q !== 32'h0000_2000) begin
        $error("redirect flush: pc_q was not updated to redirect_pc_i");
        errors++;
      end

      if (dut.epoch_q !== ~old_epoch) begin
        $error("redirect flush: epoch_q was not toggled");
        errors++;
      end

      if (dut.queue_empty !== 1'b1 || dut.queue_count !== 0) begin
        $error("redirect flush: queue_empty was not asserted");
        errors++;
      end

      if (fetch_valid !== 1'b0) begin
        $error("redirect flush: fetch_valid must be zero after redirect");
        errors++;
      end

      check_no_request("redirect flush: no request after redirect");

      @(negedge clk);
      redirect_valid = 1'b0;
      #1;
      check_request("redirect flush: next request after redirect", 1'b1, 32'h0000_2000);

      accept_request("redirect flush: accept redirected request", 32'h0000_2000);

      if (dut.request_pc_q !== 32'h0000_2000) begin
        $error("redirect flush: request_pc_q was not updated to redirect_pc_i");
        errors++;
      end
    end
  endtask

  // An outstanding response from the old epoch is discarded after redirect.
  task automatic test_stale_response;
    logic old_epoch;
    begin
      old_epoch = dut.epoch_q;

      if (dut.outstanding_q !== 1'b1) begin
        $error("stale response: expected an outstanding request before redirect");
        errors++;
      end

      @(negedge clk);
      redirect_valid = 1'b1;
      redirect_pc = 32'h0000_3000;

      @(posedge clk);
      #1;

      if (dut.pc_q !== 32'h0000_3000) begin
        $error("stale response: pc_q was not updated to redirect_pc_i");
        errors++;
      end

      if (dut.epoch_q !== ~old_epoch) begin
        $error("stale response: epoch_q was not toggled");
        errors++;
      end

      if (dut.outstanding_q !== 1'b1) begin
        $error("stale response: outstanding request was cleared by redirect");
        errors++;
      end

      if (dut.request_epoch_q !== old_epoch || dut.request_epoch_q === dut.epoch_q) begin
        $error("stale response: request_epoch_q was not preserved after redirect");
        errors++;
      end

      @(negedge clk);
      redirect_valid = 1'b0;
      #1;
      check_no_request("waiting for stale response");
      return_response(32'hdead_beef, 1'b0);
      if (fetch_valid !== 1'b0 || dut.queue_count !== '0) begin
        $error("stale response: fetch_valid must be zero after stale response");
        errors++;
      end
      check_request("stale response: next request after redirect", 1'b1, 32'h0000_3000);
      accept_request("stale response: accept redirected request", 32'h0000_3000);
    end
  endtask

  // Access faults remain attached to the returned instruction request.
  task automatic test_access_fault_response;
    fetch_entry_t expected_entry;
    begin
      expected_entry = '0;
      expected_entry.pc = 32'h0000_3000;
      expected_entry.instr = 32'h0000_0000;
      expected_entry.predicted_next_pc = 32'h0000_3004;
      expected_entry.access_fault = 1'b1;

      return_response(32'h0000_0000, 1'b1);
      check_fetch_entry("access fault: fetch entry with access fault", expected_entry);

      @(negedge clk);
      fetch_ready = 1'b1;
      @(posedge clk);
      #1;
      fetch_ready = 1'b0;

      if (fetch_valid !== 1'b0) begin
        $error("access fault: fetch_valid must be zero after ready handshake");
        errors++;
      end
      accept_request("access fault: next request after access fault", 32'h0000_3004);
    end
  endtask

  // Redirect wins when a response and recovery arrive in the same cycle.
  task automatic test_response_with_redirect;
    logic old_epoch;
    begin
      old_epoch = dut.epoch_q;

      @(negedge clk);
      redirect_valid = 1'b1;
      redirect_pc = 32'h0000_4000;
      icache_resp_valid = 1'b1;
      icache_resp_data = 32'hcafebabe;
      icache_resp_error = 1'b0;

      @(posedge clk);
      #1;

      if (dut.pc_q !== 32'h0000_4000) begin
        $error("response with redirect: pc_q was not updated to redirect_pc_i");
        errors++;
      end

      if (dut.epoch_q !== ~old_epoch) begin
        $error("response with redirect: epoch_q was not toggled");
        errors++;
      end

      if (dut.outstanding_q !== 1'b0) begin
        $error("response with redirect: returned request remained outstanding");
        errors++;
      end

      if (fetch_valid !== 1'b0 || dut.queue_count !== '0) begin
        $error("response with redirect: fetch_valid must be zero after stale response");
        errors++;
      end

      check_no_request("response with redirect: no request during redirect");

      @(negedge clk);
      redirect_valid = 1'b0;
      icache_resp_valid = 1'b0;
      #1;

      check_request("response with redirect: next request after redirect", 1'b1, 32'h0000_4000);
    end
  endtask

  initial begin
    rst = 1'b0;
    drive_idle();
    errors = 0;

    reset_dut();

    check_request("first request after reset", 1'b1, RESET_PC);

    if (fetch_valid !== 1'b0) begin
      $error("reset: Fetch Queue must be empty");
      errors++;
    end

    test_request_backpressure();
    test_delayed_response();
    test_fetch_queue_full();
    test_redirect_flush();
    test_stale_response();
    test_access_fault_response();
    test_response_with_redirect();

    if (errors != 0)
      $fatal(1, "rv32_ooo_frontend_tb failed with %0d errors", errors);
    $display("rv32_ooo_frontend_tb: PASS");
    $finish;
  end

endmodule
