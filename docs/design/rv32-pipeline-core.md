# RV32IM 五级顺序流水线指南

本文档说明 `rtl/core/rv32_pipeline_core.sv` 的现有结构和行为。该 core 与 `rv32_reference_core` 使用相同的 instruction/data memory interface 和 architectural commit interface，因此后续可以对同一程序进行逐条退休比较。

## 1. 实现范围

当前 pipeline core 包含：

- RV32IM 整数指令执行；
- IF、ID、EX、MEM、WB 五级顺序流水线；
- 基于 `valid` 的 bubble、stall 和 flush 控制；
- RAW hazard detection、WB-to-ID bypass、EX/MEM 与 MEM/WB forwarding；
- branch、JAL 和 JALR 重定向；
- blocking instruction/data memory request；
- Radix-4 Booth multiplier 和 Radix-2 iterative divider；
- illegal instruction、ECALL、EBREAK、地址未对齐和 access fault；
- architectural commit 和 trap 后 sticky halt。

当前不包含 cache、branch prediction、interrupt、CSR、privileged trap entry、虚拟内存或乱序执行。Trap 会提交一次，然后 core 进入 HALT，而不是跳转到软件 trap handler。

## 2. 五级流水线保存什么

```mermaid
flowchart LR
    IF[IF: Fetch] --> IFID[if_id_q]
    IFID --> ID[ID: Decode / Regfile]
    ID --> IDEX[id_ex_q]
    IDEX --> EX[EX: ALU / Branch / RV32M]
    EX --> EXMEM[ex_mem_q]
    EXMEM --> MEM[MEM: LSU / Data response]
    MEM --> MEMWB[mem_wb_q]
    MEMWB --> WB[WB: Regfile / Commit]
```

四个 pipeline register 的类型定义在 `rtl/pkg/rv32_pipeline_pkg.sv`。每个 payload 都包含：

```systemverilog
logic        valid;
logic [31:0] pc;
logic [31:0] instr;
```

`valid=0` 表示 bubble。不能使用 `instr==0` 表示 bubble，因为 instruction bits 和 stage 是否拥有真实指令是两个独立概念。

| Payload | 保存的主要内容 | 下一阶段用途 |
|---|---|---|
| `if_id_q` | PC、instruction、fetch trap | ID decode |
| `id_ex_q` | source 地址/数据、immediate、ALU/RV32M/branch/memory control | EX execution |
| `ex_mem_q` | effective address、store value、执行结果、rd metadata | MEM operation |
| `mem_wb_q` | rd writeback、memory commit metadata、trap | WB 和 commit |

组合逻辑形成 `*_d`，唯一的主 `always_ff` 更新 `*_q`。因此同一上升沿的所有时序逻辑都读取旧的 `*_q`；刚写入某个 payload 的值要到上升沿后才成为新的 stage state。

## 3. IF：blocking instruction fetch

`fetch_pc_q` 保存下一次请求地址，`fetch_pending_q` 表示已经接受请求但尚未收到 response。一个正常 fetch 的过程是：

```text
没有 pending request，pipeline 可以接收
  → imem_req_valid_o=1，imem_req_addr_o=fetch_pc_q

imem_req_valid_o && imem_req_ready_i
  → fetch_pending_q=1

fetch_pending_q && imem_resp_valid_i
  → response 写入 if_id_q
  → fetch_pending_q=0
  → 正常响应时 fetch_pc_q += 4
```

以下情况停止发出新的 instruction request：

- reset 或 `halted_q`；
- 已有 trap 正在流水线中传播；
- 已有 fetch response outstanding；
- ID stall；
- EX redirect；
- MEM 或 RV32M blocking operation。

### 3.1 为什么需要 `fetch_discard_q`

Branch/JAL/JALR 在 EX 才确定 redirect。此时错误顺序路径的 fetch request 可能已经被 memory 接受，接口又没有取消请求的通道。因此 core：

