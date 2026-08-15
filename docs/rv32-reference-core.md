# RV32IM 多周期 Reference Core 开发教程

本文档说明如何把已经完成的 decoder、immediate generator、regfile、ALU、branch unit、LSU、multiplier 和 divider 组合成第一颗能够运行程序的 RV32IM CPU。它描述目标接口、逐周期状态变化、每类指令的数据通路、commit 语义、测试方法和推荐实现顺序。

Reference core 的重点是架构正确性，不是性能。它一次只处理一条指令，因此没有 pipeline hazard、forwarding、branch prediction、register renaming、ROB 或乱序调度。Pipeline core 使用相同 commit 输出，未来的 OoO core 也将复用该接口进行差分验证。

## 1. 这一阶段最终要得到什么

完成后的 core 应当能够：

- 从 `RESET_PC` 开始取32位指令；
- 执行项目支持的全部 RV32I 指令；
- 执行 `MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU`；
- 发出 load/store 请求并等待可变延迟响应；
- 保持 `x0=0`；
- 对 misalignment、access fault、illegal instruction、ECALL 和 EBREAK 产生 trap commit；
- 每完成一条指令产生一次 commit；
- 在 trap commit 后进入 HALT，等待 reset；
- 在 memory ready 或 response 被延迟时保持请求和架构状态正确。

Reference core 不需要 cache。最初连接的是 `rv32_simple_memory`。以后可以在不修改 core 指令语义的情况下，把同一组 instruction/data ports 接到 L1 I-cache 和 L1 D-cache。

## 2. 为什么先做多周期 core

单元测试只能证明模块独立工作。例如 ALU 能算加法、decoder 能识别 ADDI、regfile 能写寄存器，但还没有证明以下完整链路：

```text
memory instruction
       ↓
fetch → decode → register read → execute → writeback → commit
```

多周期 core 每次只保留一条在途指令，可以先解决接口和指令语义问题。出现错误时通常只需要检查当前状态、PC、instruction、两个源操作数、运算结果和待提交信息。五级流水线则会同时存在多条指令，还必须处理 forwarding、stall、flush 和不同流水级之间的 valid bit，不适合作为第一次系统集成。

## 3. 文件职责

| 文件 | 职责 |
|---|---|
| `rtl/pkg/rv32_core_pkg.sv` | core 与 TB 共用的 trap cause 类型 |
| `rtl/core/rv32_reference_core.sv` | 多周期状态机、PC、模块实例、写回和 commit |
| `tb/model/rv32_simple_memory.sv` | 仿真用 instruction/data memory request-response model |
| `tb/core/rv32_reference_core_tb.sv` | 正常程序、commit checker、timeout 和 final-state checks |
| `tb/core/rv32_reference_core_trap_tb.sv` | illegal、system、misalignment 和 access-fault tests |
| `tb/core/rv32_reference_core_reset_pc_tb.sv` | 独立验证不对齐 `RESET_PC` 在取指前产生 trap |
| `rtl/frontend/rv32_decoder.sv` | RV32I、RV32M 和 system decode control |
| `Makefile` | 独立 compile/test/lint/synth 及统一 reference-core 检查入口 |

## 4. Memory interface

Reference core 使用两个独立端口：

```text
instruction port：只读，用于取指
data port：读写，用于 load/store
```

每个端口采用 request/response 协议，并且同一端口最多只有一个未完成请求。

### 4.1 请求何时被接受

请求在时钟上升沿满足以下条件时被接受：

```text
req_valid && req_ready
```

在接受之前，发送方必须保持以下信号不变：

```text
instruction：req_valid, req_addr
data：req_valid, req_addr, req_write, req_wdata, req_wstrb
```

错误写法是只把 `req_valid` 拉高一个周期，然后不管 `req_ready` 是否为1都撤销。这样 memory 如果正忙，请求就永久丢失。

正确的请求状态伪代码：

```text
FETCH_REQUEST:
    imem_req_valid = 1
    imem_req_addr  = pc
    if imem_req_ready:
        state = FETCH_WAIT
```

### 4.2 为什么 request 和 response 分开

`req_ready` 只表示 memory 接收了地址，不表示数据已经返回：

```text
cycle N:     req_valid=1, req_ready=1  → request accepted
cycle N+1:   resp_valid=0              → memory still working
cycle N+2:   resp_valid=1              → response available
```

Core 接受 request 后必须进入 WAIT 状态，不能重复发送同一请求。

### 4.3 response 没有 ready

当前接口没有 `resp_ready`。Memory 在 `resp_valid=1` 的周期给出结果，core 必须捕获。这个约束与现有 multiplier/divider 接口一致。初版 core 只有一个未完成请求，因此始终有能力接收响应。

### 4.4 Instruction port

Instruction port 信号：

| 信号 | 方向 | 含义 |
|---|---|---|
| `imem_req_valid_o` | core→memory | 取指请求有效 |
| `imem_req_ready_i` | memory→core | 本周期能够接受请求 |
| `imem_req_addr_o` | core→memory | 指令字节地址，必须4字节对齐 |
| `imem_resp_valid_i` | memory→core | 返回指令有效 |
| `imem_resp_data_i` | memory→core | 32位指令 |
| `imem_resp_error_i` | memory→core | instruction access fault |

