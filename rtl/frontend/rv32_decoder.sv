// SPDX-License-Identifier: Apache-2.0
//
// RV32I instruction decoder.
//
// Current support includes RV32I integer ALU, control-flow, and load/store
// instructions, plus LUI, AUIPC, and EBREAK.
// The decoder extracts register addresses and converts instruction encoding
// fields into internal control signals. It does not read registers, calculate
// results, update the PC, or write architectural state.
//
// Outputs start at safe defaults. Unsupported or reserved encodings therefore
// leave illegal_o asserted without enabling register or memory side effects.

`timescale 1ns/1ps

module rv32_decoder (
    input  logic [31:0]                 instr_i,

    output logic [4:0]                  rs1_addr_o,
    output logic [4:0]                  rs2_addr_o,
    output logic [4:0]                  rd_addr_o,
    output logic                        rs1_used_o,
    output logic                        rs2_used_o,

    output rv32_pkg::alu_op_e           alu_op_o,
    output rv32_pkg::operand_a_sel_e    operand_a_sel_o,
    output rv32_pkg::operand_b_sel_e    operand_b_sel_o,
    output rv32_pkg::imm_kind_e         imm_kind_o,

    output rv32_pkg::branch_op_e        branch_op_o,
    output rv32_pkg::control_flow_e     control_flow_o,
    output rv32_pkg::writeback_sel_e    writeback_sel_o,

    output rv32_pkg::mem_op_e           mem_op_o,
    output rv32_pkg::mem_size_e         mem_size_o,
    output logic                        load_unsigned_o,

    output logic                        reg_write_o,
    output logic                        ebreak_o,
    output logic                        illegal_o
);

  // These fields are shared by the supported R- and I-type encodings.
  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic       branch_valid;

  assign funct7     = instr_i[31:25];
  assign rs2_addr_o = instr_i[24:20];
  assign rs1_addr_o = instr_i[19:15];
  assign funct3     = instr_i[14:12];
  assign rd_addr_o  = instr_i[11:7];
  assign opcode     = instr_i[6:0];

  always_comb begin
    rs1_used_o = 1'b0;
    rs2_used_o = 1'b0;
    alu_op_o = rv32_pkg::ALU_ADD;
    operand_a_sel_o = rv32_pkg::OP_A_ZERO;
    operand_b_sel_o = rv32_pkg::OP_B_RS2;
    imm_kind_o = rv32_pkg::IMM_NONE;
    branch_valid = 1'b0;

    branch_op_o = rv32_pkg::BR_EQ;
    control_flow_o = rv32_pkg::CF_NONE;
    writeback_sel_o = rv32_pkg::WB_ALU;

    // MEM_BYTE is only a placeholder while MEM_NONE is selected. Keeping every
    // output deterministic avoids latches and makes illegal decode safe.
    mem_op_o = rv32_pkg::MEM_NONE;
    mem_size_o = rv32_pkg::MEM_BYTE;
    load_unsigned_o = 1'b0;

    reg_write_o = 1'b0;
    ebreak_o = 1'b0;
    illegal_o = 1'b1;

    case(opcode)
      rv32_pkg::OPCODE_OP: begin
        case(funct3)
          3'b000: begin
            if(funct7 == 7'b0000000) begin
              alu_op_o = rv32_pkg::ALU_ADD;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_RS2;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;
              illegal_o = 1'b0;
            end else if(funct7 == 7'b0100000) begin
              alu_op_o = rv32_pkg::ALU_SUB;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_RS2;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;
              illegal_o = 1'b0;
            end
          end
          3'b001: begin
            if(funct7 == 7'b0000000) begin
              alu_op_o = rv32_pkg::ALU_SLL;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_RS2;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;
              illegal_o = 1'b0;
            end
          end
          3'b010: begin
            if(funct7 == 7'b0000000) begin
              alu_op_o = rv32_pkg::ALU_SLT;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_RS2;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;
              illegal_o = 1'b0;
            end
          end
          3'b011: begin
            if(funct7 == 7'b0000000) begin
              alu_op_o = rv32_pkg::ALU_SLTU;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_RS2;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;
              illegal_o = 1'b0;
            end
          end
          3'b100: begin
            if(funct7 == 7'b0000000) begin
              alu_op_o = rv32_pkg::ALU_XOR;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_RS2;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;
              illegal_o = 1'b0;
            end
          end
          3'b101: begin
            if(funct7 == 7'b0000000) begin
              alu_op_o = rv32_pkg::ALU_SRL;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_RS2;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;
              illegal_o = 1'b0;
            end
            if(funct7 == 7'b0100000) begin
              alu_op_o = rv32_pkg::ALU_SRA;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_RS2;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;
              illegal_o = 1'b0;
            end
          end
          3'b110: begin
            if(funct7 == 7'b0000000) begin
              alu_op_o = rv32_pkg::ALU_OR;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_RS2;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;
              illegal_o = 1'b0;
            end
          end
          3'b111: begin
            if(funct7 == 7'b0000000) begin
              alu_op_o = rv32_pkg::ALU_AND;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_RS2;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              rs2_used_o = 1'b1;
              illegal_o = 1'b0;
            end
          end
        endcase
      end
      rv32_pkg::OPCODE_OP_IMM: begin
        case(funct3)
          3'b000: begin
            alu_op_o = rv32_pkg::ALU_ADD;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b010: begin
            alu_op_o = rv32_pkg::ALU_SLT;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b011: begin
            alu_op_o = rv32_pkg::ALU_SLTU;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b100: begin
            alu_op_o = rv32_pkg::ALU_XOR;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b110: begin
            alu_op_o = rv32_pkg::ALU_OR;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b111: begin
            alu_op_o = rv32_pkg::ALU_AND;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b001: begin
            if(funct7 == 7'b0000000) begin
              alu_op_o = rv32_pkg::ALU_SLL;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_IMM;
              imm_kind_o = rv32_pkg::IMM_I;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              illegal_o = 1'b0;
            end
          end
          3'b101: begin
            if(funct7 == 7'b0000000) begin
              alu_op_o = rv32_pkg::ALU_SRL;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_IMM;
              imm_kind_o = rv32_pkg::IMM_I;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              illegal_o = 1'b0;
            end else if(funct7 == 7'b0100000) begin
              alu_op_o = rv32_pkg::ALU_SRA;
              operand_a_sel_o = rv32_pkg::OP_A_RS1;
              operand_b_sel_o = rv32_pkg::OP_B_IMM;
              imm_kind_o = rv32_pkg::IMM_I;
              reg_write_o = 1'b1;
              rs1_used_o = 1'b1;
              illegal_o = 1'b0;
            end
          end
        endcase
      end
      rv32_pkg::OPCODE_LUI: begin
        operand_a_sel_o = rv32_pkg::OP_A_ZERO;
        operand_b_sel_o = rv32_pkg::OP_B_IMM;
        imm_kind_o = rv32_pkg::IMM_U;
        reg_write_o = 1'b1;
        illegal_o = 1'b0;
      end
      rv32_pkg::OPCODE_AUIPC: begin
        operand_a_sel_o = rv32_pkg::OP_A_PC;
        operand_b_sel_o = rv32_pkg::OP_B_IMM;
        imm_kind_o = rv32_pkg::IMM_U;
        reg_write_o = 1'b1;
        illegal_o = 1'b0;
      end
      rv32_pkg::OPCODE_SYSTEM: begin
        if(instr_i == 32'h00100073) begin // EBREAK instruction encoding
          ebreak_o = 1'b1;
          illegal_o = 1'b0;
        end
      end
      // Loads use rs1 + I-type immediate as the byte address and write the
      // formatted memory result to rd.
      rv32_pkg::OPCODE_LOAD: begin
        case(funct3)
          3'b000: begin
            mem_op_o = rv32_pkg::MEM_LOAD;
            mem_size_o = rv32_pkg::MEM_BYTE;
            load_unsigned_o = 1'b0;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            writeback_sel_o = rv32_pkg::WB_MEM;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b001: begin
            mem_op_o = rv32_pkg::MEM_LOAD;
            mem_size_o = rv32_pkg::MEM_HALF;
            load_unsigned_o = 1'b0;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            writeback_sel_o = rv32_pkg::WB_MEM;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b010: begin
            mem_op_o = rv32_pkg::MEM_LOAD;
            mem_size_o = rv32_pkg::MEM_WORD;
            load_unsigned_o = 1'b0;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            writeback_sel_o = rv32_pkg::WB_MEM;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b100: begin
            mem_op_o = rv32_pkg::MEM_LOAD;
            mem_size_o = rv32_pkg::MEM_BYTE;
            load_unsigned_o = 1'b1;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            writeback_sel_o = rv32_pkg::WB_MEM;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b101: begin
            mem_op_o = rv32_pkg::MEM_LOAD;
            mem_size_o = rv32_pkg::MEM_HALF;
            load_unsigned_o = 1'b1;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_I;
            writeback_sel_o = rv32_pkg::WB_MEM;
            reg_write_o = 1'b1;
            rs1_used_o = 1'b1;
            illegal_o = 1'b0;
          end
        endcase
      end
      // Stores use rs1 + S-type immediate as the byte address and rs2 as write
      // data. They never write an architectural destination register.
      rv32_pkg::OPCODE_STORE: begin
        case(funct3)
          3'b000: begin
            mem_op_o = rv32_pkg::MEM_STORE;
            mem_size_o = rv32_pkg::MEM_BYTE;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_S;
            rs1_used_o = 1'b1;
            rs2_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b001: begin
            mem_op_o = rv32_pkg::MEM_STORE;
            mem_size_o = rv32_pkg::MEM_HALF;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_S;
            rs1_used_o = 1'b1;
            rs2_used_o = 1'b1;
            illegal_o = 1'b0;
          end
          3'b010: begin
            mem_op_o = rv32_pkg::MEM_STORE;
            mem_size_o = rv32_pkg::MEM_WORD;
            operand_a_sel_o = rv32_pkg::OP_A_RS1;
            operand_b_sel_o = rv32_pkg::OP_B_IMM;
            imm_kind_o = rv32_pkg::IMM_S;
            rs1_used_o = 1'b1;
            rs2_used_o = 1'b1;
            illegal_o = 1'b0;
          end
        endcase
      end

      rv32_pkg::OPCODE_BRANCH: begin
        case(funct3)
          3'b000: begin
            branch_op_o = rv32_pkg::BR_EQ;
            branch_valid = 1'b1;
          end
          3'b001: begin
            branch_op_o = rv32_pkg::BR_NE;
            branch_valid = 1'b1;
          end
          3'b100: begin
            branch_op_o = rv32_pkg::BR_LT;
            branch_valid = 1'b1;
          end
          3'b101: begin
            branch_op_o = rv32_pkg::BR_GE;
            branch_valid = 1'b1;
          end
          3'b110: begin
            branch_op_o = rv32_pkg::BR_LTU;
            branch_valid = 1'b1;
          end
          3'b111: begin
            branch_op_o = rv32_pkg::BR_GEU;
            branch_valid = 1'b1;
          end
          default: begin
            branch_valid = 1'b0; // Reserved funct3 encoding
          end
        endcase
        if (branch_valid) begin
          alu_op_o = rv32_pkg::ALU_ADD;
          operand_a_sel_o = rv32_pkg::OP_A_PC;
          operand_b_sel_o = rv32_pkg::OP_B_IMM;
          imm_kind_o = rv32_pkg::IMM_B;
          control_flow_o = rv32_pkg::CF_BRANCH;
          rs1_used_o = 1'b1;
          rs2_used_o = 1'b1;
          illegal_o = 1'b0;
        end
      end
      rv32_pkg::OPCODE_JAL: begin
        alu_op_o = rv32_pkg::ALU_ADD;
        operand_a_sel_o = rv32_pkg::OP_A_PC;
        operand_b_sel_o = rv32_pkg::OP_B_IMM;
        imm_kind_o = rv32_pkg::IMM_J;
        control_flow_o = rv32_pkg::CF_JAL;
        writeback_sel_o = rv32_pkg::WB_PC_PLUS_4;
        reg_write_o = 1'b1;
        illegal_o = 1'b0;
      end
      rv32_pkg::OPCODE_JALR: begin
        if (funct3 == 3'b000) begin
          alu_op_o = rv32_pkg::ALU_ADD;
          operand_a_sel_o = rv32_pkg::OP_A_RS1;
          operand_b_sel_o = rv32_pkg::OP_B_IMM;
          imm_kind_o = rv32_pkg::IMM_I;
          control_flow_o = rv32_pkg::CF_JALR;
          writeback_sel_o = rv32_pkg::WB_PC_PLUS_4;
          rs1_used_o = 1'b1;
          reg_write_o = 1'b1;
          illegal_o = 1'b0;
        end
      end
    endcase
  end

endmodule
