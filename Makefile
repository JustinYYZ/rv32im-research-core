# SPDX-License-Identifier: Apache-2.0
#
# Build and simulation entry points for RV32IM Research Core.
# Unit tests: make test-alu, make test-regfile

CAD_ENV   ?=
IVERILOG  ?= iverilog
VVP       ?= vvp
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

.PHONY: test test-alu test-regfile tools clean

test: test-alu test-regfile

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

tools:
	bash -c '$(ENV_SETUP) \
		printf "iverilog: " && command -v $(IVERILOG) && \
		printf "vvp:      " && command -v $(VVP)'

clean:
	rm -f $(ALU_TEST) $(REGFILE_TEST)