收到正常 response 后：

```text
instr_q = imem_resp_data_i
state   = EXECUTE
```

收到 error response 后不能执行返回数据，应准备 `CORE_TRAP_INSTRUCTION_ACCESS_FAULT`。

### 4.5 Data port

Data port 始终传输一个对齐的32位 word：

| 信号 | 含义 |
|---|---|
| `dmem_req_addr_o` | `{effective_addr[31:2], 2'b00}` |
| `dmem_req_write_o` | 1为store，0为load |
| `dmem_req_wdata_o` | LSU 已移动到正确 byte lane 的store数据 |
| `dmem_req_wstrb_o` | 每一位控制对应 byte lane 是否写入 |
| `dmem_resp_rdata_i` | load 返回的完整32位 word |

例如地址 `0x1001` 上的 `SB x5, 0(x1)`：

```text
dmem_req_addr  = 0x1000
dmem_req_wdata = {16'b0, x5[7:0], 8'b0}
dmem_req_wstrb = 4'b0010
```

LSU 已经实现这些格式转换。Core 的职责是保存 decode control 和 effective address，直到 data response 到达。

## 5. Commit interface

Commit 表示一条指令的所有架构效果已经确定，并且不会再被取消。Reference core 每条非 trap 指令产生一个周期的 `commit_valid_o`；trap 也产生一次 commit，然后进入 HALT。

### 5.1 基本字段

| 字段 | 含义 |
|---|---|
| `commit_pc_o` | 这条指令原始 PC，不是 next PC |
| `commit_instr_o` | 从 memory 取得的原始32位指令 |
| `commit_rd_write_o` | 是否真的写架构寄存器，写 x0 时必须为0 |
| `commit_rd_addr_o` | destination register |
| `commit_rd_wdata_o` | 写回数据 |

即使 branch、store 或 FENCE 不写寄存器，它们仍然必须 commit，否则 TB 无法知道程序执行到了哪里。

### 5.2 Memory 字段

| 字段 | load | store | 非 memory |
|---|---|---|---|
| `commit_mem_valid_o` | 1 | 1 | 0 |
| `commit_mem_write_o` | 0 | 1 | 0 |
| `commit_mem_addr_o` | 对齐后的word地址 | 对齐后的word地址 | 0 |
| `commit_mem_rmask_o` | 被读取的byte lanes | 0 | 0 |
| `commit_mem_wmask_o` | 0 | 实际写入的byte lanes | 0 |
| `commit_mem_rdata_o` | memory返回的word | 0 | 0 |
| `commit_mem_wdata_o` | 0 | lane对齐后的store word | 0 |

保留 mask 和原始 memory word，使未来 differential checker 能独立重新计算 load extraction 和 store side effect。

### 5.3 Trap 字段

```text
commit_valid_o      = 1
commit_trap_o       = 1
commit_trap_cause_o = 对应cause
commit_rd_write_o   = 0
commit_mem_valid_o  = 0
```

本项目当前没有 privileged CSR 和 `mtvec`，因此 trap commit 后进入 HALT。Reset 才能重新启动。

## 6. 状态机

推荐状态序列：

```text
RESET
  ↓
FETCH_REQUEST ──accepted──> FETCH_WAIT
                                │
                         response received
                                ↓
                             EXECUTE
                      ┌─────────┼──────────┐
                      │         │          │
                    simple    memory     mul/div
                      │         │          │
                      │    DATA_REQUEST  MULDIV_REQUEST
                      │         ↓          ↓
                      │    DATA_WAIT     MULDIV_WAIT
                      │         │          │
                      └─────────┴──────────┘
                                ↓
                              COMMIT
                                ↓
                         FETCH_REQUEST
```

错误路径进入：

```text
TRAP → HALT
```

### 6.1 哪些值必须跨周期保存

如果一个值在产生后的下一个周期仍会使用，就必须进入寄存器。至少包括：

- `pc_q`：下一次取指地址；
- `instr_q`：当前指令；
- pending next PC；
- pending destination register、write enable 和 writeback value；
- memory operation、effective address、size、unsigned 标志和 store数据；
- commit memory fields；
- pending trap cause；
- mul/div operation 和操作数，直到请求被接受。

不能在 DATA_WAIT 中继续直接依赖 decoder 的组合输出，除非 `instr_q` 和所有相关输入在整个等待期间明确保持不变。为了让状态职责清楚，推荐在 EXECUTE 结束时保存 pending control。

## 7. PC 更新规则

| 指令类型 | next PC |
|---|---|
| 普通 ALU/load/store/mul/div/system | `pc + 4` |
| branch not taken | `pc + 4` |
| branch taken | `pc + immediate` |
| JAL | `pc + immediate` |
| JALR | `(rs1 + immediate) & 32'hffff_fffe` |

没有 C extension，因此真正取指地址必须满足：

```text
next_pc[1:0] == 2'b00
```

JALR 只强制清除 bit0，bit1 仍可能为1。若最终 target 不是4字节对齐，应产生 instruction-address-misaligned trap，不能发出错误取指请求。

PC 推荐在 COMMIT 时更新，而不是 EXECUTE 时更新。这样在 memory stall 或 mul/div stall 期间，当前指令 PC 保持不变，commit 也能报告正确 PC。

