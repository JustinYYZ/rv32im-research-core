# SPDX-License-Identifier: Apache-2.0
#
# Build and simulation entry points for RV32IM Research Core.
# Run all unit tests with `make test`, or select one of the module targets below.

CAD_ENV   ?=
IVERILOG  ?= iverilog
VVP       ?= vvp
VERILATOR ?= verilator
YOSYS     ?= yosys
BUILD_DIR ?= build

# Leave CAD_ENV empty when the tools are already on PATH. A machine-specific
# setup script can be supplied with: make CAD_ENV=/path/to/env.sh <target>
ENV_SETUP = $(if $(strip $(CAD_ENV)),source "$(CAD_ENV)" >/dev/null &&,)

ALU_TEST := $(BUILD_DIR)/rv32_alu_tb
ALU_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/backend/rv32_alu.sv \
	tb/unit/rv32_alu_tb.sv

REGFILE_TEST := $(BUILD_DIR)/rv32_regfile_tb
REGFILE_SRCS := \
	rtl/backend/rv32_regfile.sv \
	tb/unit/rv32_regfile_tb.sv

IMM_GEN_TEST := $(BUILD_DIR)/rv32_imm_gen_tb
IMM_GEN_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/frontend/rv32_imm_gen.sv \
	tb/unit/rv32_imm_gen_tb.sv

DECODER_TEST := $(BUILD_DIR)/rv32_decoder_tb
DECODER_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/frontend/rv32_decoder.sv \
	tb/unit/rv32_decoder_tb.sv

BRANCH_UNIT_TEST := $(BUILD_DIR)/rv32_branch_unit_tb
BRANCH_UNIT_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/backend/rv32_branch_unit.sv \
	tb/unit/rv32_branch_unit_tb.sv

LSU_TEST := $(BUILD_DIR)/rv32_lsu_tb
LSU_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/backend/rv32_lsu.sv \
	tb/unit/rv32_lsu_tb.sv

MULTIPLIER_TEST := $(BUILD_DIR)/rv32_multiplier_tb
MULTIPLIER_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/backend/rv32_multiplier.sv \
	tb/unit/rv32_multiplier_tb.sv

DIVIDER_TEST := $(BUILD_DIR)/rv32_divider_tb
DIVIDER_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/backend/rv32_divider.sv \
	tb/unit/rv32_divider_tb.sv

.PHONY: test test-alu test-regfile test-imm-gen test-decoder test-branch-unit test-lsu \
	test-multiplier test-divider check-decoder lint-decoder synth-decoder \
	check-multiplier lint-multiplier synth-multiplier \
	check-divider lint-divider synth-divider tools clean

test: test-alu test-regfile test-imm-gen test-decoder test-branch-unit test-lsu test-multiplier test-divider

test-alu: $(ALU_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(ALU_TEST): $(ALU_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_alu_tb -o $@ $(ALU_SRCS)'

test-regfile: $(REGFILE_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(REGFILE_TEST): $(REGFILE_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_regfile_tb -o $@ $(REGFILE_SRCS)'

test-imm-gen: $(IMM_GEN_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(IMM_GEN_TEST): $(IMM_GEN_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_imm_gen_tb -o $@ $(IMM_GEN_SRCS)'

test-decoder: $(DECODER_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(DECODER_TEST): $(DECODER_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_decoder_tb -o $@ $(DECODER_SRCS)'

# Run the decoder simulation, lint its RTL and testbench, and verify that the
# synthesizable decoder hierarchy passes Yosys structural checks.
check-decoder: test-decoder lint-decoder synth-decoder

lint-decoder:
	bash -c '$(ENV_SETUP) \
		$(VERILATOR) --lint-only --timing -Wall --Wno-fatal $(DECODER_SRCS)'

synth-decoder:
	bash -c '$(ENV_SETUP) \
		$(YOSYS) -q -p "read_verilog -sv rtl/pkg/rv32_pkg.sv rtl/frontend/rv32_decoder.sv; \
		hierarchy -check -top rv32_decoder; proc; opt; check"'

test-branch-unit: $(BRANCH_UNIT_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(BRANCH_UNIT_TEST): $(BRANCH_UNIT_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_branch_unit_tb -o $@ $(BRANCH_UNIT_SRCS)'

test-lsu: $(LSU_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(LSU_TEST): $(LSU_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_lsu_tb -o $@ $(LSU_SRCS)'

# Three-stage Radix-4 Booth/Wallace multiplier regression.
test-multiplier: $(MULTIPLIER_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(MULTIPLIER_TEST): $(MULTIPLIER_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_multiplier_tb -o $@ $(MULTIPLIER_SRCS)'

check-multiplier: test-multiplier lint-multiplier synth-multiplier

lint-multiplier:
	bash -c '$(ENV_SETUP) \
		$(VERILATOR) --lint-only --timing -Wall --Wno-fatal $(MULTIPLIER_SRCS)'

synth-multiplier:
	bash -c '$(ENV_SETUP) \
		$(YOSYS) -q -p "read_verilog -sv rtl/pkg/rv32_pkg.sv rtl/backend/rv32_multiplier.sv; \
		hierarchy -check -top rv32_multiplier; proc; opt; check"'

# 32-cycle Radix-2 restoring divider regression.
test-divider: $(DIVIDER_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(DIVIDER_TEST): $(DIVIDER_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_divider_tb -o $@ $(DIVIDER_SRCS)'

check-divider: test-divider lint-divider synth-divider

lint-divider:
	bash -c '$(ENV_SETUP) \
		$(VERILATOR) --lint-only --timing -Wall --Wno-fatal $(DIVIDER_SRCS)'

synth-divider:
	bash -c '$(ENV_SETUP) \
		$(YOSYS) -q -p "read_verilog -sv rtl/pkg/rv32_pkg.sv rtl/backend/rv32_divider.sv; \
		hierarchy -check -top rv32_divider; proc; opt; check"'

tools:
	bash -c '$(ENV_SETUP) \
		printf "iverilog: " && command -v $(IVERILOG) && \
		printf "vvp:      " && command -v $(VVP) && \
		printf "verilator: " && command -v $(VERILATOR) && \
		printf "yosys:     " && command -v $(YOSYS)'

clean:
	rm -f $(ALU_TEST) $(REGFILE_TEST) $(IMM_GEN_TEST) $(DECODER_TEST) \
		$(BRANCH_UNIT_TEST) $(LSU_TEST) $(MULTIPLIER_TEST) $(DIVIDER_TEST)
