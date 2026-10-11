# Feature Inventory / 功能清单

[English](#english) | [中文](#中文) · [Project overview / 项目概览](README.md)

## English

This inventory describes the implemented baseline and its verification entry points. Experimental numbers and measurement constraints remain in the [benchmark report](docs/results/ooo-l1-baseline.md) and [timing report](docs/results/ooo-core-timing.md).

### ISA and architectural data path

- shared RV32I control types and instruction opcodes;
- combinational integer ALU;
- combinational RV32I branch-condition unit;
- 32 × 32-bit architectural register file with two read ports and one write port;
- I-, S-, B-, U-, and J-type immediate generation;
- decoder support for all RV32I register-register and immediate ALU
  instructions, conditional branches, JAL, JALR, loads, and stores, plus LUI,
  AUIPC, and decode events for ECALL, EBREAK, FENCE, and FENCE.TSO; FENCE.I is
  not supported;
- a combinational load/store formatting unit with address-alignment checks, store byte enables, and signed or unsigned load extension;

### Multiply and divide

- a three-stage RV32M multiplier using Radix-4 Booth recoding and a Wallace carry-save tree, with one-request-per-cycle throughput;
- a single-request RV32M divider using 32-cycle Radix-2 restoring division, signed-magnitude preprocessing, and RISC-V-defined corner-case handling;

### Reference core, pipeline, and traps

- a multi-cycle in-order RV32IM reference core with blocking instruction/data interfaces, architectural commit reporting, system instructions, synchronous traps, and halt-after-trap behavior;
- a five-stage RV32IM pipeline with valid-bit stage control, optional RAW stalling, EX/MEM and MEM/WB forwarding, branch/JAL/JALR recovery, blocking load/store operation, and multicycle RV32M integration;
- precise synchronous pipeline traps for illegal instructions, ECALL, EBREAK, instruction/data misalignment, and instruction/data access faults, followed by sticky halt;

### OoO frontend

- an eight-entry Fetch Queue with ready/valid flow control, FIFO ordering, full-Queue simultaneous replacement, explicit pointer wraparound, instruction-fault metadata, and recovery Flush;
- a single-request out-of-order instruction frontend with I-cache backpressure, Fetch Queue flow control, sequential PC generation, redirect recovery, epoch-based stale-response rejection, and instruction-access-fault metadata;

### Renaming and scheduling

ROB is the reorder buffer; PRF is the physical register file; RAT and RRAT are the speculative and retirement register-alias maps. IQ denotes the issue queue.

- a 16-entry circular ROB with generation-tagged pointers, explicit occupancy, stored PC/instruction/destination payloads, tagged out-of-order result completion, stale-tag rejection, backpressured in-order retirement, and simultaneous allocation/retirement handling;
- a 64-entry physical register file with two combinational data-read ports, two independent rename-readiness lookup ports, allocation-based readiness tracking, one completion writeback port, hardwired p0 behavior, and allocation priority on same-register collisions;
- 32-entry speculative and committed rename maps with two source lookups, old-destination lookup, identity reset, fixed x0 mapping, and recovery that includes same-cycle retirement;
- a 64-entry physical-register free list with lowest-index allocation, speculative and committed availability maps, retirement-based old-mapping release, fixed p0 exclusion, exhaustion backpressure, and recovery that includes same-cycle retirement;
- an eight-entry, single-dispatch, single-issue queue with physical-tag wakeup, same-cycle Dispatch/CDB handling, functional-unit backpressure, deterministic lowest-slot selection, simultaneous Dispatch/Issue occupancy handling, and recovery Flush;
- an atomic single-instruction Rename/Dispatch controller that allocates ROB and Issue Queue entries together with optional Free List, RAT, and PRF destination updates;

### OoO execution and retirement

CDB is the shared completion/data broadcast path; LSU is the load/store unit. Memory requests remain ordered even though independent arithmetic can execute out of order.

- a combinational integer/control-flow Issue Stage with physical-register addressing, operand selection, branch comparison, actual-next-PC resolution, and completion backpressure;
- a one-entry registered Completion Buffer carrying result and actual-next-PC metadata with stable retention, recovery Flush, and bubble-free consume-and-replace throughput;
- a four-input round-robin CDB arbiter with single-winner downstream backpressure and fairness rotation;
- a buffered OoO multiplier producer that aligns ROB/physical-register metadata with the pipelined result, reserves four outstanding credits, absorbs CDB backpressure, and discards queued or in-flight work on recovery;
- a single-request OoO divider producer that retains instruction metadata, holds a completed result under CDB backpressure, and cancels active or buffered work on recovery;
- an ordered one-request OoO LSU that issues only ROB-Head memory operations and preserves load/store completion, access-fault, and memory-commit metadata through CDB backpressure;
- an integrated single-dispatch/single-issue OoO backend connecting Rename, Issue Queue, shared PRF reads, ALU/MUL/DIV/LSU producers, CDB writeback, ROB completion, RRAT/Free List updates, ordered retirement, branch recovery, and trap recovery;

### L1 caches and integration

- a parameterized 32 KiB direct-mapped blocking L1 instruction cache with 32-byte lines, sequential word refill, request backpressure, atomic line installation, reset invalidation, and refill-error handling;
- a parameterized 32 KiB direct-mapped blocking L1 data cache with masked store hits, write-allocate, dirty-victim writeback, sequential word transfers, request backpressure, atomic refill installation, and access-error recovery;
- a pipeline-plus-separate-L1 integration top with regressions covering instruction refill and redirect recovery, data load/store commits, masked store merging, dirty eviction, access faults, and backing-memory request counts;
- an OoO-plus-separate-L1 integration top with a directed regression covering instruction/data refill, same-line hits, Store-hit visibility, same-set conflict replacement, dirty writeback, Commit results, and precise ECALL halt;

### Directed and internal differential verification

- integrated OoO core regressions covering integer/control-flow and RV32M execution, ordered load/store commits, subword formatting, memory faults and backpressure, wrong-path Store cancellation, precise ECALL retirement, and sticky halt;
- commit-level differential verification between the reference and pipeline cores using independent memory images and retirement-order comparison;
- commit-level differential verification between the reference and OoO cores, with and without split L1 caches, covering RV32I/RV32M operations, control-flow recovery, subword memory behavior, misalignment, access faults, and final memory signatures;
- directed unit, reference-core, pipeline, and OoO integration regressions covering the implemented paths.

Core-level RV32M directed programs use MUL and DIV to check integration behavior. Decoder tests cover all eight RV32M operations; Rename/Dispatch routing tests directly check representative MUL and DIV operations. Standalone arithmetic tests cover signed/unsigned variants and corner cases. The offline Spike suite adds an independent model for the measured programs. These tests do not constitute exhaustive ISA compliance certification; online RVFI and privileged trap handling remain outside this version.

### Software and external verification

- Bare-metal startup and linker script, repository-owned C and subword-memory assembly tests, and ELF32 little-endian RISC-V to word-addressed memh conversion.
- C, standalone assembly, and existing RV32IM ELF build inputs, with disassembly and software-image inspection.
- A mapped benchmark memory with separate program/stack regions and instruction/data ports, one pending request per port, and masked writes.
- A split-L1 benchmark harness with commit CSV output, timeout/signature checks, halt markers, and region-of-interest (ROI) cycle/instruction accounting.
- Streaming offline Spike comparison of PC, instruction, integer writeback, and normalized memory effects through the first halt. Unexpected traps are rejected by this runner; internal directed tests cover synchronous exceptions.
- Per-run JSON manifests record tools, commands, cache/memory configuration, IPC, and correctness status. Icarus and Verilator use the same benchmark harness.
- Core-only Yosys/slang synthesis and OpenROAD timing scripts, with explicit Nangate45 platform input. Full constraints and the pre-clock-tree/pre-route limitation are documented separately.

### Focused commands

Run `make <target>` with tools on PATH. Add `BUILD_DIR=/tmp/rv32-test` to keep output outside the repository and `CAD_ENV=/path/to/env.sh` when a simulation/CAD environment needs initialization. Simulation/lint/synthesis combined targets require their corresponding tools; `test` runs the directed simulation suite, not the external benchmark batch or physical-design flow.

| Group | Make targets |
|---|---|
| Full directed regression | `test` |
| ISA/data-path units | `test-alu`, `test-regfile`, `test-imm-gen`, `test-decoder`, `test-branch-unit`, `test-lsu` |
| Unit simulation/lint/synthesis | `check-decoder`, `check-multiplier`, `check-divider` |
| Reference core | `test-reference-core`, `test-reference-core-trap`, `test-reference-core-reset-pc`, `check-reference-core` |
| Pipeline | `check-pipeline` |
| Internal differential | `test-core-differential`, `test-ooo-differential`, `test-ooo-l1-differential` |
| Cache units and wrappers | `test-icache`, `test-dcache`, `test-pipeline-l1`, `test-ooo-l1` |
| OoO frontend | `test-fetch-queue`, `test-ooo-frontend` |
| Rename/physical registers | `test-phys-regfile`, `test-rename-map`, `test-free-list`, `test-rename-dispatch` |
| Issue queue | `test-issue-queue` |
| ROB storage/completion/retirement | `test-rob`, `test-rob-storage`, `test-rob-completion`, `test-rob-retirement` |
| Integer issue and CDB | `test-ooo-execute`, `test-cdb-arbiter` |
| OoO arithmetic/memory producers | `test-ooo-multiplier`, `test-ooo-divider`, `test-ooo-lsu` |
| OoO core integration | `test-ooo-integer`, `test-ooo-core`, `test-ooo-rv32m`, `test-ooo-memory` |
| Software images | `build-program`, `inspect-program` |
| External verification | `test-spike-tools`, `test-spike`, `test-benchmarks` |
| Benchmark harness | `compile-ooo-benchmark`, `test-ooo-benchmark`, `test-ooo-benchmark-verilator` |
| Core-only synthesis/timing | `synth-ooo`, `sta-ooo` |
| Benchmark report generation | `summarize-benchmarks` |

For independent comparison and workload reporting:

```bash
make BUILD_DIR=/tmp/rv32-spike test-spike PROGRAM=sw/tests/memory_widths.s SPIKE=/path/to/spike
make BUILD_DIR=/tmp/rv32-bench test-benchmarks BENCHMARK_ROOT=/path/to/benchmarks SPIKE=/path/to/spike BENCH_ENGINE=verilator
make BUILD_DIR=/tmp/rv32-bench summarize-benchmarks
```

`BENCHMARK_ROOT` contains the six ELF filenames listed in the [baseline report](docs/results/ooo-l1-baseline.md). The external binaries are not distributed with this repository. Use `BENCH_ENGINE=icarus` for Icarus. The standalone benchmark harness checks program completion and optional signatures; prefer `test-spike` / `test-benchmarks` when independent architectural checking is required.

For the core-only physical baseline:

```bash
make BUILD_DIR=/tmp/rv32-sta sta-ooo NANGATE45_DIR=/path/to/Nangate45 OOO_PERIOD=5
```

The platform directory must contain the library, technology/standard-cell LEF files, tracks, and RC configuration used by `scripts/sta_ooo.tcl`. Supply `CAD_ENV` if the CAD tools are not already on PATH. This target excludes L1 caches and does not perform clock-tree synthesis or routing.

### Not implemented in this baseline

- FENCE.I, A/F/D/C/V ISA extensions, privileged CSRs/trap handlers, virtual memory, Linux, and multicore coherence.
- Unified L2, load/store-queue scheduling, early loads, store-to-load forwarding, advanced prediction, and superscalar issue.
- Online full RVFI integration, exhaustive ISA compliance certification, cache SRAM-macro integration, power characterization, and physical signoff.

The [documentation index](docs/README.md) links the design and verification references. These limits distinguish the current implementation from possible future extensions.

---

## 中文

本清单介绍当前已实现的组件及验证入口。实验数值和测量约束分别保存在 [benchmark 报告](docs/results/ooo-l1-baseline.md)与[时序报告](docs/results/ooo-core-timing.md)中。

### ISA 与架构数据通路

- 公共 RV32I 控制类型与指令 opcode；
- 组合逻辑整数 ALU；
- RV32I 组合逻辑 branch-condition 单元；
- 具有两个读端口和一个写端口的 32 × 32-bit 架构寄存器堆；
- I、S、B、U 和 J-type immediate 生成；
- decoder 已支持全部 RV32I 寄存器和 immediate ALU 指令、conditional
  branch、JAL、JALR、load 和 store，以及 LUI、AUIPC；同时能够识别 ECALL、
  EBREAK、FENCE 和 FENCE.TSO 事件；暂不支持 FENCE.I；
- 组合逻辑 LSU formatting 单元，支持地址对齐检查、store byte enable 和 signed/unsigned load extension；

### 乘法与除法

- 三级 RV32M 乘法器，使用 Radix-4 Booth 编码和 Wallace carry-save tree，吞吐率为每周期一条请求；
- 单请求 RV32M 除法器，使用 32 周期 Radix-2 restoring division，支持 signed-magnitude 预处理和 RISC-V 规定的除零、溢出行为；

### 参考核、流水线与异常

- 多周期顺序 RV32IM reference core，具有 blocking instruction/data interface、architectural commit、system instruction、同步 trap 和 trap 后 HALT；
- 五级 RV32IM 顺序流水线，具有 valid-bit stage control、可选 RAW stall、EX/MEM 与 MEM/WB forwarding、branch/JAL/JALR recovery、blocking load/store 和多周期 RV32M 集成；
- 精确同步异常，覆盖非法指令、ECALL、EBREAK、指令/数据地址未对齐和 instruction/data access fault，异常提交后进入 sticky HALT；

### OoO 前端

- 8-entry Fetch Queue，支持 ready/valid flow control、FIFO 顺序、满队列同周期替换、显式指针回绕、取指错误信息和 recovery Flush；
- 单请求 OoO 取指前端，支持 I-cache backpressure、Fetch Queue flow control、顺序 PC 生成、redirect recovery、基于 epoch 的旧响应丢弃和 instruction access fault 信息传递；

### 重命名与调度

ROB 是重排序缓冲区，PRF 是物理寄存器堆，RAT／RRAT 分别是推测／已提交的寄存器重命名映射表，IQ 是发射队列。

- 16-entry circular ROB，使用带 generation 的指针、显式 occupancy 和 PC/instruction/destination payload storage，支持 tagged out-of-order result completion、stale-tag rejection、带 backpressure 的顺序 retirement 以及同周期 allocation/retirement；
- 64-entry 物理寄存器文件，具有两个组合数据读端口、两个独立 Rename ready 查询端口、allocation ready-state tracking、单 completion writeback 端口、固定 p0 行为以及同地址冲突时的 allocation 优先级；
- 各 32 项的推测/已提交重命名映射表，支持双源查询、旧目标映射查询、初始一一映射、固定 x0 映射，以及包含同周期 retirement 的恢复；
- 64-entry 物理寄存器 Free List，支持最低编号优先分配、推测/已提交空闲状态、retirement 释放旧映射、固定排除 p0、耗尽 backpressure，以及包含同周期 retirement 的恢复；
- 8-entry 单 Dispatch、单 Issue 调度队列，支持物理 tag 唤醒、同周期 Dispatch/CDB 处理、功能单元 backpressure、确定性的最低槽位选择、同周期 Dispatch/Issue occupancy 更新和 recovery Flush；
- 原子单指令 Rename/Dispatch 控制器，将 ROB 和 Issue Queue 分配与可选的 Free List、RAT 和 PRF 目标更新绑定为同一事务；

### OoO 执行与退休

CDB 是共享完成／数据广播路径，LSU 是 Load/Store 单元。独立算术操作可以乱序执行，但访存请求仍保持顺序。

- 组合逻辑整数/控制流 Issue Stage，支持物理寄存器寻址、操作数选择、branch compare、实际 next-PC 解析和 completion backpressure；
- 单项寄存式 Completion Buffer，携带结果和 actual-next-PC metadata，支持稳定保持、recovery Flush 和无气泡 consume-and-replace；
- 四输入 round-robin CDB arbiter，支持单 winner 下游 backpressure 和公平轮换；
- 带缓冲的 OoO 乘法 producer，能够将 ROB/物理寄存器 metadata 与流水结果对齐，预留四个 outstanding credit，吸收 CDB backpressure，并在 recovery 时丢弃队列内和流水线内的旧工作；
- 单请求 OoO 除法 producer，保存指令 metadata，在 CDB backpressure 下保持完成结果，并在 recovery 时清除在途计算或已保存结果；
- 单请求顺序 OoO LSU，仅允许 ROB Head 访存，并在 CDB backpressure 下保持 Load/Store completion、access fault 和 memory Commit metadata；
- 集成的单 Dispatch、单 Issue OoO backend，连接 Rename、Issue Queue、共享 PRF 读端口、ALU/MUL/DIV/LSU producer、CDB 写回、ROB 完成、RRAT/Free List 更新、顺序退休、分支恢复和异常恢复；

### L1 cache 与集成

- 参数化的32 KiB direct-mapped blocking L1 instruction cache，使用32-byte line，支持逐 word refill、request backpressure、整 line 原子安装、reset invalidation 和 refill error 处理；
- 参数化的32 KiB direct-mapped blocking L1 data cache，支持 masked store hit、write-allocate、dirty victim writeback、逐 word transfer、request backpressure、整 line 原子安装和 access error 恢复；
- pipeline + separate L1 集成顶层及自检 regression，覆盖 instruction refill 与 redirect recovery、data load/store commit、masked store merge、dirty eviction、access fault 和 backing-memory request count；
- OoO + separate L1 集成顶层及定向 regression，覆盖 instruction/data refill、同一 line 命中、Store hit 后可见性、同 Set 冲突替换、dirty writeback、Commit 结果和精确 ECALL halt；

### 定向与内部差分验证

- OoO core 自检 regression，覆盖整数/控制流与 RV32M 执行、顺序 Load/Store Commit、subword 格式、访存异常及 backpressure、错误路径 Store 取消、精确 ECALL 退休和 sticky halt；
- Reference core 与 pipeline core 之间的 commit-level 差分验证，使用独立 memory image 并按退休顺序比较；
- Reference core 与 OoO core 之间的 commit-level 差分验证，覆盖原始 memory port 与 split L1 两种配置，以及 RV32I/RV32M、控制流恢复、subword memory、地址未对齐、access fault 和最终 memory signature；
- 覆盖已接通路径的 unit、reference-core、pipeline 和 OoO integration directed regression。

Core-level RV32M 定向程序使用 MUL 和 DIV 检查集成行为；decoder 测试覆盖八条 RV32M 指令，Rename/Dispatch 路由测试直接检查 MUL、DIV 两个代表，独立算术测试覆盖有符号/无符号变体及边界情况。离线 Spike suite 为实际测量程序增加了独立参考模型。这些测试不等于完整 ISA 合规认证；在线 RVFI 和特权级 trap handler 不在本版本范围内。

### 软件与外部验证

- 裸机启动代码、链接脚本、仓库自有的 C 与 subword-memory 汇编测试，以及 ELF32 小端 RISC-V 到按 word 寻址的 memh 转换。
- 支持 C、独立汇编和已有 RV32IM ELF 输入，可生成反汇编并检查软件镜像。
- 使用独立程序／栈区域的 benchmark 存储器，分离指令／数据端口，每个端口允许一个在途请求，支持按 byte mask 写入。
- 分离式 L1 benchmark 测试平台，支持 Commit CSV、超时／signature 检查、halt 标记和测量区间（ROI）的周期／退休指令统计。
- 离线、流式 Spike 差分，比较 PC、指令、整数写回和归一化访存副作用，直到首次 halt。该入口拒绝意外异常；同步异常由内部定向测试覆盖。
- 每次运行的 JSON manifest 保存工具、命令、cache／memory 配置、IPC 和正确性状态。Icarus 和 Verilator 使用相同 benchmark 测试平台。
- 仅核心的 Yosys/slang 综合与 OpenROAD 时序脚本，显式传入 Nangate45 平台。完整约束以及尚未进行时钟树／布线的限制见独立报告。

### 分项命令

工具在 PATH 时运行 `make <target>`。可加 `BUILD_DIR=/tmp/rv32-test` 将产物放到仓库外；仿真／CAD 工具需要初始化时传入 `CAD_ENV=/path/to/env.sh`。仿真／lint／综合联合 target 需要相应工具；`test` 运行定向仿真回归，不包含外部 benchmark 批量测试或物理设计流程。

| 分类 | Make target |
|---|---|
| 完整定向回归 | `test` |
| ISA／数据通路单元 | `test-alu`, `test-regfile`, `test-imm-gen`, `test-decoder`, `test-branch-unit`, `test-lsu` |
| 单元仿真／lint／综合 | `check-decoder`, `check-multiplier`, `check-divider` |
| 参考核 | `test-reference-core`, `test-reference-core-trap`, `test-reference-core-reset-pc`, `check-reference-core` |
| 流水线 | `check-pipeline` |
| 内部差分 | `test-core-differential`, `test-ooo-differential`, `test-ooo-l1-differential` |
| Cache 单元与集成顶层 | `test-icache`, `test-dcache`, `test-pipeline-l1`, `test-ooo-l1` |
| OoO 前端 | `test-fetch-queue`, `test-ooo-frontend` |
| 重命名／物理寄存器 | `test-phys-regfile`, `test-rename-map`, `test-free-list`, `test-rename-dispatch` |
| 发射队列 | `test-issue-queue` |
| ROB 存储／完成／退休 | `test-rob`, `test-rob-storage`, `test-rob-completion`, `test-rob-retirement` |
| 整数发射与 CDB | `test-ooo-execute`, `test-cdb-arbiter` |
| OoO 算术／访存执行单元 | `test-ooo-multiplier`, `test-ooo-divider`, `test-ooo-lsu` |
| OoO 核心集成 | `test-ooo-integer`, `test-ooo-core`, `test-ooo-rv32m`, `test-ooo-memory` |
| 软件镜像 | `build-program`, `inspect-program` |
| 外部验证 | `test-spike-tools`, `test-spike`, `test-benchmarks` |
| Benchmark 测试平台 | `compile-ooo-benchmark`, `test-ooo-benchmark`, `test-ooo-benchmark-verilator` |
| 仅核心综合／时序 | `synth-ooo`, `sta-ooo` |
| Benchmark 报告生成 | `summarize-benchmarks` |

独立差分与工作负载报告：

```bash
make BUILD_DIR=/tmp/rv32-spike test-spike PROGRAM=sw/tests/memory_widths.s SPIKE=/path/to/spike
make BUILD_DIR=/tmp/rv32-bench test-benchmarks BENCHMARK_ROOT=/path/to/benchmarks SPIKE=/path/to/spike BENCH_ENGINE=verilator
make BUILD_DIR=/tmp/rv32-bench summarize-benchmarks
```

`BENCHMARK_ROOT` 中需要包含[基线报告](docs/results/ooo-l1-baseline.md)列出的六个 ELF；这些外部二进制不随仓库分发。`BENCH_ENGINE=icarus` 可改用 Icarus。独立 benchmark 测试平台只检查程序结束及可选 signature；需要独立架构检查时应使用 `test-spike`／`test-benchmarks`。

仅核心物理基线：

```bash
make BUILD_DIR=/tmp/rv32-sta sta-ooo NANGATE45_DIR=/path/to/Nangate45 OOO_PERIOD=5
```

平台目录需要包含 `scripts/sta_ooo.tcl` 使用的库文件、technology／standard-cell LEF、tracks 和 RC 配置。CAD 工具未在 PATH 时可传入 `CAD_ENV`。该 target 不含两个 L1，也不执行时钟树综合或布线。

### 当前基线未实现的内容

- FENCE.I、A/F/D/C/V 扩展、特权级 CSR／trap handler、虚拟内存、Linux 和多核一致性。
- Unified L2、访存队列调度、提前 Load、Store-to-Load forwarding、复杂分支预测与超标量发射。
- 在线完整 RVFI 集成、穷尽式 ISA 合规认证、cache SRAM macro 集成、功耗表征及物理签核。

[文档索引](docs/README.md)提供架构与验证资料入口。上述边界用于区分当前实现与未来可能扩展的功能。
