# RV32IM Core 差分验证教程

本文说明 `rv32_reference_core` 与 `rv32_pipeline_core` 的 commit-level differential testbench，重点回答三个问题：reference core 为什么可以作为参考、两颗周期行为完全不同的 core 如何比较，以及 testbench 的 scoreboard 应如何实现和扩展。

## 1. 差分验证能证明什么

差分验证让两个实现运行相同程序，并比较它们产生的架构可见结果。这里的“架构可见”包括退休指令的 PC、指令编码、寄存器写回、load/store 和 trap，不包括流水级位置、stall 周期数、forwarding 路径或执行耗时。

如果第 N 条退休指令不同，至少有一个实现存在问题。它特别适合发现 pipeline 中的：

- forwarding 选择错误；
- load-use stall 少停或多停一个周期；
- branch/JAL/JALR flush 不完整；
- 被冲刷指令仍然写回；
- RV32M 等待期间重复发请求或提前提交；
- memory backpressure 下丢失请求；
- trap 之前或之后错误提交指令。

差分验证不能单独证明两颗 core 都符合 RISC-V 规范。如果两个 core 共用一个错误 decoder，它们可能得到完全相同的错误结果。因此 reference-vs-pipeline 是项目内部的一层验证，最终还需要 Spike、Sail 或 RISC-V architectural tests 作为独立外部依据。

## 2. 在差分测试前，怎样建立 Reference Core 的可信度

不能通过一句“reference core 比较简单”保证它正确。更可靠的做法是逐层增加独立证据。

### 2.1 第一层：模块单元测试

Reference core 依赖的模块必须先独立验证：

- decoder：每个 opcode、funct3、funct7 组合产生正确控制信号；
- immediate generator：I/S/B/U/J 五类立即数的符号扩展和位拼接；
- regfile：x0 恒为零、同步写回、两个组合读端口；
- ALU 和 branch unit：算术、比较、逻辑和分支条件；
- LSU：地址对齐、byte enable、store 数据移位、load 符号扩展；
- multiplier/divider：运算结果、延迟、back-to-back 行为和 RISC-V 特殊情况。

这些测试已经存在于 `tb/unit/`，`make test` 会运行它们。单元测试把错误限制在一个小模块中，但无法覆盖模块连接错误。

### 2.2 第二层：Reference Core directed tests

现有 reference-core regression 检查正常执行、同步 trap 和不对齐 RESET_PC。还应持续确认：

- 每条指令只提交一次；
- 没有完整执行的指令不能提交；
- x0 不产生架构写入；
- load/store 的 commit 信息与实际 memory transaction 一致；
- trap 指令提交后不再取指、访存或提交；
- request 在 `valid && !ready` 时保持稳定；
- response 只被消费一次。

运行当前 reference-core 验证：

```bash
make CAD_ENV=/path/to/env.sh check-reference-core
```

### 2.3 第三层：自检查程序

单条 directed test 容易漏掉跨指令交互。应让 reference core 运行包含以下内容的短程序：

1. 构造寄存器初值；
2. 形成连续 RAW 数据依赖；
3. 用 branch 构造 loop；
4. load 已由先前 store 写入的数据；
5. 执行每类 RV32M 运算和特殊情况；
6. 把结果写到约定的 signature memory 区域；
7. 用 `EBREAK` 结束。

Testbench 根据 RISC-V 语义预先计算 signature，而不是从 DUT 内部寄存器推断答案。这样能够验证多条指令组合后的状态。

### 2.4 第四层：独立软件模型

更强的依据是让同一个 ELF 在 Spike 或 Sail 上运行，再比较 commit trace。外部模型与项目 RTL 不共享 decoder、ALU 或 LSU，因此能发现 reference 和 pipeline 同时具有的错误。

建议的可信度层次是：

```text
RISC-V ISA specification
          ↓
Spike / Sail / architectural tests
          ↓
rv32_reference_core
          ↓
pipeline + cache + future OoO cores
```

在接入外部模型前，现有单元测试、reference directed tests 和自检查程序足以开始内部差分测试，但文档和 README 不应因此宣称完整 ISA compliance。

## 3. 为什么比较 Commit，而不是每个周期

Reference core 一次只执行一条指令，pipeline core 允许多条指令同时在途。它们执行同一个程序时，fetch request、memory request 和 commit 发生的周期一定不同。