1. 把 `fetch_pc_q` 改为 `ex_redirect_target`；
2. 清空 `if_id_q` 和 `id_ex_q`；
3. 如果旧请求仍 pending，置位 `fetch_discard_q`；
4. 旧 response 返回时只清除 pending/discard，不写入 IF/ID。

如果被丢弃的 response 同时报告 error，也不能产生 trap，因为它属于错误路径。

### 3.2 Instruction access fault

有效路径上的 `imem_resp_error_i` 会生成：

```text
if_id_q.valid      = 1
if_id_q.pc         = faulting fetch PC
if_id_q.instr      = 0
if_id_q.trap       = 1
if_id_q.trap_cause = CORE_TRAP_INSTRUCTION_ACCESS_FAULT
```

错误 response data 不被当作 instruction 使用。

## 4. ID：decode、regfile 和 ID/EX payload

ID 使用 `if_id_q.instr` 驱动：

- `rv32_decoder`；
- `rv32_imm_gen`；
- `rv32_regfile` 的两个读地址。

Decoder 给出 `rs1_used` 和 `rs2_used`，它们非常重要。某些 instruction bits 虽然与 rs1/rs2 位域重叠，但该指令语义并不读取对应寄存器；hazard 和 forwarding 都必须先检查 used flag。

### 4.1 WB-to-ID bypass

当 `mem_wb_q` 正在写回与 ID source 相同的寄存器时，`id_rs1_data_effective` 或 `id_rs2_data_effective` 直接选择 `mem_wb_q.rd_wdata`。这样不依赖 regfile 在同一个时钟边沿的读写行为。

### 4.2 ID trap

`id_trap` 的优先级是：

1. IF 已经携带的 fetch trap；
2. decoder 报告 illegal instruction；
3. ECALL；
4. EBREAK。

FENCE 是合法、无寄存器和 memory side effect 的 instruction，仍然会沿 pipeline 正常 commit。

## 5. RAW hazard 和 forwarding

### 5.1 Hazard detector

`rv32_hazard_unit` 把 IF/ID instruction 当作 consumer，把 ID/EX、EX/MEM 和 MEM/WB 当作 older producers。一个 source 形成 RAW dependency 需要同时满足：

```text
consumer valid
source used
source address != x0
producer valid
producer plans to write rd
producer rd == consumer source
producer data is not ready through a bypass path
```

`id_stall=1` 时：

- IF/ID 保持不动；
- ID/EX 写入 bubble；
- fetch 不发出新请求；
- 更老的 stage 继续前进。

参数 `ENABLE_FORWARDING=0` 用于验证纯 stall 路径；默认值为1。

### 5.2 EX forwarding

`rv32_forwarding_unit` 的 consumer 是 ID/EX instruction。每个 source 的选择顺序是：

```text
保存于 id_ex_q 的 regfile data
  → matching MEM/WB data
  → matching EX/MEM data
```

EX/MEM 优先于 MEM/WB，因为它是较新的 producer。Invalid producer、`rd_write=0`、unused source 和 x0 都不会触发 forwarding。

Load result 在 data response 返回后进入 MEM/WB；blocking MEM control 会让 dependent instruction 保留到该结果可以从 MEM/WB forward 的周期。

## 6. EX：ALU、control flow 和 RV32M

### 6.1 ALU operands

`ex_alu_lhs` 和 `ex_alu_rhs` 从 forwarded source、PC、zero 或 immediate 中选择。`rv32_alu` 产生 `ex_alu_result`。

普通 ALU instruction 把 result、rd address 和 write enable 写入 `ex_mem_d`。JAL/JALR 的 rd data 是 `id_ex_q.pc + 4`。

### 6.2 Branch、JAL 和 JALR

`rv32_branch_unit` 比较 forwarded operands。Target 由 ALU 计算：

| 类型 | Target |
|---|---|
| Branch | `pc + B-immediate` |
| JAL | `pc + J-immediate` |
| JALR | `(rs1 + I-immediate) & ~1` |

