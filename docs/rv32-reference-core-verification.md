# RV32IM Reference Core 验证指南

本文档说明当前 reference core 如何验证，重点是 testbench 分工、commit 不变量、trap case、memory request/response 检查和回归命令。数据通路和逐阶段实现方法见 [RV32IM 多周期 Reference Core 开发教程](rv32-reference-core.md)。

## 1. 验证对象与边界

`rv32_reference_core` 是一次只处理一条指令的多周期顺序核。验证目标是证明每条支持指令产生正确的架构效果，并且 memory stall、异常和 HALT 不会产生重复请求或额外副作用。

当前验证不声称覆盖以下内容：

- privileged CSR、`mtvec`、`mret` 或真正的 trap handler；
- cache、pipeline hazard、branch prediction 或 OoO speculation；
- RISC-V 官方 architectural test suite 或 Spike differential checking；
- 随机 memory backpressure 和覆盖率收敛。

这些未包含项不会影响 reference core 作为 pipeline/OoO 实现的顺序架构基准，但如果要对外声称更完整的 ISA compliance，应继续补充程序级和差分验证。

## 2. Testbench 分工

| 文件 | 主要职责 |
|---|---|
| `tb/model/rv32_simple_memory.sv` | 提供共享的 little-endian word array，以及独立 instruction/data request-response channel |
| `tb/core/rv32_reference_core_tb.sv` | 执行正常 RV32IM directed program，检查 commit 序列、register result 和 memory side effect |
| `tb/core/rv32_reference_core_trap_tb.sv` | 每个 case reset 并装载短程序，验证 instruction/data/system trap 与 HALT |
| `tb/core/rv32_reference_core_reset_pc_tb.sv` | 用 `RESET_PC=0x0000_0002` 验证取指前的 instruction-address-misaligned trap |

正常执行和 trap 分开测试，是因为 trap commit 后 core 会进入持久 HALT。独立 case 可以明确区分“程序正常退休到某处”和“异常恰好发生在期望 instruction”。

## 3. Commit 是主要观察点

Commit 表示当前指令的架构效果已经确定。Checker 不应只观察内部 ALU result，因为相同结果可能在错误 PC、错误 destination 或错误周期出现。

普通 commit 至少检查：

```text
commit_valid_o
commit_pc_o
commit_instr_o
commit_rd_write_o / commit_rd_addr_o / commit_rd_wdata_o
commit_mem_valid_o 及 memory fields
commit_trap_o = 0
```

Trap commit 必须满足：

```text
commit_valid_o      = 1
commit_trap_o       = 1
commit_trap_cause_o = expected cause
commit_rd_write_o   = 0
commit_mem_valid_o  = 0
```

Trap 的下一周期进入 HALT，此后必须保持：

```text
halted_o          = 1
commit_valid_o    = 0
imem_req_valid_o  = 0
dmem_req_valid_o  = 0
```

## 4. 正常程序回归覆盖什么

`rv32_reference_core_tb.sv` 把机器码直接写入 memory model，然后按顺序等待 commit。测试应同时证明以下关系：

- dependency chain 读取前一条指令刚写回的 register；
- taken branch 和 jump 跳过的 instruction 不会 commit；
- JAL/JALR 写回 `pc + 4`，target 用于 next PC；
- load 只在 response 到达后写回；
- store 只在 acknowledgement 到达后 commit；
- byte/half/word mask、lane alignment 和 sign extension 正确；
- 八条 RV32M 指令通过真实 multiplier/divider request-response path；
- FENCE 作为无寄存器、无 memory side effect 的普通 instruction commit；
- 程序结束后 register file 和 memory 最终状态与预期一致。

最终 register/memory 检查不能代替逐条 commit 检查。两个错误可能互相抵消并产生正确终值，而 commit trace 仍能暴露错误的中间架构状态。

## 5. Trap 测试矩阵

