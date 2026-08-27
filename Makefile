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

ROB_TEST := $(BUILD_DIR)/rv32_rob_tb
ROB_SRCS := \
	rtl/pkg/rv32_ooo_pkg.sv \
	rtl/backend/rv32_rob.sv \
	tb/unit/rv32_rob_tb.sv

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

HAZARD_UNIT_TEST := $(BUILD_DIR)/rv32_hazard_unit_tb
HAZARD_UNIT_SRCS := \
	rtl/pipeline/rv32_hazard_unit.sv \
	tb/unit/rv32_hazard_unit_tb.sv

FORWARDING_UNIT_TEST := $(BUILD_DIR)/rv32_forwarding_unit_tb
FORWARDING_UNIT_SRCS := \
	rtl/pipeline/rv32_forwarding_unit.sv \
	tb/unit/rv32_forwarding_unit_tb.sv

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

REFERENCE_CORE_TEST := $(BUILD_DIR)/rv32_reference_core_tb
REFERENCE_CORE_RTL_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/pkg/rv32_core_pkg.sv \
	rtl/frontend/rv32_decoder.sv \
	rtl/frontend/rv32_imm_gen.sv \
	rtl/backend/rv32_regfile.sv \
	rtl/backend/rv32_alu.sv \
	rtl/backend/rv32_branch_unit.sv \
	rtl/backend/rv32_lsu.sv \
	rtl/backend/rv32_multiplier.sv \
	rtl/backend/rv32_divider.sv \
	rtl/core/rv32_reference_core.sv

REFERENCE_CORE_SRCS := \
	$(REFERENCE_CORE_RTL_SRCS) \
	tb/model/rv32_simple_memory.sv \
	tb/core/rv32_reference_core_tb.sv

REFERENCE_CORE_TRAP_TEST := $(BUILD_DIR)/rv32_reference_core_trap_tb
REFERENCE_CORE_TRAP_SRCS := \
	$(REFERENCE_CORE_RTL_SRCS) \
	tb/model/rv32_simple_memory.sv \
	tb/core/rv32_reference_core_trap_tb.sv

REFERENCE_CORE_RESET_PC_TEST := $(BUILD_DIR)/rv32_reference_core_reset_pc_tb
REFERENCE_CORE_RESET_PC_SRCS := \
	$(REFERENCE_CORE_RTL_SRCS) \
	tb/core/rv32_reference_core_reset_pc_tb.sv

PIPELINE_CORE_COMPILE := $(BUILD_DIR)/rv32_pipeline_core_tb
PIPELINE_CORE_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/pkg/rv32_core_pkg.sv \
	rtl/pkg/rv32_pipeline_pkg.sv \
	rtl/frontend/rv32_decoder.sv \
	rtl/frontend/rv32_imm_gen.sv \
	rtl/backend/rv32_regfile.sv \
	rtl/backend/rv32_alu.sv \
	rtl/backend/rv32_branch_unit.sv \
	rtl/backend/rv32_lsu.sv \
	rtl/backend/rv32_multiplier.sv \
	rtl/backend/rv32_divider.sv \
	rtl/pipeline/rv32_hazard_unit.sv \
	rtl/pipeline/rv32_forwarding_unit.sv \
	rtl/core/rv32_pipeline_core.sv \
	tb/model/rv32_simple_memory.sv \
	tb/core/rv32_pipeline_core_tb.sv

PIPELINE_HAZARD_COMPILE := $(BUILD_DIR)/rv32_pipeline_hazard_tb
PIPELINE_HAZARD_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/pkg/rv32_core_pkg.sv \
	rtl/pkg/rv32_pipeline_pkg.sv \
	rtl/frontend/rv32_decoder.sv \
	rtl/frontend/rv32_imm_gen.sv \
	rtl/backend/rv32_regfile.sv \
	rtl/backend/rv32_alu.sv \
	rtl/backend/rv32_branch_unit.sv \
	rtl/backend/rv32_lsu.sv \
	rtl/backend/rv32_multiplier.sv \
	rtl/backend/rv32_divider.sv \
	rtl/pipeline/rv32_hazard_unit.sv \
	rtl/pipeline/rv32_forwarding_unit.sv \
	rtl/core/rv32_pipeline_core.sv \
	tb/model/rv32_simple_memory.sv \
	tb/core/rv32_pipeline_hazard_tb.sv