Taken branch、JAL 或 JALR 产生 `ex_redirect_valid`，清除年轻 payload 并把 fetch PC 改为 target。Not-taken branch 按 PC+4 继续。

RV32I instruction 必须4-byte aligned，因此 target 低两位必须为零。JALR 按规范先清除 bit 0，再检查 bit 1。Misaligned target 产生 instruction-address-misaligned trap，不执行 redirect，也不写 link register。

### 6.3 Multicycle RV32M

MUL/MULH/MULHSU/MULHU 使用 `rv32_multiplier`，DIV/DIVU/REM/REMU 使用 `rv32_divider`。请求被接受后，`muldiv_pending_q` 保持操作状态；在 response 之前：

- ID/EX 保持当前 M instruction；
- 不接受年轻 instruction；
- EX/MEM 不产生该 instruction 的结果；
- fetch 停止。

`muldiv_complete` 后结果进入 EX/MEM，之后按照普通 rd writeback 路径退休。当前 pipeline 同时只允许一个 multicycle M operation。

## 7. MEM：LSU 和 blocking data request

EX 已经计算 `effective_addr` 并保存原始 `store_value`。MEM 中的 `rv32_lsu` 负责：

- 把地址对齐到32-bit memory word；
- 生成 store byte mask 和 lane-aligned data；
- 根据 byte/half/word 选择 load bytes；
- 对 LB/LH sign-extend，对 LBU/LHU zero-extend；
- 报告地址是否满足访问宽度的 alignment。

### 7.1 Data handshake

对齐的 Load/Store 使用 `dmem_pending_q` 执行 blocking request：

```text
MEM instruction active，没有 pending request
  → 发出 dmem request

dmem_req_valid_o && dmem_req_ready_i
  → dmem_pending_q=1

dmem_pending_q && dmem_resp_valid_i
  → mem_complete=1
  → 正常结果或 access fault 进入 MEM/WB
```

等待 response 时，EX/MEM、ID/EX 和 IF/ID 保持不动，MEM/WB 不产生新的 commit。Store 也必须等待 response，不能在 request acceptance 时提前退休。

### 7.2 Misalignment 和 access fault

二者发生时刻不同：

| Fault | 检测时刻 | 是否发送 request |
|---|---|---|
| Load/Store address misaligned | request 之前 | 否 |
| Load/Store access fault | response 返回 error | 是 |

因此 `mem_trap` 先判断 `mem_misaligned`，再判断 `mem_complete && dmem_resp_error_i`。仅观察 error 信号不够，因为 error 只有在有效 response 周期才有意义。

## 8. WB 和 architectural commit

WB 只读取 `mem_wb_q`。Regfile 写入条件是：

```systemverilog
mem_wb_q.valid && !mem_wb_q.trap && mem_wb_q.rd_write
```

Commit interface 报告同一个 payload：

| 输出组 | 含义 |
|---|---|
| `commit_valid/pc/instr` | 退休 instruction 的身份 |
| `commit_rd_*` | architectural register side effect |
| `commit_mem_*` | load/store address、mask 和 data |
| `commit_trap/cause` | 同步异常及原因 |

写 x0 的 instruction 仍然可以正常 commit，但 `commit_rd_write_o=0`。Trap commit 的 register 和 memory side-effect fields 都为零。

## 9. 精确异常

Trap 可以在不同 stage 被发现：

| Stage | Cause |
|---|---|
| IF | instruction access fault |
| ID | illegal instruction、ECALL、EBREAK |
| EX | branch/JAL/JALR target misaligned |
| MEM | load/store address misaligned、load/store access fault |

精确异常要求：

1. faulting instruction 之前的 older instructions 可以正常退休；
2. faulting instruction 不产生普通 register/memory side effect；
3. faulting instruction 之后的 younger instructions 被清除；
4. trap 只 commit 一次，并携带 faulting PC、instruction 和 cause；
5. trap commit 后 `halted_o` 保持为1，不再发请求或 commit。

`trap_inflight` 在 trap 尚未到达 WB 时停止新的 fetch。已经发出但属于年轻路径的 instruction response 会被丢弃。

