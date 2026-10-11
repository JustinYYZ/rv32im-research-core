# Offline Spike Verification

scripts/run_spike_diff.py builds and executes one RV32IM program through rv32_ooo_l1_top, runs the same ELF in Spike, and uses scripts/compare_commit_trace.py to compare retirement records. Both logs are streamed, so memory usage does not grow with retired instruction count.

## Compared behavior

| Field | Comparison |
|---|---|
| PC / instruction | Exact 32-bit equality in retirement order |
| Integer writeback | Destination and value; x0 writes normalize to no architectural write |
| Memory access | Load/store validity, direction, actual byte address, access width |
| Store effect | Written bytes after normalization; unused bus lanes are ignored |
| Load result | Register writeback versus Spike; RTL masked read data is also checked against signed/unsigned writeback |
| Completion | Both streams reach the same first magic halt; the RTL stream must end there |

The checker validates contiguous RTL order beginning at one, mask shape/alignment, CSV columns, supported integer records, and known active-field values. Unsupported Spike records are errors rather than silently skipped lines.

RTL records aligned word addresses and four byte-enable bits. Spike records the effective byte address. For SB at base+1, RTL mask 0010 and data 0x0000aa00 normalize to address base+1, width 1, value 0xaa. SH and SW use the same rule.

Spike's integer commit log does not expose full load bus data. Loads into x0 therefore check address and width but cannot independently compare the loaded value. This is not a complete RVFI implementation.

## Halt and exception boundary

The first retirement of 0x00000063, 0x0000006f, or 0xf0002013 ends the testbench program. Spike interprets these as normal instructions, so the runner gives it a small instruction margin beyond the RTL count and parses through its first marker. Exhausting the budget without reaching halt fails.

This runner verifies programs without traps. Unexpected RTL traps and unsupported Spike privilege/trap records fail. Halt-after-trap differs from privileged Spike trap-vector handling; ECALL, illegal instruction, misalignment, and access faults remain checked by the internal reference/OoO directed suite.

## Commands

With tools on PATH:

~~~bash
make BUILD_DIR=/tmp/rv32-release test-spike-tools
make BUILD_DIR=/tmp/rv32-release test-spike PROGRAM=sw/tests/smoke.c SPIKE=/path/to/spike
make BUILD_DIR=/tmp/rv32-release test-spike PROGRAM=sw/tests/memory_widths.s SPIKE=/path/to/spike
make BUILD_DIR=/tmp/rv32-release test-benchmarks BENCHMARK_ROOT=/path/to/benchmarks SPIKE=/path/to/spike BENCH_ENGINE=verilator
~~~

The default engine is Icarus. Verilator compiles the same harness with --binary --timing, preserving clock, cache, memory, and ROI semantics.

The three checker tests verify matching logs pass, a changed destination value fails, and truncated RTL logs fail.

## Artifacts and reproducibility

Every run writes RTL CSV, Spike logs, simulator/host logs, and result.json in BUILD_DIR/runs/<program>/. The manifest records the dirty-worktree flag, commands, versions, configuration, IPC, and compared count.

A dirty-worktree result includes uncommitted files; keep the measured version separate from later functional changes.

Simulation failures, missing halt/metrics, timeouts, parser errors, and architectural differences return nonzero status. The benchmark target stops at the first failure. The first architectural mismatch includes the preceding four matching records.

Raw generated artifacts are not committed. Curated results live in [the baseline report](../results/ooo-l1-baseline.md). External workload ELF files remain local inputs and are not redistributed.