PIPELINE_FORWARDING_COMPILE := $(BUILD_DIR)/rv32_pipeline_forwarding_tb
PIPELINE_FORWARDING_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/pkg/rv32_core_pkg.sv \
	rtl/pkg/rv32_pipeline_pkg.sv \
	rtl/frontend/rv32_decoder.sv \
	rtl/frontend/rv32_imm_gen.sv \
	rtl/backend/rv32_regfile.sv \
	rtl/backend/rv32_alu.sv \
	rtl/backend/rv32_branch_unit.sv \
	rtl/backend/rv32_lsu.sv \
	rtl/backend/rv32_multiplier.sv \
	rtl/backend/rv32_divider.sv \
	rtl/pipeline/rv32_hazard_unit.sv \
	rtl/pipeline/rv32_forwarding_unit.sv \
	rtl/core/rv32_pipeline_core.sv \
	tb/core/rv32_pipeline_forwarding_tb.sv

PIPELINE_CONTROL_FLOW_COMPILE := $(BUILD_DIR)/rv32_pipeline_control_flow_tb
PIPELINE_CONTROL_FLOW_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/pkg/rv32_core_pkg.sv \
	rtl/pkg/rv32_pipeline_pkg.sv \
	rtl/frontend/rv32_decoder.sv \
	rtl/frontend/rv32_imm_gen.sv \
	rtl/backend/rv32_regfile.sv \
	rtl/backend/rv32_alu.sv \
	rtl/backend/rv32_branch_unit.sv \
	rtl/backend/rv32_lsu.sv \
	rtl/backend/rv32_multiplier.sv \
	rtl/backend/rv32_divider.sv \
	rtl/pipeline/rv32_hazard_unit.sv \
	rtl/pipeline/rv32_forwarding_unit.sv \
	rtl/core/rv32_pipeline_core.sv \
	tb/core/rv32_pipeline_control_flow_tb.sv

PIPELINE_MEMORY_COMPILE := $(BUILD_DIR)/rv32_pipeline_memory_tb
PIPELINE_MEMORY_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/pkg/rv32_core_pkg.sv \
	rtl/pkg/rv32_pipeline_pkg.sv \
	rtl/frontend/rv32_decoder.sv \
	rtl/frontend/rv32_imm_gen.sv \
	rtl/backend/rv32_regfile.sv \
	rtl/backend/rv32_alu.sv \
	rtl/backend/rv32_branch_unit.sv \
	rtl/backend/rv32_lsu.sv \
	rtl/backend/rv32_multiplier.sv \
	rtl/backend/rv32_divider.sv \
	rtl/pipeline/rv32_hazard_unit.sv \
	rtl/pipeline/rv32_forwarding_unit.sv \
	rtl/core/rv32_pipeline_core.sv \
	tb/model/rv32_simple_memory.sv \
	tb/core/rv32_pipeline_memory_tb.sv

PIPELINE_MULDIV_COMPILE := $(BUILD_DIR)/rv32_pipeline_muldiv_tb
PIPELINE_MULDIV_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/pkg/rv32_core_pkg.sv \
	rtl/pkg/rv32_pipeline_pkg.sv \
	rtl/frontend/rv32_decoder.sv \
	rtl/frontend/rv32_imm_gen.sv \
	rtl/backend/rv32_regfile.sv \
	rtl/backend/rv32_alu.sv \
	rtl/backend/rv32_branch_unit.sv \
	rtl/backend/rv32_lsu.sv \
	rtl/backend/rv32_multiplier.sv \
	rtl/backend/rv32_divider.sv \
	rtl/pipeline/rv32_hazard_unit.sv \
	rtl/pipeline/rv32_forwarding_unit.sv \
	rtl/core/rv32_pipeline_core.sv \
	tb/core/rv32_pipeline_muldiv_tb.sv