## 8. 各类指令的数据通路

### 8.1 ALU register-register

```text
rs1 → ALU lhs
rs2 → ALU rhs
ALU result → pending writeback → rd
next PC = PC + 4
```

### 8.2 ALU immediate

```text
rs1 → ALU lhs
immediate → ALU rhs
```

Shift immediate 仍由 ALU 使用低5位 shift amount。

### 8.3 LUI 与 AUIPC

Decoder 已通过 operand selection 统一它们：

```text
LUI:   0  + U-immediate
AUIPC: PC + U-immediate
```

Reference core 不需要单独的 LUI/AUIPC 算术模块。

### 8.4 Branch

Branch unit 只产生 condition taken。Core 还需要选择 next PC：

```text
branch_taken ? PC + B-immediate : PC + 4
```

Branch 不写 rd，但仍进入 COMMIT。

### 8.5 JAL/JALR

```text
rd writeback = PC + 4
next PC JAL  = PC + J-immediate
next PC JALR = (rs1 + I-immediate) & ~1
```

### 8.6 Load/store

EXECUTE 中先计算：

```text
effective_addr = rs1 + immediate
```

然后 LSU 产生 aligned address、store word、store mask、misaligned 和 load extraction。Load 在 response 到达后才能得到最终 `load_value_o`。Store 在 memory acknowledgement 到达后才能 commit；不能在 request accepted 时就提前 commit。

### 8.7 Multiply/divide

RV32M 集成使用 decoder 的 `muldiv_op_o`：

```text
funct7 == 7'b0000001
funct3 选择 MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU
```

Reference core 在 `MULDIV_REQUEST` 中只向对应执行单元发送一次请求：

```text
MUL family → rv32_multiplier
DIV/REM family → rv32_divider
```

请求被 `req_valid && req_ready` 接受后进入 `MULDIV_WAIT`。收到 `resp_valid` 后保存 result，再进入 COMMIT。即使 multiplier 能每周期接受请求，reference core 仍然一次只发送一条。

## 9. Trap 与 system 行为

| 条件 | Cause |
|---|---|
| fetch PC未4字节对齐 | instruction address misaligned |
| instruction response error | instruction access fault |
| decoder `illegal_o=1` | illegal instruction |
| taken branch/JAL/JALR target未4字节对齐 | instruction address misaligned |
| LSU load misaligned | load address misaligned |
| LSU store misaligned | store address misaligned |
| load response error | load access fault |
| store response error | store access fault |
| ECALL | ECALL |
| EBREAK | breakpoint |

FENCE 在单请求、顺序、blocking memory reference core 中不需要额外硬件动作。它仍然正常 commit，确保此前 store 已经收到 acknowledgement；这一点由“一次只执行一条指令”自然保证。

## 10. 开发里程碑

每个里程碑完成后保留已有测试，后续功能不能删除早期检查。

### RC1：Reset 与 instruction fetch

修改文件：

```text
rtl/core/rv32_reference_core.sv
tb/model/rv32_simple_memory.sv
tb/core/rv32_reference_core_tb.sv
```

Core 要完成：

- reset 设置 `pc_q=RESET_PC`；
- reset 期间所有 request、commit 和 halted 输出无效；
- reset 释放后进入 FETCH_REQUEST；
- `imem_req_valid_o=1`，地址保持为 `pc_q`；
- ready 为0时持续保持请求；
- handshake 后只等待 response，不重复请求；
- response 到达时保存 instruction；
- error 或 PC misaligned 准备 trap。

Memory model 要完成 MEM1：接受取指并在后续周期返回一个 response pulse。

TB 必须检查：

- reset 跨越上升沿；
- 首次请求地址等于 RESET_PC；
- ready 延迟时 valid/address 保持；
- 每次 request 只被接受一次；
- response 前不出现 commit；
- instruction 被保存后离开 FETCH_WAIT。

RC1 暂时不执行指令，可以让 EXECUTE 保持不动。测试重点只在 fetch protocol。

### RC2：Decode、register read 和 operand selection

RC2 只建立组合数据通路，不更新 `pc_q`、不写 regfile、不进入 `CORE_STATE_COMMIT`。取指完成后，`instr_q` 在 `CORE_STATE_EXECUTE` 保持不变，下面的模块会持续产生与当前指令对应的组合结果。

本文件使用的实际信号名如下：

| 来源 | `rv32_reference_core.sv` 信号 | 去向 |
|---|---|---|
| `instr_q` | `rs1_addr`、`rs2_addr`、`rd_addr` | decoder 输出、regfile 地址 |
| decoder | `imm_kind` | `rv32_imm_gen.kind_i` |
| decoder | `alu_op` | `rv32_alu.op_i` |
| decoder | `operand_a_sel`、`operand_b_sel` | ALU operand mux |
| regfile | `rs1_data`、`rs2_data` | operand mux 和 branch unit |
| immediate generator | `imm` | `OP_B_IMM` 路径 |
| operand mux | `alu_lhs`、`alu_rhs` | `rv32_alu` |
| ALU | `alu_result` | RC3 的 pending writeback input |
| branch unit | `branch_taken` | RC4 使用 |

