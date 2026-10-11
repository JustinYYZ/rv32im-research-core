`timescale 1ns/1ps

module rv32_benchmark_memory #(
    parameter logic [31:0] PROGRAM_BASE = 32'haaaa_a000,
    parameter int unsigned PROGRAM_BYTES = 1024 * 1024,
    parameter logic [31:0] STACK_TOP = 32'hf000_0000,
    parameter int unsigned STACK_BYTES = 1024 * 1024
) (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic        imem_req_valid_i,
    output logic        imem_req_ready_o,
    input  logic [31:0] imem_req_addr_i,
    output logic        imem_resp_valid_o,
    output logic [31:0] imem_resp_data_o,
    output logic        imem_resp_error_o,

    input  logic        dmem_req_valid_i,
    output logic        dmem_req_ready_o,
    input  logic [31:0] dmem_req_addr_i,
    input  logic        dmem_req_write_i,
    input  logic [31:0] dmem_req_wdata_i,
    input  logic [3:0]  dmem_req_wstrb_i,
    output logic        dmem_resp_valid_o,
    output logic [31:0] dmem_resp_rdata_o,
    output logic        dmem_resp_error_o
);

  localparam int unsigned PROGRAM_WORDS = PROGRAM_BYTES / 4;
  localparam int unsigned STACK_WORDS = STACK_BYTES / 4;
  localparam logic [31:0] PROGRAM_LIMIT = PROGRAM_BASE + PROGRAM_BYTES;
  localparam logic [31:0] STACK_BASE = STACK_TOP - STACK_BYTES;

  logic [31:0] program_memory [0:PROGRAM_WORDS-1];
  logic [31:0] stack_memory [0:STACK_WORDS-1];

  logic        imem_pending_q;
  logic [31:0] imem_addr_q;

  logic        dmem_pending_q;
  logic [31:0] dmem_addr_q;
  logic        dmem_write_q;
  logic [31:0] dmem_wdata_q;
  logic [3:0]  dmem_wstrb_q;

  initial begin
    if (PROGRAM_BYTES == 0 || PROGRAM_BYTES % 4 != 0)
      $fatal(1, "PROGRAM_BYTES must be a non-zero multiple of four");

    if (STACK_BYTES == 0 || STACK_BYTES % 4 != 0)
      $fatal(1, "STACK_BYTES must be a non-zero multiple of four");
  end

  function automatic logic address_in_program(input logic [31:0] byte_addr);
    return byte_addr >= PROGRAM_BASE && byte_addr < PROGRAM_LIMIT;
  endfunction

  function automatic logic address_in_stack(input logic [31:0] byte_addr);
    return byte_addr >= STACK_BASE && byte_addr < STACK_TOP;
  endfunction

  function automatic logic address_is_mapped(input logic [31:0] byte_addr);
    return address_in_program(byte_addr) || address_in_stack(byte_addr);
  endfunction

  function automatic int unsigned program_index(input logic [31:0] byte_addr);
    return (byte_addr - PROGRAM_BASE) >> 2;
  endfunction

  function automatic int unsigned stack_index(input logic [31:0] byte_addr);
    return (byte_addr - STACK_BASE) >> 2;
  endfunction

  function automatic logic [31:0] merge_write_data(
      input logic [31:0] old_word,
      input logic [31:0] new_word,
      input logic [3:0]  write_strobe
  );
    logic [31:0] merged_word;

    merged_word = old_word;
    if (write_strobe[0]) merged_word[7:0]   = new_word[7:0];
    if (write_strobe[1]) merged_word[15:8]  = new_word[15:8];
    if (write_strobe[2]) merged_word[23:16] = new_word[23:16];
    if (write_strobe[3]) merged_word[31:24] = new_word[31:24];
    return merged_word;
  endfunction

  function automatic logic [31:0] read_word(input logic [31:0] byte_addr);
    if (byte_addr[1:0] != 2'b00) begin
      return 32'd0;
    end

    if (address_in_program(byte_addr)) begin
      return program_memory[program_index(byte_addr)];
    end

    if (address_in_stack(byte_addr)) begin
      return stack_memory[stack_index(byte_addr)];
    end

    return 32'd0;
  endfunction

  task automatic write_word(
      input logic [31:0] byte_addr,
      input logic [31:0] word_data
  );
    if (byte_addr[1:0] != 2'b00 || !address_is_mapped(byte_addr)) begin
      $fatal(1, "write_word address is invalid: 0x%08h", byte_addr);
    end

    if (address_in_program(byte_addr)) begin
      program_memory[program_index(byte_addr)] = word_data;
    end else begin
      stack_memory[stack_index(byte_addr)] = word_data;
    end
  endtask

  task automatic clear_memory;
    for (int unsigned index = 0; index < PROGRAM_WORDS; index++) begin
      program_memory[index] = 32'd0;
    end

    for (int unsigned index = 0; index < STACK_WORDS; index++) begin
      stack_memory[index] = 32'd0;
    end
  endtask

  task automatic load_memh(input string filename);
    integer file_descriptor;
    integer scan_result;
    integer loaded_words;
    string token;
    logic [31:0] current_word_address;
    logic [31:0] word_data;
    logic have_address;

    file_descriptor = $fopen(filename, "r");
    if (file_descriptor == 0) begin
      $fatal(1, "Unable to open memory image: %0s", filename);
    end

    loaded_words = 0;
    have_address = 1'b0;

    while (!$feof(file_descriptor)) begin
      scan_result = $fscanf(file_descriptor, "%s", token);

      if (scan_result == 1) begin
        if ($sscanf(token, "@%h", current_word_address) == 1) begin
          have_address = 1'b1;
        end else if ($sscanf(token, "%h", word_data) == 1) begin
          if (!have_address) begin
            $fatal(1, "Memory data appears before an address directive");
          end

          write_word(current_word_address << 2, word_data);
          current_word_address = current_word_address + 1;
          loaded_words = loaded_words + 1;
        end else begin
          $fatal(1, "Invalid token in memory image: %0s", token);
        end
      end
    end

    $fclose(file_descriptor);
    $display("rv32_benchmark_memory: loaded %0d words from %0s", loaded_words, filename);
  endtask

  assign imem_req_ready_o = !imem_pending_q;
  assign dmem_req_ready_o = !dmem_pending_q;

  always_ff @(posedge clk_i) begin
    imem_resp_valid_o <= 1'b0;
    imem_resp_data_o <= 32'd0;
    imem_resp_error_o <= 1'b0;

    dmem_resp_valid_o <= 1'b0;
    dmem_resp_rdata_o <= 32'd0;
    dmem_resp_error_o <= 1'b0;

    if (rst_i) begin
      imem_pending_q <= 1'b0;
      imem_addr_q <= 32'd0;

      dmem_pending_q <= 1'b0;
      dmem_addr_q <= 32'd0;
      dmem_write_q <= 1'b0;
      dmem_wdata_q <= 32'd0;
      dmem_wstrb_q <= 4'd0;
    end else begin
      if (imem_pending_q) begin
        imem_resp_valid_o <= 1'b1;
        imem_pending_q <= 1'b0;

        if (imem_addr_q[1:0] != 2'b00 || !address_is_mapped(imem_addr_q)) begin
          imem_resp_error_o <= 1'b1;
        end else begin
          imem_resp_data_o <= read_word(imem_addr_q);
        end
      end else if (imem_req_valid_i && imem_req_ready_o) begin
        imem_pending_q <= 1'b1;
        imem_addr_q <= imem_req_addr_i;
      end

      if (dmem_pending_q) begin
        dmem_resp_valid_o <= 1'b1;
        dmem_pending_q <= 1'b0;

        if (dmem_addr_q[1:0] != 2'b00 || !address_is_mapped(dmem_addr_q)) begin
          dmem_resp_error_o <= 1'b1;
        end else if (dmem_write_q) begin
          if (address_in_program(dmem_addr_q)) begin
            program_memory[program_index(dmem_addr_q)] <= merge_write_data(program_memory[program_index(dmem_addr_q)], dmem_wdata_q, dmem_wstrb_q);
          end else begin
            stack_memory[stack_index(dmem_addr_q)] <= merge_write_data(stack_memory[stack_index(dmem_addr_q)], dmem_wdata_q, dmem_wstrb_q);
          end
        end else begin
          dmem_resp_rdata_o <= read_word(dmem_addr_q);
        end
      end else if (dmem_req_valid_i && dmem_req_ready_o) begin
        dmem_pending_q <= 1'b1;
        dmem_addr_q <= dmem_req_addr_i;
        dmem_write_q <= dmem_req_write_i;
        dmem_wdata_q <= dmem_req_wdata_i;
        dmem_wstrb_q <= dmem_req_wstrb_i;
      end
    end
  end

endmodule