PIPELINE_TRAP_COMPILE := $(BUILD_DIR)/rv32_pipeline_trap_tb
PIPELINE_TRAP_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/pkg/rv32_core_pkg.sv \
	rtl/pkg/rv32_pipeline_pkg.sv \
	rtl/frontend/rv32_decoder.sv \
	rtl/frontend/rv32_imm_gen.sv \
	rtl/backend/rv32_regfile.sv \
	rtl/backend/rv32_alu.sv \
	rtl/backend/rv32_branch_unit.sv \
	rtl/backend/rv32_lsu.sv \
	rtl/backend/rv32_multiplier.sv \
	rtl/backend/rv32_divider.sv \
	rtl/pipeline/rv32_hazard_unit.sv \
	rtl/pipeline/rv32_forwarding_unit.sv \
	rtl/core/rv32_pipeline_core.sv \
	tb/core/rv32_pipeline_trap_tb.sv

CORE_DIFFERENTIAL_COMPILE := $(BUILD_DIR)/rv32_core_differential_tb
CORE_DIFFERENTIAL_SRCS := \
	$(REFERENCE_CORE_RTL_SRCS) \
	rtl/pkg/rv32_pipeline_pkg.sv \
	rtl/pipeline/rv32_hazard_unit.sv \
	rtl/pipeline/rv32_forwarding_unit.sv \
	rtl/core/rv32_pipeline_core.sv \
	tb/model/rv32_simple_memory.sv \
	tb/core/rv32_core_differential_tb.sv

ICACHE_COMPILE := $(BUILD_DIR)/rv32_icache_tb
ICACHE_SRCS := \
	rtl/pkg/rv32_cache_pkg.sv \
	rtl/cache/rv32_icache.sv \
	tb/cache/rv32_icache_tb.sv

PIPELINE_L1_COMPILE := $(BUILD_DIR)/rv32_pipeline_l1_tb
PIPELINE_L1_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/pkg/rv32_core_pkg.sv \
	rtl/pkg/rv32_pipeline_pkg.sv \
	rtl/pkg/rv32_cache_pkg.sv \
	rtl/frontend/rv32_decoder.sv \
	rtl/frontend/rv32_imm_gen.sv \
	rtl/backend/rv32_regfile.sv \
	rtl/backend/rv32_alu.sv \
	rtl/backend/rv32_branch_unit.sv \
	rtl/backend/rv32_lsu.sv \
	rtl/backend/rv32_multiplier.sv \
	rtl/backend/rv32_divider.sv \
	rtl/pipeline/rv32_hazard_unit.sv \
	rtl/pipeline/rv32_forwarding_unit.sv \
	rtl/cache/rv32_icache.sv \
	rtl/cache/rv32_dcache.sv \
	rtl/core/rv32_pipeline_core.sv \
	rtl/core/rv32_pipeline_l1_top.sv \
	tb/model/rv32_simple_memory.sv \
	tb/cache/rv32_pipeline_l1_tb.sv

DCACHE_COMPILE := $(BUILD_DIR)/rv32_dcache_tb
DCACHE_SRCS := \
	rtl/pkg/rv32_cache_pkg.sv \
	rtl/cache/rv32_dcache.sv \
	tb/cache/rv32_dcache_tb.sv

.PHONY: test test-alu test-regfile test-rob test-imm-gen test-decoder test-branch-unit test-hazard-unit test-forwarding-unit test-lsu \
	test-multiplier test-divider check-decoder lint-decoder synth-decoder \
	check-multiplier lint-multiplier synth-multiplier \
	check-divider lint-divider synth-divider tools clean

.PHONY: compile-reference-core test-reference-core test-reference-core-trap test-reference-core-reset-pc check-reference-core lint-reference-core synth-reference-core
.PHONY: compile-pipeline-core compile-pipeline-hazard compile-pipeline-forwarding compile-pipeline-control-flow compile-pipeline-memory compile-pipeline-muldiv compile-pipeline-trap test-pipeline-core test-pipeline-hazard test-pipeline-forwarding test-pipeline-control-flow test-pipeline-memory test-pipeline-muldiv test-pipeline-trap check-pipeline
.PHONY: compile-core-differential test-core-differential
.PHONY: compile-icache test-icache compile-pipeline-l1 test-pipeline-l1
.PHONY: compile-dcache test-dcache

