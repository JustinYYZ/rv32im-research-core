# OoO + L1 benchmark baseline

Measured on 2026-10-11 with the single-dispatch/single-issue core and split blocking L1 caches. All six programs passed offline Spike comparison from startup through the first magic halt.

| Program | ROI cycles | ROI instructions | IPC | Full-program commits compared | Spike |
|---|---:|---:|---:|---:|---|
| coremark_im.elf | 1,106,599 | 291,563 | 0.263477 | 304,044 | PASS |
| aes_sha.elf | 2,895,233 | 775,934 | 0.268004 | 776,008 | PASS |
| compression.elf | 1,450,145 | 430,012 | 0.296530 | 435,228 | PASS |
| fft.elf | 3,912,959 | 1,161,014 | 0.296710 | 1,166,732 | PASS |
| image.elf | 2,269,883 | 472,983 | 0.208373 | 477,026 | PASS |
| mergesort.elf | 1,711,217 | 481,846 | 0.281581 | 493,187 | PASS |

Total: **3,652,225 retirement events** compared against Spike. This is workload verification, not exhaustive ISA certification.

## Configuration

- reset_pc: 0xaaaaa000
- isa: rv32im
- icache_bytes: 32768
- dcache_bytes: 32768
- line_bytes: 32
- cache: direct-mapped, blocking; D-cache write-back/write-allocate
- refill_bits: 32
- memory: separate I/D ports; one pending request per port; response one rising edge after acceptance
- roi: exclude start marker, include stop marker
- max_cycles: 20000000

IPC excludes the start marker and includes the stop marker. Correctness comparison includes startup, ROI, post-ROI execution, and halt.
Measurements use the deterministic mapped memory model described above. Equal ELF inputs do not imply directly comparable IPC across different cache and memory configurations.

## Tool versions

- Simulator: Verilator 5.051 devel rev v5.050-74-g796d5174f (mod)
- Reference: Spike RISC-V ISA Simulator 1.1.1-dev
- Compiler: riscv64-unknown-elf-gcc () 10.2.0
- Functional RTL and the benchmark harness were unchanged throughout these runs.

## Reproduce

External workload ELF files remain local inputs and are not redistributed. BENCHMARK_ROOT contains the six RV32IM ELF files.

~~~bash
make BUILD_DIR=/tmp/rv32-release test-benchmarks BENCHMARK_ROOT=/path/to/benchmarks SPIKE=/path/to/spike BENCH_ENGINE=verilator
make BUILD_DIR=/tmp/rv32-release summarize-benchmarks
~~~

Use BENCH_ENGINE=icarus for the same testbench under Icarus. All six benchmarks also passed Spike under Icarus, with identical ROI cycles, instructions, IPC, and full-program commit counts to Verilator.
The 70-commit C smoke and 17-commit subword-memory program matched between both simulators as well. The total above counts each workload once, not both simulator runs.
Each BUILD_DIR/runs/<program>/ contains traces, host logs, and result.json with commands, configuration, versions, and correctness status.

## Limits and future work

One outstanding fetch, ROB-head-only memory issue, and retirement-time branch recovery limit IPC.
L2, LSQ/forwarding, advanced prediction, online RVFI, and privileged execution are outside this version. Internal directed/differential tests cover synchronous traps.
External comparison checks architectural stores, not every cache writeback transaction. Directed cache tests separately cover refill, masks, dirty eviction, backpressure, and errors.
See [Spike verification](../verification/rv32-spike-verification.md) and the [core-only timing result](ooo-core-timing.md).