模块实例必须写在 module scope，不能放进 `always_ff`。连接顺序是：

```text
instr_q → decoder → rs1_addr/rs2_addr → regfile → rs1_data/rs2_data
       └→ decoder → imm_kind → imm_gen → imm
       └→ decoder → alu_op/operand select → mux → alu_lhs/alu_rhs → alu_result
```

在只搭建 RC2 组合数据通路、还未加入 RC3 写回时，regfile 写端可以临时连接常量：

```systemverilog
.we_i(1'b0),
.waddr_i(5'd0),
.wdata_i(32'd0)
```

`alu_lhs` 的选择必须对应实际 enum：`OP_A_RS1` 选择 `rs1_data`，`OP_A_PC` 选择 `pc_q`，`OP_A_ZERO` 选择零。`alu_rhs` 中 `OP_B_RS2` 选择 `rs2_data`，`OP_B_IMM` 选择 `imm`。两个 mux 都是组合逻辑，并且必须先设置默认值，避免遗漏分支产生 latch。

RC2 的 TB 在 core 捕获指令并进入 `CORE_STATE_EXECUTE` 后检查 hierarchy signal。例如 `32'h0050_0093`（`addi x1, x0, 5`）应产生：

```text
rs1_addr=0, rd_addr=1, rs1_used=1, rs2_used=0
alu_op=ALU_ADD, operand_a_sel=OP_A_RS1, operand_b_sel=OP_B_IMM
imm_kind=IMM_I, imm=5, alu_lhs=0, alu_rhs=5, alu_result=5
reg_write=1, illegal=0, commit_valid_o=0
```

I-type 的 instruction bits `[24:20]` 属于 immediate，但 `rs2_addr` 仍会直接提取这五位，因此不要要求 `rs2_addr=0`；应检查 `rs2_used=0`。

### RC3：第一批可 commit 指令

RC3 让下列、且仅下列普通 ALU 指令从 `CORE_STATE_EXECUTE` 进入 `CORE_STATE_COMMIT`：

```text
LUI AUIPC
ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI
ADD SUB SLL SLT SLTU XOR SRL SRA OR AND
```

Branch、JAL/JALR、load/store、system、illegal 和 RV32M 不属于 RC3，不能被当前 EXECUTE 分支误当作 ALU 指令提交。

#### RC3.1 当前值和 pending 值不是一回事

在 `CORE_STATE_EXECUTE` 周期，decoder 和 ALU 产生的是当前组合值：

```text
reg_write, rd_addr, alu_result, pc_q
```

进入 `CORE_STATE_COMMIT` 后需要继续使用这些值，所以必须在 EXECUTE 结束的上升沿保存到实际寄存器：

| EXECUTE 组合值 | 跨周期寄存器 | COMMIT 用途 |
|---|---|---|
| `reg_write && rd_addr != 5'd0` | `pending_rd_write_q` | 是否真的写架构寄存器 |
| `rd_addr` | `pending_rd_addr_q` | regfile 和 commit destination |
| `alu_result` | `pending_rd_wdata_q` | regfile 和 commit write data |
| `pc_q + 32'd4` | `pending_next_pc_q` | COMMIT 结束时更新 PC |

后缀 `_q` 表示 flip-flop 输出。这四个信号只能在 `always_ff @(posedge clk_i)` 中使用非阻塞赋值 `<=` 修改。

#### RC3.2 第一步：reset pending 寄存器

在现有 `if (rst_i)` 分支中，紧跟 `state_q`、`pc_q` 和 `instr_q` 的 reset 赋值，加入：

```systemverilog
pending_rd_write_q <= 1'b0;
pending_rd_addr_q <= 5'd0;
pending_rd_wdata_q <= 32'd0;
pending_next_pc_q <= RESET_PC;
```

这一步发生在 reset 有效的上升沿。只声明 pending 信号而不 reset，会让 commit 和 regfile write control 在仿真开始时携带 `X`。

#### RC3.3 第二步：驱动 regfile 写端

RC2 中 regfile 写端使用常量。RC3 改为连接已经声明的实际信号：

```text
rv32_regfile.we_i    ← regfile_we
rv32_regfile.waddr_i ← regfile_waddr
rv32_regfile.wdata_i ← regfile_wdata
```

这三个信号必须在 module scope 驱动，不能只声明：

```systemverilog
assign regfile_we = (state_q == CORE_STATE_COMMIT) && pending_rd_write_q;
assign regfile_waddr = pending_rd_addr_q;
assign regfile_wdata = pending_rd_wdata_q;
```

`regfile_we` 只在整个 COMMIT 周期为1。Regfile 自己的 `always_ff` 会在 COMMIT 周期结束的上升沿看到 `we_i=1`，并写入 `regfile_waddr/regfile_wdata`。

#### RC3.4 第三步：限制 EXECUTE 可提交的指令类型

进入 pending capture 之前，先判断当前指令确实属于 RC3。判断使用当前文件中的 decoder 输出：

```text
illegal == 0
control_flow == rv32_pkg::CF_NONE
mem_op == rv32_pkg::MEM_NONE
system_op == rv32_pkg::SYS_NONE
writeback_sel == rv32_pkg::WB_ALU
reg_write == 1
```

只有全部满足时，`CORE_STATE_EXECUTE` 才执行：

