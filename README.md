# RV32IM Research Core

[English](#english) | [中文](#中文)

## English

### Overview

RV32IM Research Core is a synthesizable RISC-V processor project developed in SystemVerilog. The
project uses an in-order implementation as a verified architectural baseline, then extends the
same ISA and commit interface toward pipelined and out-of-order microarchitectures.

The architecture, implementation, and verification are developed by the author with assistance
from OpenAI Codex (GPT-5.6-sol).

The project focuses on three goals:

- understanding the complete path from RISC-V instruction semantics to RTL;
- building a reusable verification environment based on architectural commit behavior;
- evaluating microarchitectural tradeoffs with simulation, synthesis, and timing data.

### Target Scope

The planned processor scope is:

- RV32IM integer instruction set;
- 32-bit integer registers and byte-addressed memory;
- little-endian bare-metal execution;
- synthesizable SystemVerilog;
- in-order reference core;
- five-stage in-order pipeline;
- separate L1 instruction and data caches;
- unified L2 cache;
- register renaming, physical register file, reorder buffer, and reservation stations;
- out-of-order execution with in-order retirement;
- commit-level differential verification;
- synthesis and timing evaluation with Yosys and OpenROAD.

The initial scope does not include virtual memory, Linux, multicore coherence, superscalar issue,
or the A/F/D/C/V extensions. Unsupported features are documented explicitly rather than being
treated as implemented behavior.

### Planned Architecture

```text
                                +-------------------+
                                |    L1 I-cache     |
                                +---------+---------+
                                          |
PC -> Fetch -> Decode -> Rename/Dispatch -+--------------------+
                         |                                      |
                         +-> RAT / Free List                    |
                         +-> ROB --------------------------> Commit -> ARF
                         +-> Reservation Stations               |
                                          |                     |
                                          v                     |
                                  Execution Units -> Completion-+
                                    |      |      |
                                   ALU   MUL/DIV  LSU -> L1 D-cache
                                                        |
                                L1 I-cache --------------+-> L2 -> Memory
```

Development uses three independently testable cores:

1. `rv32_reference_core`: a multicycle in-order architectural reference;
2. `rv32_pipeline_core`: a five-stage in-order performance baseline;
3. `rv32_ooo_core`: a dynamically scheduled core with in-order retirement.

All cores are intended to share the same memory and architectural commit interfaces.

### Verification Strategy

Verification is developed together with the RTL:

- directed unit tests for decoder, ALU, regfile, branch, LSU, and mul/div units;
- instruction-level assembly tests;
- randomized instruction and memory-response latency tests;
- a common architectural commit trace;
- differential checking between the reference, pipeline, and OoO cores;
- Spike comparison through an RVFI-like retirement interface;
- Verilator lint and Yosys synthesis sanity checks;
- cache hit, miss, refill, writeback, replacement, and byte-mask tests.

Correctness is established before IPC, frequency, or area optimizations are evaluated.

### Research Direction

The main planned study compares conservative memory scheduling with more aggressive load
scheduling in a small out-of-order core:

- loads and stores restricted to the ROB head;
- early loads when older memory operations are known not to conflict;
- a load/store queue with store-to-load forwarding.

The comparison will use retired-instruction count, cycle count, IPC, memory-stall cycles, cache
miss rates, synthesis area, and critical-path timing.

### Repository Layout

```text
rtl/                 synthesizable processor RTL
  pkg/               ISA constants, shared types, and interfaces
  frontend/          decode, immediate generation, and fetch logic
  core/              reference, pipeline, OoO, and system top levels
  pipeline/          pipeline registers, forwarding, and hazard control
  backend/           regfile, ALU, mul/div, rename, ROB, and scheduling
  cache/             L1 caches, L2 cache, and cache-line adapters
  memory/            external memory protocol definitions

tb/                  unit, core, and model testbenches
sw/                  bare-metal tests and benchmarks
docs/                design, verification, development, and result documents
scripts/             build, regression, synthesis, and result-processing scripts
.github/workflows/    continuous-integration jobs
```

### Project Status

The project is in early implementation. The following components are implemented and covered by
self-checking unit tests:

- shared RV32I ALU operation types;
- combinational integer ALU;
- 32 × 32-bit architectural register file with two read ports and one write port.

Run the current regression with:

```bash
make test
```

If the simulation tools require an environment setup script:

```bash
make CAD_ENV=/path/to/env.sh test
```

### License

This project is licensed under the [Apache License 2.0](LICENSE).

---

## 中文

### 项目简介

RV32IM Research Core 是一个使用 SystemVerilog 开发的可综合 RISC-V 处理器项目。
项目先建立经过验证的顺序执行实现，作为 architectural baseline，再在相同 ISA
和 commit interface 上逐步发展出流水线和乱序执行微架构。

项目的架构、实现和验证由作者完成，并使用 OpenAI Codex（GPT-5.6-sol）辅助开发。

项目主要关注三个目标：

- 理解从 RISC-V 指令语义到 RTL 数据通路的完整过程；
- 建立基于 architectural commit behavior 的可复用验证环境；
- 使用仿真、综合和时序数据研究微架构设计取舍。

### 目标范围

计划中的处理器范围包括：

- RV32IM 整数指令集；
- 32 位整数寄存器和 byte-addressed memory；
- little-endian bare-metal 执行环境；
- 可综合 SystemVerilog；
- 顺序参考核；
- 五级顺序流水线；
- 分离的 L1 instruction/data cache；
- unified L2 cache；
- register renaming、physical register file、ROB 和 reservation stations；
- 乱序执行、顺序退休；
- commit-level differential verification；
- 使用 Yosys/OpenROAD 进行综合和时序实验。

第一阶段不包含虚拟内存、Linux、多核一致性、超标量发射以及 A/F/D/C/V 扩展。
所有未实现功能都会在文档中明确标注，不会被当作已经支持的行为。

### 计划架构

```text
                                +-------------------+
                                |    L1 I-cache     |
                                +---------+---------+
                                          |
PC -> Fetch -> Decode -> Rename/Dispatch -+--------------------+
                         |                                      |
                         +-> RAT / Free List                    |
                         +-> ROB --------------------------> Commit -> ARF
                         +-> Reservation Stations               |
                                          |                     |
                                          v                     |
                                  Execution Units -> Completion-+
                                    |      |      |
                                   ALU   MUL/DIV  LSU -> L1 D-cache
                                                        |
                                L1 I-cache --------------+-> L2 -> Memory
```

项目包含三种可以独立测试的处理器实现：

1. `rv32_reference_core`：多周期顺序 architectural reference；
2. `rv32_pipeline_core`：五级顺序流水线性能 baseline；
3. `rv32_ooo_core`：动态调度、顺序退休的乱序执行核。

三种实现计划共用相同的 memory interface 和 architectural commit interface。

### 验证方法

验证环境和 RTL 同步开发：

- decoder、ALU、regfile、branch、LSU 和 mul/div 单元测试；
- 指令级汇编测试；
- 随机指令和随机 memory response latency；
- 统一 architectural commit trace；
- reference、pipeline 和 OoO core 之间的逐条差分比较；
- 通过 RVFI-like retirement interface 与 Spike 比较；
- Verilator lint 和 Yosys synthesis sanity check；
- cache hit、miss、refill、writeback、replacement 和 byte-mask 测试。

项目会先证明正确性，再评估 IPC、频率和面积优化。

### 研究方向

计划研究小型乱序核中，保守 memory scheduling 和更激进 load scheduling 的差异：

- load/store 都限制在 ROB head；
- 确认与旧 memory operation 无冲突后允许 load 提前执行；
- 使用 load/store queue 和 store-to-load forwarding。

实验将比较退休指令数、周期数、IPC、memory stall cycles、cache miss rate、综合面积
和关键路径时序。

### 仓库结构

```text
rtl/                 可综合处理器 RTL
  pkg/               ISA 常量、公共类型和接口
  frontend/          decode、immediate generation 和 fetch
  core/              reference、pipeline、OoO 和 system top
  pipeline/          流水线寄存器、forwarding 和 hazard control
  backend/           regfile、ALU、mul/div、rename、ROB 和调度
  cache/             L1、L2 和 cache-line adapter
  memory/            外部 memory protocol 定义

tb/                  unit、core 和 model testbench
sw/                  bare-metal 测试与 benchmark
docs/                设计、验证、开发记录和实验结果
scripts/             构建、回归、综合和结果处理脚本
.github/workflows/    自动测试
```

### 当前状态

项目目前处于早期实现阶段。以下模块已经实现，并具有 self-checking unit test：

- 公共 RV32I ALU 操作类型；
- 组合逻辑整数 ALU；
- 具有两个读端口和一个写端口的 32 × 32-bit 架构寄存器堆。

运行当前全部测试：

```bash
make test
```

如果仿真工具需要环境初始化脚本：

```bash
make CAD_ENV=/path/to/env.sh test
```

### 开源许可证

本项目采用 [Apache License 2.0](LICENSE) 开源许可证。
