# SPDX-License-Identifier: Apache-2.0
#
# Build and simulation entry points for RV32IM Research Core.
# Run the current ALU unit test with: make test-alu

CAD_ENV   ?= /home/yyao30/Openroad_workspace/env.sh
IVERILOG  ?= iverilog
VVP       ?= vvp
BUILD_DIR ?= build

ALU_TEST := $(BUILD_DIR)/rv32_alu_tb
ALU_SRCS := \
	rtl/pkg/rv32_pkg.sv \
	rtl/backend/rv32_alu.sv \
	tb/unit/rv32_alu_tb.sv

.PHONY: test-alu tools clean

test-alu: $(ALU_TEST)
	bash -c 'source "$(CAD_ENV)" >/dev/null && $(VVP) $<'

$(ALU_TEST): $(ALU_SRCS)
	mkdir -p $(BUILD_DIR)
	bash -c 'source "$(CAD_ENV)" >/dev/null && \
		$(IVERILOG) -g2012 -Wall -s rv32_alu_tb -o $@ $(ALU_SRCS)'

tools:
	bash -c 'source "$(CAD_ENV)" >/dev/null && \
		printf "iverilog: " && command -v $(IVERILOG) && \
		printf "vvp:      " && command -v $(VVP)'

clean:
	rm -f $(ALU_TEST)