```systemverilog
pending_rd_write_q <= reg_write && rd_addr != 5'd0;
pending_rd_addr_q <= rd_addr;
pending_rd_wdata_q <= alu_result;
pending_next_pc_q <= pc_q + 32'd4;
state_q <= CORE_STATE_COMMIT;
```

按里程碑实现时，RC3 尚未接入的指令不应落入 ALU commit 分支；RC4、RC5、RC6 和 RC7 会分别为这些类型增加明确出口。不能在没有分类判断的情况下无条件进入 COMMIT，否则 branch、store 甚至 illegal instruction 都会被错误地当作 ALU 指令退休。

`rd_addr==0` 时仍然进入 COMMIT，因为写 x0 的指令仍然是一条已经执行完成的指令；但是 `pending_rd_write_q` 必须为0。

#### RC3.5 第四步：驱动 commit 输出

Commit 有效条件只来自状态：

```systemverilog
assign commit_valid_o = (state_q == CORE_STATE_COMMIT);
assign commit_pc_o = pc_q;
assign commit_instr_o = instr_q;
assign commit_rd_write_o = commit_valid_o && pending_rd_write_q;
assign commit_rd_addr_o = pending_rd_addr_q;
assign commit_rd_wdata_o = pending_rd_wdata_q;
```

`commit_rd_write_o` 使用 `commit_valid_o` gating，使 FETCH/EXECUTE 等无效周期不会残留一个看起来有效的 write enable。RC3 不处理 memory 和 trap，因此 `commit_mem_*`、`commit_trap_o` 继续保持安全值0。

#### RC3.6 第五步：COMMIT 更新 PC

`CORE_STATE_COMMIT` 的时序逻辑只负责结束当前指令：

```systemverilog
CORE_STATE_COMMIT: begin
  pc_q <= pending_next_pc_q;
  state_q <= CORE_STATE_FETCH_REQUEST;
end
```

不要在 EXECUTE 更新 `pc_q`。在 COMMIT 结束时统一更新，可以保证整个 EXECUTE/COMMIT 期间 `commit_pc_o=pc_q` 仍指向当前指令，而不是下一条指令。

#### RC3.7 一个 ADDI 实际跨过哪些周期

假设 `instr_q` 是 `addi x1, x0, 5`，在进入 EXECUTE 前有：

```text
pc_q=0, rd_addr=1, alu_result=5, reg_write=1
```

| 时刻 | 上升沿之前的状态 | 这个上升沿发生什么 | 上升沿之后可观察到什么 |
|---|---|---|---|
| E | `CORE_STATE_EXECUTE` | pending registers 捕获 rd=1/data=5/next_pc=4；`state_q<=COMMIT` | `commit_valid_o=1`，commit fields 报告 PC=0、rd=1、data=5；`regfile_we=1` |
| C | `CORE_STATE_COMMIT` | regfile 的 `always_ff` 写入 x1=5；core 执行 `pc_q<=4`、`state_q<=FETCH_REQUEST` | commit 结束，PC=4，开始请求下一条指令 |

同一个上升沿的所有 `always_ff` 都读取上升沿之前的旧值。所以上表 C 时刻，regfile 能看到旧的 `state_q==CORE_STATE_COMMIT` 和已经保存好的 pending 数据；上升沿之后状态才变为 FETCH_REQUEST。

#### RC3.8 TB 如何证明写回真的发生

第一段程序示例：

```asm
addi x1, x0, 5
addi x2, x1, 3
add  x3, x1, x2
```

对应的 memory 初始化为：

```systemverilog
memory_model.write_word(32'h0000_0000, 32'h0050_0093);
memory_model.write_word(32'h0000_0004, 32'h0030_8113);
memory_model.write_word(32'h0000_0008, 32'h0020_81b3);
```

TB 等待三次 `commit_valid`，逐次检查：


```text
commit 1: commit_pc=0x0, commit_instr=0x00500093, commit_rd_write=1, commit_rd_addr=1, commit_rd_wdata=5
commit 2: commit_pc=0x4, commit_instr=0x00308113, commit_rd_write=1, commit_rd_addr=2, commit_rd_wdata=8
commit 3: commit_pc=0x8, commit_instr=0x002081b3, commit_rd_write=1, commit_rd_addr=3, commit_rd_wdata=13
```

第二条读取第一条写入的 x1，第三条读取前两条写入的 x1/x2。因此得到13不仅验证 ALU，也验证 regfile write 发生在正确的 COMMIT 边沿。在 RC3 的独立测试中，第三次 commit 检查完成后可以直接 `$finish`，无需用尚未接入该阶段的 EBREAK 结束程序。

RC3 完成条件：连续三条指令产生且只产生三次 commit，PC 序列为0/4/8，写回数据为5/8/13，第三次 commit 后没有重复 commit，lint 中不再出现 `regfile_we/regfile_waddr/regfile_wdata` 的 `UNDRIVEN`。

### RC4：Control flow

RC4 让 `rv32_reference_core` 能够执行以下控制流指令：

```text
BEQ BNE BLT BGE BLTU BGEU
JAL
JALR
```

这一阶段只修改：

```text
rtl/core/rv32_reference_core.sv
tb/core/rv32_reference_core_tb.sv
```