| 场景 | `commit_trap_cause_o` | 是否应先发出相关 memory request |
|---|---|---:|
| `RESET_PC` 不是4字节对齐 | `CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED` | 否 |
| taken branch/JAL/JALR target 不对齐 | `CORE_TRAP_INSTRUCTION_ADDRESS_MISALIGNED` | 否 |
| instruction memory 返回 error | `CORE_TRAP_INSTRUCTION_ACCESS_FAULT` | 是，instruction request |
| decoder 报告 illegal | `CORE_TRAP_ILLEGAL_INSTRUCTION` | 已完成该 instruction 的 fetch；无 data request |
| EBREAK | `CORE_TRAP_BREAKPOINT` | 无 data request |
| load effective address 不对齐 | `CORE_TRAP_LOAD_ADDRESS_MISALIGNED` | 否，不能发 data request |
| load response 返回 error | `CORE_TRAP_LOAD_ACCESS_FAULT` | 是，data request |
| store effective address 不对齐 | `CORE_TRAP_STORE_ADDRESS_MISALIGNED` | 否，不能发 data request |
| store response 返回 error | `CORE_TRAP_STORE_ACCESS_FAULT` | 是，data request |
| ECALL | `CORE_TRAP_ECALL` | 无 data request |

Misalignment 和 access fault 必须分开验证。前者由 core 在 request 之前发现；后者只有目标 memory 接受请求并返回 error 后才能知道。Sticky request monitor 用来捕获短暂 request，避免只在 trap 周期观察信号而漏掉之前已经发生的访问。

## 6. Memory model 的时序语义

Request 仅在上升沿满足 `req_valid && req_ready` 时被接受。Memory model 保存 payload，并在后续周期发出一个周期的 response。Core 必须遵守：

- ready 为0时保持 valid 和 payload；
- handshake 后进入 WAIT，不能重复发送同一请求；
- response 前不能 commit 对应 load/store；
- store 只修改 `wstrb` 选择的 byte lanes；
- misaligned 或超出 model 范围的访问返回 error，不索引数组外部。

当前 simple memory 通常保持 ready，并提供固定短延迟。它证明基本 request/response 分离，但不能替代随机 backpressure regression。

## 7. 永久协议检查

Core-level TB 应长期保留以下逐周期检查：

- reset 时 request、commit 和 halted 都无效；
- request 在 ready 前不会撤销或改变 payload；
- data request address 是 word aligned；
- read request 的 write strobe 为0；
- commit register write 不以 x0 为 destination；
- trap commit 不同时报告 register 或 memory side effect；
- HALT 不产生 request 或 commit；
- 同一 instruction 不产生重复 commit。

这些检查属于接口不变量，不应因为 directed program 改变而删除。

## 8. 回归命令

只运行正常程序：

```bash
make CAD_ENV=/path/to/env.sh test-reference-core
```

只运行 trap cases：

```bash
make CAD_ENV=/path/to/env.sh test-reference-core-trap
```

只运行 misaligned reset-PC case：

```bash
make CAD_ENV=/path/to/env.sh test-reference-core-reset-pc
```

运行三组 simulation、Verilator lint 和 Yosys structural synthesis check：

```bash
make CAD_ENV=/path/to/env.sh check-reference-core
```

顶层 `make test` 也包含三组 reference-core simulation，但不包含 lint 和 synthesis check。

## 9. 如何解释工具警告

Icarus Verilog 对 `always_comb` constant select 和 `unique case` 的提示属于工具支持限制，不表示仿真失败。Verilator 可能报告 testbench 中仅用于端口完整连接的 unused signal，以及故意留空的 output pin。Yosys 可能把 multiplier 内部 array 展开为 registers。

不能只因为 warning 看起来熟悉就忽略。每次新增 warning 都应确认来源；允许保留的 warning 应满足：

- 不涉及 latch、multiple driver、width truncation 或 combinational loop；
- 不改变可综合 RTL 行为；
- 对应信号确实只在特定 testbench 中不使用，或 output 故意不连接。

## 10. 后续验证增强

Reference core 的下一层验证可以按以下顺序增加：

1. 用 RISC-V GNU toolchain 将 assembly 链接到固定地址，并转换为 memory image；
2. 增加包含 loop、memory copy、RV32M corner case 和 trap termination 的程序级 smoke tests；
3. 让 memory model 随机延迟 ready/response，检查 backpressure 下 commit trace 不变；
4. 用相同程序比较 reference core 与 pipeline core 的 commit trace；
5. 接入 Spike 或兼容 RVFI 的 differential checker；
6. 运行适合当前 RV32IM/bare-metal 范围的 architectural tests，并记录明确的 pass/fail 配置。

这些增强应作为独立提交加入，并保留当前 directed regressions。Directed test 适合快速定位，program-level 和 differential test 负责扩大覆盖范围，两者用途不同。