test: test-alu test-regfile test-rob test-imm-gen test-decoder test-branch-unit test-lsu test-multiplier test-divider \
	test-reference-core test-reference-core-trap test-reference-core-reset-pc check-pipeline test-core-differential test-icache test-pipeline-l1 test-dcache

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

# Compile and run the ROB allocation-order and occupancy regression.
test-rob: $(ROB_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(ROB_TEST): $(ROB_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_rob_tb -o $@ $(ROB_SRCS)'

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

test-hazard-unit: $(HAZARD_UNIT_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(HAZARD_UNIT_TEST): $(HAZARD_UNIT_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_hazard_unit_tb -o $@ $(HAZARD_UNIT_SRCS)'

test-forwarding-unit: $(FORWARDING_UNIT_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(FORWARDING_UNIT_TEST): $(FORWARDING_UNIT_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_forwarding_unit_tb -o $@ $(FORWARDING_UNIT_SRCS)'

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

compile-reference-core: $(REFERENCE_CORE_TEST)

test-reference-core: $(REFERENCE_CORE_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(REFERENCE_CORE_TEST): $(REFERENCE_CORE_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_reference_core_tb -o $@ $(REFERENCE_CORE_SRCS)'

test-reference-core-trap: $(REFERENCE_CORE_TRAP_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(REFERENCE_CORE_TRAP_TEST): $(REFERENCE_CORE_TRAP_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_reference_core_trap_tb -o $@ $(REFERENCE_CORE_TRAP_SRCS)'

test-reference-core-reset-pc: $(REFERENCE_CORE_RESET_PC_TEST)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(REFERENCE_CORE_RESET_PC_TEST): $(REFERENCE_CORE_RESET_PC_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_reference_core_reset_pc_tb -o $@ $(REFERENCE_CORE_RESET_PC_SRCS)'

check-reference-core: test-reference-core test-reference-core-trap test-reference-core-reset-pc lint-reference-core synth-reference-core

lint-reference-core:
	bash -c '$(ENV_SETUP) \
		$(VERILATOR) --lint-only --timing -Wall --Wno-fatal --top-module rv32_reference_core_tb $(REFERENCE_CORE_SRCS)'
	bash -c '$(ENV_SETUP) \
		$(VERILATOR) --lint-only --timing -Wall --Wno-fatal --top-module rv32_reference_core_trap_tb $(REFERENCE_CORE_TRAP_SRCS)'
	bash -c '$(ENV_SETUP) \
		$(VERILATOR) --lint-only --timing -Wall --Wno-fatal --top-module rv32_reference_core_reset_pc_tb $(REFERENCE_CORE_RESET_PC_SRCS)'

synth-reference-core:
	bash -c '$(ENV_SETUP) \
		$(YOSYS) -q -p "read_verilog -sv $(REFERENCE_CORE_RTL_SRCS); \
		hierarchy -check -top rv32_reference_core; proc; opt; check"'

compile-pipeline-core: $(PIPELINE_CORE_COMPILE)

test-pipeline-core: $(PIPELINE_CORE_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(PIPELINE_CORE_COMPILE): $(PIPELINE_CORE_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_pipeline_core_tb -o $@ $(PIPELINE_CORE_SRCS)'

compile-pipeline-hazard: $(PIPELINE_HAZARD_COMPILE)

test-pipeline-hazard: $(PIPELINE_HAZARD_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(PIPELINE_HAZARD_COMPILE): $(PIPELINE_HAZARD_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_pipeline_hazard_tb -o $@ $(PIPELINE_HAZARD_SRCS)'

compile-pipeline-forwarding: $(PIPELINE_FORWARDING_COMPILE)

test-pipeline-forwarding: $(PIPELINE_FORWARDING_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(PIPELINE_FORWARDING_COMPILE): $(PIPELINE_FORWARDING_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_pipeline_forwarding_tb -o $@ $(PIPELINE_FORWARDING_SRCS)'

compile-pipeline-control-flow: $(PIPELINE_CONTROL_FLOW_COMPILE)

test-pipeline-control-flow: $(PIPELINE_CONTROL_FLOW_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(PIPELINE_CONTROL_FLOW_COMPILE): $(PIPELINE_CONTROL_FLOW_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_pipeline_control_flow_tb -o $@ $(PIPELINE_CONTROL_FLOW_SRCS)'

compile-pipeline-memory: $(PIPELINE_MEMORY_COMPILE)

test-pipeline-memory: $(PIPELINE_MEMORY_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(PIPELINE_MEMORY_COMPILE): $(PIPELINE_MEMORY_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_pipeline_memory_tb -o $@ $(PIPELINE_MEMORY_SRCS)'

compile-pipeline-muldiv: $(PIPELINE_MULDIV_COMPILE)

test-pipeline-muldiv: $(PIPELINE_MULDIV_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(PIPELINE_MULDIV_COMPILE): $(PIPELINE_MULDIV_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_pipeline_muldiv_tb -o $@ $(PIPELINE_MULDIV_SRCS)'

compile-pipeline-trap: $(PIPELINE_TRAP_COMPILE)

test-pipeline-trap: $(PIPELINE_TRAP_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(PIPELINE_TRAP_COMPILE): $(PIPELINE_TRAP_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_pipeline_trap_tb -o $@ $(PIPELINE_TRAP_SRCS)'

check-pipeline: test-hazard-unit test-forwarding-unit test-pipeline-core test-pipeline-hazard test-pipeline-forwarding test-pipeline-control-flow test-pipeline-memory test-pipeline-muldiv test-pipeline-trap

compile-core-differential: $(CORE_DIFFERENTIAL_COMPILE)

test-core-differential: $(CORE_DIFFERENTIAL_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(CORE_DIFFERENTIAL_COMPILE): $(CORE_DIFFERENTIAL_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_core_differential_tb -o $@ $(CORE_DIFFERENTIAL_SRCS)'

compile-icache: $(ICACHE_COMPILE)

test-icache: $(ICACHE_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(ICACHE_COMPILE): $(ICACHE_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_icache_tb -o $@ $(ICACHE_SRCS)'

compile-pipeline-l1: $(PIPELINE_L1_COMPILE)

test-pipeline-l1: $(PIPELINE_L1_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(PIPELINE_L1_COMPILE): $(PIPELINE_L1_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_pipeline_l1_tb -o $@ $(PIPELINE_L1_SRCS)'

compile-dcache: $(DCACHE_COMPILE)

test-dcache: $(DCACHE_COMPILE)
	bash -c '$(ENV_SETUP) $(VVP) $<'

$(DCACHE_COMPILE): $(DCACHE_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c '$(ENV_SETUP) \
		$(IVERILOG) -g2012 -Wall -s rv32_dcache_tb -o $@ $(DCACHE_SRCS)'

tools:
	bash -c '$(ENV_SETUP) \
		printf "iverilog: " && command -v $(IVERILOG) && \
		printf "vvp:      " && command -v $(VVP) && \
		printf "verilator: " && command -v $(VERILATOR) && \
		printf "yosys:     " && command -v $(YOSYS)'

clean:
	rm -f $(ALU_TEST) $(REGFILE_TEST) $(ROB_TEST) $(IMM_GEN_TEST) $(DECODER_TEST) \
		$(BRANCH_UNIT_TEST) $(HAZARD_UNIT_TEST) $(FORWARDING_UNIT_TEST) $(LSU_TEST) $(MULTIPLIER_TEST) $(DIVIDER_TEST) $(REFERENCE_CORE_TEST) $(REFERENCE_CORE_TRAP_TEST) $(REFERENCE_CORE_RESET_PC_TEST) $(PIPELINE_CORE_COMPILE) $(PIPELINE_HAZARD_COMPILE) $(PIPELINE_FORWARDING_COMPILE) $(PIPELINE_CONTROL_FLOW_COMPILE) $(PIPELINE_MEMORY_COMPILE) $(PIPELINE_MULDIV_COMPILE) $(PIPELINE_TRAP_COMPILE) $(CORE_DIFFERENTIAL_COMPILE) $(ICACHE_COMPILE) $(PIPELINE_L1_COMPILE) $(DCACHE_COMPILE)