`rv32_pkg.sv`、`rv32_decoder.sv`、`rv32_imm_gen.sv` 和 `rv32_branch_unit.sv` 已经提供 RC4 需要的类型、译码、立即数和比较结果，不需要重新实现。RC4 的任务是让 core 使用这些现有输出计算 `pending_next_pc_q`，并为 JAL/JALR 保存 link value。

#### RC4.1 先理解现有信号已经算出了什么

Decoder 对三类控制流指令产生以下组合输出：

| 指令 | `control_flow` | `alu_lhs` | `alu_rhs` | `alu_result` | `branch_taken` | `writeback_sel` |
|---|---|---|---|---|---|---|
| conditional branch | `CF_BRANCH` | `pc_q` | B-immediate | `pc_q + imm`，即 taken target | 比较 `rs1_data` 和 `rs2_data` | `WB_ALU`，但 `reg_write=0` |
| JAL | `CF_JAL` | `pc_q` | J-immediate | `pc_q + imm`，即 jump target | 不使用 | `WB_PC_PLUS_4` |
| JALR | `CF_JALR` | `rs1_data` | I-immediate | `rs1_data + imm`，尚未清除 bit 0 | 不使用 | `WB_PC_PLUS_4` |

因此 core 不需要再写一套 branch adder 或 jump adder。现有 ALU 已经给出了 target。`branch_unit` 只回答条件是否成立；它不修改 PC。

三类指令最终需要保存的值是：

| 指令 | `pending_rd_write_q` | `pending_rd_addr_q` | `pending_rd_wdata_q` | `pending_next_pc_q` |
|---|---:|---|---|---|
| branch not taken | `0` | `0` | `0` | `pc_q + 4` |
| branch taken | `0` | `0` | `0` | `alu_result` |
| JAL | `reg_write && rd_addr != 0` | `rd_addr` | `pc_q + 4` | `alu_result` |
| JALR | `reg_write && rd_addr != 0` | `rd_addr` | `pc_q + 4` | `{alu_result[31:1], 1'b0}` |

Branch 没有目的寄存器，所以它仍然需要产生一次 commit，但不能写 regfile。JAL/JALR 同时产生两个不同的值：target 写入 `pending_next_pc_q`，旧 PC 加4作为 link value 写入 rd。不能把 `alu_result` 同时用于这两项，因为此时 `alu_result` 是 target，不是 link value。

#### RC4.2 修改 `CORE_STATE_EXECUTE` 的分类

保留 RC3 已经完成的普通 ALU 分支，在它后面增加三种 `control_flow` 情况。可以把 EXECUTE 理解为以下分类，变量名全部对应当前 `rv32_reference_core.sv`：

```text
如果 illegal == 0、mem_op == MEM_NONE、system_op == SYS_NONE：

  control_flow == CF_NONE：
    保留 RC3 的 WB_ALU + reg_write 处理

  control_flow == CF_BRANCH：
    不写 rd
    branch_taken == 1 时 next PC 使用 alu_result
    branch_taken == 0 时 next PC 使用 pc_q + 4
    保存 pending 值后进入 CORE_STATE_COMMIT

  control_flow == CF_JAL：
    rd 写入 pc_q + 4
    next PC 使用 alu_result
    保存 pending 值后进入 CORE_STATE_COMMIT

  control_flow == CF_JALR：
    rd 写入 pc_q + 4
    next PC 使用 {alu_result[31:1], 1'b0}
    保存 pending 值后进入 CORE_STATE_COMMIT
```

这里仍然不要在 EXECUTE 直接修改 `pc_q`。所有类型都只修改 `pending_next_pc_q`；现有 `CORE_STATE_COMMIT` 在下一拍统一执行：

```systemverilog
pc_q <= pending_next_pc_q;
```

这样 `commit_pc_o` 在整个 COMMIT 周期仍然是当前指令的 PC，而不是已经跳转后的 PC。

#### RC4.3 Branch 为什么也必须进入 COMMIT

以位于 `0x0000_0008` 的 `beq x1, x2, +8` 为例：

```text
branch_taken = 1  -> pending_next_pc_q = 0x0000_0010
branch_taken = 0  -> pending_next_pc_q = 0x0000_000c
pending_rd_write_q = 0
state_q = CORE_STATE_COMMIT
```

即使 branch 不写寄存器，它仍然是一条已经执行完成的架构指令，所以要产生一次 `commit_valid_o`。差分测试需要这次 commit 来判断核心是否执行了该 branch。COMMIT 周期中应看到：

```text
commit_valid_o    = 1
commit_pc_o       = branch 自己的 pc_q
commit_instr_o    = branch 自己的 instr_q
commit_rd_write_o = 0
```

COMMIT 结束的上升沿才把 `pc_q` 更新为选定的 target 或 `pc_q + 4`。

#### RC4.4 JAL 和 JALR 为什么写 `pc_q + 4`

JAL/JALR 的 rd 保存返回地址。假设 `jal x4, +8` 位于 `0x18`：

```text
跳转目标 = 0x18 + 8 = 0x20
x4/link  = 0x18 + 4 = 0x1c
```

所以 EXECUTE 必须同时保存：