错误方法是比较同一个周期的输出：

```text
cycle 20: reference commit == pipeline commit
```

正确方法是比较退休序号：

```text
reference commit 0 == pipeline commit 0
reference commit 1 == pipeline commit 1
reference commit 2 == pipeline commit 2
```

因此两边各需要一个按顺序保存 commit event 的缓冲区。只要两个缓冲区都已经产生下一项，scoreboard 就比较它们。某一颗 core 暂时领先只会让自己的缓冲区多保存几项，不构成错误。

## 4. 为什么必须使用两个独立 Memory

两颗 core 的初始程序和数据必须相同，但运行中的 memory 状态必须独立。如果它们共享一个可写 memory，同一条 store 会执行两次，并且先执行的 core 会改变另一颗 core 随后 load 的结果。

Testbench 使用：

```text
rv32_reference_core → reference_memory
rv32_pipeline_core  → pipeline_memory
```

`write_word_both(address, data)` 同时初始化两份 memory，保证初态一致。此后两个 memory instance 不再互相影响。

## 5. Commit Event 的字段和比较条件

`commit_valid` 表示当前周期存在一条退休指令。捕获事件以后，数组中的一项本身就代表 valid，因此不需要再把 `commit_valid` 保存进结构体。

| 字段 | 何时比较 | 含义 |
|---|---|---|
| `pc` | 始终 | 退休指令地址 |
| `instr` | 始终 | 退休指令编码 |
| `rd_write` | 始终 | 是否产生架构寄存器写回 |
| `rd_addr`, `rd_wdata` | `rd_write == 1` | 目标寄存器及写回值 |
| `mem_valid` | 始终 | 是否为架构 load/store |
| `mem_write` | `mem_valid == 1` | load 或 store |
| `mem_addr` | `mem_valid == 1` | 架构访问地址 |
| `mem_rmask`, `mem_wmask` | `mem_valid == 1` | 有效 byte lane |
| `mem_rdata`, `mem_wdata` | 对应 mask 有效时 | load/store 数据 |
| `trap` | 始终 | 是否以同步异常结束 |
| `trap_cause` | `trap == 1` | RISC-V exception cause |

不要无条件比较无效字段。例如普通 ADD 的 `mem_rdata` 没有架构意义，两个 core 可以输出不同的默认值而不构成错误。Store 的 `mem_rdata` 同样无效；load 的 `mem_wdata` 也不应参与比较。

对于 `rd_addr == 0`，以当前 commit interface 的定义为准：如果 core 报告 `rd_write == 0`，则不比较 `rd_addr/rd_wdata`。两个 core 必须遵守相同的 commit 语义。

## 6. 为什么在 negedge 采样

DUT 的状态通常在 `posedge clk` 通过 nonblocking assignment 更新。如果 testbench 也在同一个 posedge 立即读取，可能在 DUT 更新之前看到旧值，形成仿真 race。

骨架在 `negedge clk` 捕获 commit。此时距离 DUT 的 posedge 更新已经过去半个周期，输出稳定，逻辑关系更直观。另一种工业 testbench 写法是使用 SystemVerilog clocking block，但当前 Icarus 环境使用 negedge 更简单可靠。

## 7. Testbench 结构

文件：`tb/core/rv32_core_differential_tb.sv`

Testbench 包含：

- 两颗 core 的全部端口声明与连接；
- 两个独立 `rv32_simple_memory`；
- `commit_event_t`；
- 固定大小的 reference/pipeline trace 数组；
- commit、compare 和 cycle 计数器；
- 公共 program loader helper；
- clock/reset 基础结构；
- 独立的编译和回归 Makefile target。

固定数组比 SystemVerilog 动态 queue 更冗长，但对 Icarus 的兼容性更稳定，也能明确检测 trace overflow。

## 8. Scoreboard 的实现顺序

### 第一步：加载第一个差分程序

使用 `write_word_both()` 把相同指令和初始数据写入两个 memory。第一个程序不要覆盖全部 ISA，先包含：

```text
ADDI → dependent ADD → SW → dependent LW
taken branch → not-taken branch
MUL或DIV
EBREAK
```

程序必须自己结束，否则无法区分 CPU 死锁和测试仍在正常运行。初始数据地址应避开指令区域。

### 第二步：打包 Commit Event