## 10. 主时序控制的优先级

理解 `always_ff` 时，不要把所有 `if` 看成互不相关的局部更新。它们共同决定当前周期哪一级可以移动。总体优先级是：

```text
reset
  → trap 已到 MEM/WB：提交后进入 HALT
  → MEM active：misalignment/access fault、response complete 或继续等待
  → RV32M active：complete 或继续等待
  → EX trap
  → EX redirect
  → ID RAW stall
  → normal pipeline movement
```

Memory 和 RV32M 放在普通 movement 之前，是因为它们可能需要保持同一 instruction 多个周期。Trap 和 redirect 清除年轻 payload；stall 只保持 consumer 并允许 older instructions 前进。

## 11. 验证结构

| Testbench | 主要覆盖内容 |
|---|---|
| `tb/unit/rv32_hazard_unit_tb.sv` | RAW matching、readiness、x0、unused source |
| `tb/unit/rv32_forwarding_unit_tb.sv` | producer selection、priority、独立 rs1/rs2 |
| `tb/core/rv32_pipeline_core_tb.sv` | fetch handshake、逐 stage movement、basic commit |
| `tb/core/rv32_pipeline_hazard_tb.sv` | forwarding disabled 时的真实 stall |
| `tb/core/rv32_pipeline_forwarding_tb.sv` | EX forwarding 和零 RAW stall |
| `tb/core/rv32_pipeline_control_flow_tb.sv` | branch/JAL/JALR、flush、stale response discard |
| `tb/core/rv32_pipeline_memory_tb.sv` | byte/half/word load/store、extension、MEM blocking |
| `tb/core/rv32_pipeline_muldiv_tb.sv` | 八种 RV32M operation、request/response、pipeline freeze |
| `tb/core/rv32_pipeline_trap_tb.sv` | system、misalignment、access fault、precise flush、sticky halt |

运行全部 pipeline regression：

```bash
make check-pipeline
```

如果工具需要环境脚本：

```bash
make CAD_ENV=/path/to/env.sh check-pipeline
```

`iverilog` 关于 `always_*` constant select sensitivity 的 `sorry` 信息是该仿真器的已知限制；测试 PASS 与真正的 error/fatal 才决定 regression 结果。

## 12. 阅读代码的方法

第一次阅读 `rv32_pipeline_core.sv` 时，可以选择一条 instruction，按下面顺序追踪：

1. 在 `if_id_q` 找到 PC 和 machine word；
2. 查看 decoder 产生哪些 control fields；
3. 查看这些 fields 如何写入 `id_ex_d`；
4. 查看 forwarding 后的 operands 和 `ex_alu_result`；
5. 查看 `ex_mem_d` 保存的是 ALU result 还是 memory metadata；
6. 如果是 memory operation，追踪 request、pending、response 和 `mem_wb_d`；
7. 最后比较 `mem_wb_q`、regfile write 和 commit outputs。

遇到错误时先问三个问题：当前 instruction 在哪个 `*_q`，该 stage 的 `valid` 是否为1，以及本周期是否被 MEM、RV32M、trap、redirect 或 stall 阻塞。这样比一次阅读整个主 `always_ff` 更容易定位问题。

## 13. 后续工作边界

当前 core 是经过 directed regression 和基础 reference-vs-pipeline commit differential test 的五级顺序 baseline，但这不等于已经完成 ISA compliance 或性能研究。进入 cache/OoO 之后仍应逐步增加：

- 覆盖更多程序和不同 memory latency 的 commit-level differential checking；
- assembler/ELF-to-memory-image 流程；
- 更长的 bare-metal program tests；
- 随机 instruction 和随机 memory latency regression；
- Spike、Sail 或兼容 RVFI 的外部模型 differential checking；
- Verilator lint、Yosys synthesis 和 OpenROAD timing baseline。

这些验证应复用现有 commit interface，而不改变已经验证的 pipeline stage semantics。