```text
pending_rd_wdata_q = pc_q + 4
pending_next_pc_q  = alu_result
```

如果 rd 是 x0，跳转仍然发生，但 `pending_rd_write_q` 必须为0。这正是无条件跳转伪指令 `j` 的硬件行为。

JALR 的 ALU 先算 `rs1_data + imm`。RISC-V 规定最终 target 的 bit0 必须清零，所以不能直接保存 `alu_result`，而应保存：

```text
{alu_result[31:1], 1'b0}
```

这项规则不是地址向下四字节对齐：它只清 bit0，不清 bit1。

#### RC4.5 四字节对齐检查

本项目没有实现 C extension，取指地址必须满足 `target[1:0] == 2'b00`。

- not-taken branch 使用 `pc_q + 4`，不检查未采用的 branch target；
- taken branch 检查 `alu_result[1:0]`；
- JAL 检查 `alu_result[1:0]`；
- JALR 先清 bit0，然后检查剩余的 bit1。

如果实际采用的 target 不对齐，不能进入 COMMIT，也不能发出该 target 的 instruction request。RC4 可以先进入已经存在的 `CORE_STATE_TRAP`，阻止错误取指；RC7 再补全 `commit_trap_o`、`commit_trap_cause_o` 和随后进入 HALT 的可见 trap 行为。因此 RC4 的正常程序测试只使用对齐 target，misaligned trap 的完整 commit 检查留到 RC7。

#### RC4.6 RC4 的逐拍时序

以 taken JAL 为例：

| 时刻 | 上升沿之前的状态 | 这个上升沿发生什么 | 上升沿之后可观察到什么 |
|---|---|---|---|
| E | `CORE_STATE_EXECUTE` | 保存 rd、`pc_q+4`、jump target；`state_q<=COMMIT` | `commit_valid_o=1`，commit 报告 JAL 本身的 PC 和 link value |
| C | `CORE_STATE_COMMIT` | regfile 写入 link；core 执行 `pc_q<=pending_next_pc_q` | commit 结束，从 jump target 发出下一次取指请求 |

Branch 的时序相同，只是 `pending_rd_write_q=0`。JALR 的时序也相同，只是 target 来自清除 bit0后的 `rs1_data+imm`。

#### RC4.7 扩展 `check_commit`

当前 TB 的 `check_commit` 把 `commit_rd_write` 固定要求为1，因此无法检查 branch。给 task 增加一个参数：

```text
expected_rd_write
```

然后把 task 内部固定的：

```text
commit_rd_write == 1
```

改成与 `expected_rd_write` 比较。RC3 的三个旧调用传入1，branch 调用传入0。旧测试必须保留，不能为了写 RC4 TB 删除 RC1～RC3 的检查。

#### RC4.8 推荐的第一组程序级测试

先使用一段只含正向跳转的短程序：

```asm
0x00: addi x1, x0, 1
0x04: addi x2, x0, 1
0x08: beq  x1, x2, +8      # taken，下一条是0x10
0x0c: addi x3, x0, 99      # 必须被跳过
0x10: addi x3, x0, 3
0x14: bne  x1, x2, +8      # not taken，下一条是0x18
0x18: jal  x4, +8           # x4=0x1c，下一条是0x20
0x1c: addi x5, x0, 99      # 必须被跳过
0x20: addi x6, x0, 45
0x24: jalr x7, x6, 0        # raw target=45，清bit0后跳到44(0x2c)，x7=0x28
0x28: addi x5, x0, 88      # 必须被跳过
0x2c: addi x8, x0, 8
```

期望 commit PC 序列是：

```text
0x00, 0x04, 0x08, 0x10, 0x14, 0x18, 0x20, 0x24, 0x2c
```

序列中不能出现 `0x0c`、`0x1c` 或 `0x28`。最终还应检查：

```text
x3 = 3
x4 = 0x1c
x5 = 0
x7 = 0x28
x8 = 8
```

这组测试分别证明 taken branch、not-taken branch、JAL link、JALR link、JALR bit0 clear，以及被跳过的指令没有产生副作用。之后再增加一个计数循环，用负 B-immediate 同时覆盖 backward taken 和最终 not-taken。

#### RC4.9 完成条件

满足以下全部条件后 RC4 才算完成：

1. RC3 的三条 ALU 指令仍然通过；
2. 六种 branch condition 至少在 branch-unit unit test 中全部通过；
3. core TB 同时出现 taken 和 not-taken branch；
4. commit PC 序列中没有被跳过的地址；
5. JAL/JALR 的 `commit_rd_wdata_o` 都是各自的 `pc_q + 4`；
6. JALR 奇数 raw target 的 bit0 被清除；
7. branch commit 的 `commit_rd_write_o` 为0；
8. 不对齐的实际 target 不会触发错误取指；
9. reference-core simulation、lint 和 Yosys synthesis check 全部通过。

### RC5：Load/store

先完成 memory model 的 MEM2/MEM3/MEM4，再接 core。

推荐顺序：

```text
LW/SW
LB/LBU/SB
LH/LHU/SH
misaligned
access fault
```

TB 同时检查 commit 字段和 memory 最终内容。对 store，只有 response acknowledgement 后才允许 commit。

### RC6：RV32M

先扩展 decoder 与 decoder TB，再修改 core：