完成 `sample_reference_commit()` 和 `sample_pipeline_commit()`。每个函数只做一件事：把当前 core 的 `commit_*` 输出复制到对应结构体字段，不在这里判断正确性。

伪代码：

```text
event.pc         = commit_pc
event.instr      = commit_instr
event.rd_write   = commit_rd_write
...
event.trap_cause = commit_trap_cause
return event
```

两个函数的字段顺序应完全相同，避免一边漏掉新加入的 commit 字段。

### 第三步：捕获两边的 Commit

在 negedge monitor 中分别处理：

```text
if reference commit valid:
    if ref_commit_count == MAX_COMMITS: fail
    ref_events[ref_commit_count] = sample_reference_commit()
    ref_commit_count++

if pipeline commit valid:
    if pipe_commit_count == MAX_COMMITS: fail
    pipe_events[pipe_commit_count] = sample_pipeline_commit()
    pipe_commit_count++
```

Testbench 变量使用 blocking assignment，确保同一个 monitor 内后续语句能看到刚更新的计数值。

### 第四步：条件化比较一个 Event

`compare_commit_events(expected, actual, index)` 必须始终比较 PC、instruction 和三个控制条件，再根据控制条件比较有效 payload。

推荐每组字段给出独立错误信息：

```text
differential mismatch at commit 17
field: rd_wdata
reference: 0x00000008
pipeline:  0x00000004
pc:        0x00000030
instr:     0x002081b3
```

只输出“FAIL”会让波形定位困难。

### 第五步：按退休序号消费

当 `compared_count < ref_commit_count` 且 `compared_count < pipe_commit_count` 时，两边都已经产生下一项，可以调用：

```text
compare_commit_events(ref_events[compared_count], pipe_events[compared_count], compared_count)
compared_count++
```

不能因为 pipeline 先 halt 就跳过 reference 尚未产生的 event，也不能把较快 core 的 cycle count 当作退休序号。

### 第六步：结束、PASS 和 Timeout

只有同时满足以下条件才能 PASS：

```text
ref_halted == 1
pipe_halted == 1
ref_commit_count == pipe_commit_count
compared_count == ref_commit_count
ref_commit_count > 0
```

还必须具有两个失败条件：

- `cycle_count >= MAX_CYCLES`：core 死锁、程序未终止或 timeout 设置过小；
- 任一 commit count 达到 `MAX_COMMITS`：trace buffer 不够或程序没有按预期结束。

开发未完成的 testbench 时应保留 deliberate `$fatal`，防止空 TB 假 PASS。只有 scoreboard 和终止检查实际运行后，才允许删除它并打印 PASS。

## 9. 第一版通过以后怎样增强

按以下顺序增加测试强度：

1. 扩大 directed program，覆盖全部 RV32IM 指令类型；
2. 增加多个程序，每次 reset、重新初始化 memory 和 trace counters；
3. 给两个 memory 使用不同的随机 ready/response latency；
4. 随机插入分支、RAW dependency、load/store 和 RV32M；
5. 保存失败 seed，使随机错误可以复现；
6. 接入 ELF/hex loader，运行编译器生成程序；
7. 与 Spike/Sail commit trace 比较。

给两颗 core 使用不同 memory latency 很重要：它证明 commit 结果与微架构等待周期无关，而不是两颗 core 恰好以相似节奏通过测试。

## 10. Cache 加入后的使用方式

I-cache 或 D-cache 接入 pipeline 后，仍然让 reference core 连接 simple memory，让 pipeline core 通过 cache 连接自己的 backing memory。正确 Cache 只能改变请求数量、miss 延迟和总周期数，不能改变 commit trace。

Write-back D-cache 有一个特殊点：store 可以已经架构提交，但 dirty line 尚未写回 backing memory。因此 cache 差分测试应优先比较 commit memory event；只有执行 cache flush 后，才能直接比较两份 backing memory 的最终内容。

## 11. 编译命令

只编译差分 testbench：

```bash
make CAD_ENV=/path/to/env.sh compile-core-differential
```

运行差分 testbench：

```bash
make CAD_ENV=/path/to/env.sh test-core-differential
```

该测试已经加入总 `make test` 回归。扩展 checker 后仍应确认正确设计能够 PASS，并且人为修改一条 pipeline commit 数据或测试程序预期时一定 FAIL，以证明 checker 本身不是空的。