- decoder 增加 `muldiv_op_o`，所有非 RV32M 指令输出 `MD_NONE`；
- 添加八条 M-extension encoding tests；
- core 区分 multiply family 和 divide/remainder family；
- request 在 ready 前保持；
- response 前不能 write rd 或 commit；
- result commit 后才能取下一条指令。

Multiplier/divider 已经有完整 unit test，core TB 只需验证集成、stall 和 commit，不必重复全部算法随机测试。

### RC7：System 与 trap

加入 illegal、fetch/data faults、misalignment、ECALL、EBREAK、FENCE。每个 trap 只 commit 一次，随后 `halted_o=1` 且所有 request 停止。Reset 后应重新从 RESET_PC 开始。

这些异常的测试分工、期望 cause 和 commit 不变量集中记录在 [reference-core verification guide](rv32-reference-core-verification.md)，避免在实现教程中重复维护同一份 trap case 清单。

### RC8：程序级回归

将 directed instruction sequence 扩展成小型 bare-metal programs：

- arithmetic dependency chain；
- loop 和条件分支；
- byte/half/word memory copy；
- multiply/divide mixed program；
- divide-by-zero program；
- trap termination。

之后再加入 assembler/ELF-to-hex 流程和 Spike differential checking。Reference core 的 commit interface 已经为这些工作提供观察点。

## 11. TB 的 commit checker

推荐写一个 task：

```text
expect_commit(expected_pc, expected_instr, expected_rd_write,
              expected_rd_addr, expected_rd_wdata, expected_trap, cause)
```

它应当：

1. 每个上升沿检查 `commit_valid`；
2. 超过最大周期数时 `$fatal`，避免仿真永久挂起；
3. commit 到达后逐字段比较；
4. 用 `$error` 累计可继续检查的差异；
5. 对不适用字段要求安全值为0；
6. 返回前确认 commit pulse 不会重复两次。

Memory 指令可以使用单独的 `expect_memory_commit`，避免一个 task 接收过多参数。

## 12. 必须建立的断言或永久检查

即使暂时不使用 SystemVerilog Assertions，TB 也应逐周期检查：

- reset 时 request/commit/halted 均为0；
- request valid 在 ready 前不能撤销或改变 payload；
- WAIT 状态不能再次发送请求；
- data request 的地址低两位为0；
- `dmem_req_wstrb_o!=0` 只能出现在 store；
- `commit_valid_o` 不能连续重复同一条指令；
- `commit_rd_write_o` 时 rd 不能为 x0；
- trap commit 不能同时写 rd 或 memory；
- halted 时所有请求和 commit 都为0；
- PC 每次只在 commit 或 reset 时改变。

## 13. 常见错误

### 13.1 在 ready 前撤销 valid

会让请求在 memory stall 时丢失。valid 必须保持到 handshake 上升沿。

### 13.2 request accepted 就当作 load 完成

`req_ready` 不是 `resp_valid`。Load result 只有 response 到达后有效。

### 13.3 store 提前 commit

Store request accepted 后仍可能返回 access fault。必须等待 response acknowledgement。

### 13.4 在 EXECUTE 直接更新 PC

遇到 memory 或 mul/div stall 时容易让 commit PC 与当前 instruction 不一致。保存 pending next PC，在 commit 时统一更新更清楚。

### 13.5 JALR 只检查 bit0

JALR 必须清除 bit0，但没有 C extension 时还要检查最终 bit1，保证4字节对齐。

### 13.6 写 x0 仍报告 commit write

Regfile 会忽略 x0 写入，但 commit interface 也应报告 `commit_rd_write_o=0`，否则 differential checker 会认为发生了架构写回。

### 13.7 依赖已经变化的组合输入

进入 WAIT 后，上游 instruction、decoder output 或 regfile read data 可能变化。跨周期需要的内容必须保存。

### 13.8 一开始同时实现所有指令

若第一次程序就混合 branch、memory 和 RV32M，错误无法快速定位。按照 RC1 到 RC8 增量开发，并永久保留每一阶段测试。

## 14. 与后续模块的关系

本项目在 reference core 之后实现五级 pipeline core，而不是修改 reference core 追求频率。Pipeline core 使用相同 memory 和 commit 语义，但允许多条指令同时在途。

L1 cache 可以接在 instruction/data ports 外部：

```text
core imem port → L1 I-cache → lower memory
core dmem port → L1 D-cache → lower memory
```

初版 OoO core 也可以使用同样的 blocking data port和保守 memory scheduling。Unified L2 应在 L1 miss/refill/writeback 接口稳定后实现。

## 15. 如何使用这份教程

如果从空白实现同类 reference core，应按 RC1 到 RC8 顺序阅读和实现，每完成一阶段就保留对应检查。这样可以分别定位 fetch protocol、组合数据通路、写回、控制流、memory、RV32M 和 trap 问题。

阅读当前实现时，可以反向使用同一结构：先从第6节状态机理解一条指令经过哪些周期，再在第8节跟踪某类指令的数据通路，最后对照 `rv32_reference_core.sv` 中相应 state branch 和 pending registers。验证接口和现有 regression 的具体关系见 [reference-core verification guide](rv32-reference-core-verification.md)。
