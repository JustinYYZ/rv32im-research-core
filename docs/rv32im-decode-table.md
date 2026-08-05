<!-- SPDX-License-Identifier: Apache-2.0 -->

# RV32IM RTL 开发教程与指令编码手册

本文档用于从空的 RTL 工程开始，逐步实现本项目采用的 RV32IM 处理器基础模块。它既是
指令编码速查表，也是可直接执行的开发教程。阅读某个阶段时，应能确定：

- 指令从哪里取得数据、进行什么运算、把结果写到哪里；
- ISA 规定了什么，项目内部接口又规定了什么；
- 需要新建或修改哪些文件；
- 每个输出信号应设置成什么；
- testbench 应使用哪些输入和期望值；
- 什么条件下可以进入下一个阶段。

教程覆盖 RV32I 基础整数指令和 M 乘除扩展，不覆盖 A、F、D、C、V、Zicsr、虚拟内存
或特权架构。所有阶段都使用 32-bit little-endian、byte-addressed memory。

权威 ISA 定义：

- [RV32I Base Integer Instruction Set](https://docs.riscv.org/reference/isa/unpriv/rv32.html)
- [M Extension for Integer Multiplication and Division](https://docs.riscv.org/reference/isa/unpriv/m-st-ext.html)
- [RV32/64 Instruction Set Listings](https://docs.riscv.org/reference/isa/unpriv/rv-32-64g.html)

## 1. 从指令到 RTL 的整体路径

一条指令不会由单个文件独立完成。基础数据通路可以分成以下职责：

```text
instruction
    |
    +--> decoder ------------------------------+
    |      产生控制信号                         |
    |                                          v
    +--> immediate generator             operand select
    |                                          |
    +--> register file --> rs1/rs2 ------------+
                                               |
PC --------------------------------------------+
                                               v
                         +----------- execution units -----------+
                         | ALU | branch comparison | MUL/DIV | LSU |
                         +-------------------+--------------------+
                                             |
                                             v
                           ALU result / pc+4 / memory result
                                             |
                                             v
                                         writeback
                                             |
                                             v
                                       register file rd
```

各模块的边界必须明确：

| 模块 | 负责 | 不负责 |
|---|---|---|
| Decoder | 解释 opcode/funct3/funct7，产生内部控制信号 | 读取寄存器、执行运算、访问内存 |
| Immediate generator | 按 I/S/B/U/J 格式拼接并符号扩展 immediate | 判断指令是否合法 |
| Register file | 保存 x0–x31，提供 rs1/rs2，时钟沿写 rd | 判断该指令是否需要读写 |
| ALU | 加减、逻辑、移位、比较和地址计算 | 选择 operand 来源、决定写回 |
| Branch unit | 比较 rs1/rs2，产生条件是否成立 | 生成 branch immediate、更新 PC |
| LSU | 对齐地址、生成 store mask、选择并扩展 load 数据 | cache hit/miss、refill、异常提交 |
| Core control | PC、执行顺序、memory handshake、异常和写回 | 重新解释 instruction encoding |

开发时先单独验证这些模块，再把它们连接成完整 core。模块单测通过不代表处理器已经能
执行程序；它只证明该模块的局部合同成立。

## 2. 工程结构与统一开发规则

本教程使用以下文件命名：

```text
rtl/pkg/rv32_pkg.sv
rtl/backend/rv32_alu.sv
rtl/backend/rv32_regfile.sv
rtl/backend/rv32_branch_unit.sv
rtl/backend/rv32_lsu.sv
rtl/frontend/rv32_imm_gen.sv
rtl/frontend/rv32_decoder.sv

tb/unit/rv32_alu_tb.sv
tb/unit/rv32_regfile_tb.sv
tb/unit/rv32_branch_unit_tb.sv
tb/unit/rv32_lsu_tb.sv
tb/unit/rv32_imm_gen_tb.sv
tb/unit/rv32_decoder_tb.sv
```

### 2.1 组合逻辑的安全默认值

每个 `always_comb` 先给所有输出赋值，再进入 `case` 或 `if`。Decoder 建议使用：

```text
reg_write       = 0
mem_op          = MEM_NONE
control_flow    = CF_NONE
ebreak          = 0
illegal         = 1
```

只有完整匹配合法 encoding 后才清除 `illegal` 并打开副作用。未识别和 reserved
encoding 因而不会写寄存器或内存。Case 没有列出所有 bit pattern 并不自动产生 latch；
只要进入 case 前已对相关输出赋值，未匹配分支就会保留安全默认值。

### 2.2 时序逻辑规则

寄存器状态只在明确的时钟沿更新。Register file 的写操作使用 `always_ff @(posedge clk)`；
组合读端口使用 `always_comb` 或连续赋值。Testbench 应在时钟沿前设置输入，在时钟沿后
等待一个很短的时间再检查输出。

### 2.3 Testbench 规则

每个 TB 都应 self-checking：

1. 设置输入；
2. 组合逻辑等待 `#1`，时序逻辑产生时钟沿；
3. 使用 `!==` 检查实际值与期望值；
4. 失败时调用 `$error` 并增加 `errors`；
5. 结束时零错误打印 PASS，否则 `$fatal`；
6. 新测试必须保留所有旧测试，形成累计回归。

### 2.4 每个阶段的验证命令

```bash
make test-<module>
make test
```

组合模块还应通过 Yosys：

```text
read_verilog -sv <package> <module>
hierarchy -check -top <top>
proc
opt
check
```

Icarus 对 `always_comb` 中固定 bit select 可能打印
`constant selects in always_* processes are not currently supported`。这是敏感列表兼容性
提示；仍应使用 Yosys 检查 latch 和结构错误。

## 3. RISC-V 固定字段和六种格式

### 3.1 固定字段

| 字段 | Instruction bits | 用途 |
|---|---:|---|
| opcode | `[6:0]` | 确定指令大类 |
| rd | `[11:7]` | 目的寄存器 |
| funct3 | `[14:12]` | 区分同一 opcode 下的操作 |
| rs1 | `[19:15]` | 第一个源寄存器 |
| rs2 | `[24:20]` | 第二个源寄存器 |
| funct7 | `[31:25]` | 进一步区分操作 |

Decoder 可以始终提取这些位置，但必须用 `rs1_used` 和 `rs2_used` 表示某条指令是否
真的读取对应寄存器。例如 I-type load 的 `instr[24:20]` 属于 immediate，不是 rs2。

### 3.2 R-type

```text
31       25 24    20 19    15 14  12 11     7 6       0
+----------+--------+--------+------+---------+---------+
|  funct7  |  rs2   |  rs1   |funct3|   rd    | opcode  |
+----------+--------+--------+------+---------+---------+
```

用于 register-register ALU 和 RV32M，没有 immediate。

### 3.3 I-type

```text
31                20 19    15 14  12 11     7 6       0
+-------------------+--------+------+---------+---------+
|     imm[11:0]     |  rs1   |funct3|   rd    | opcode  |
+-------------------+--------+------+---------+---------+
```

用于 immediate ALU、load 和 JALR。

### 3.4 S-type

```text
31       25 24    20 19    15 14  12 11      7 6       0
+----------+--------+--------+------+----------+---------+
| imm[11:5]|  rs2   |  rs1   |funct3| imm[4:0] | opcode  |
+----------+--------+--------+------+----------+---------+
```

用于 store。它没有 rd；`instr[11:7]` 是 immediate 的低五位。

### 3.5 B-type

```text
31       25 24    20 19    15 14  12 11      7 6       0
+----------+--------+--------+------+----------+---------+
|12| 10:5 |  rs2   |  rs1   |funct3| 4:1 |11 | opcode  |
+----------+--------+--------+------+----------+---------+
```

用于 conditional branch。生成的 offset 最低位固定为 0。

### 3.6 U-type

```text
31                                12 11     7 6       0
+-----------------------------------+---------+---------+
|             imm[31:12]            |   rd    | opcode  |
+-----------------------------------+---------+---------+
```

用于 LUI 和 AUIPC。

### 3.7 J-type

```text
31                                12 11     7 6       0
+-----------------------------------+---------+---------+
| 20 | 10:1 | 11 |      19:12       |   rd    | opcode  |
+-----------------------------------+---------+---------+
```

用于 JAL。生成的 offset 最低位固定为 0。

### 3.8 Major opcode

| 指令大类 | Binary opcode | Hex |
|---|---:|---:|
| LOAD | `0000011` | `0x03` |
| MISC-MEM | `0001111` | `0x0f` |
| OP-IMM | `0010011` | `0x13` |
| AUIPC | `0010111` | `0x17` |
| STORE | `0100011` | `0x23` |
| OP | `0110011` | `0x33` |
| LUI | `0110111` | `0x37` |
| BRANCH | `1100011` | `0x63` |
| JALR | `1100111` | `0x67` |
| JAL | `1101111` | `0x6f` |
| SYSTEM | `1110011` | `0x73` |

## 4. 阶段一：建立 package、Makefile 和测试骨架

### 4.1 目标

建立所有模块共享的类型，不在不同文件中重复使用裸数字表示控制操作。

### 4.2 在 `rv32_pkg.sv` 定义的类型

| 类型 | 成员 | 使用位置 |
|---|---|---|
| `alu_op_e` | ADD、SUB、SLL、SLT、SLTU、XOR、SRL、SRA、OR、AND | decoder → ALU |
| `imm_kind_e` | NONE、I、S、B、U、J | decoder → immediate generator |
| `operand_a_sel_e` | RS1、PC、ZERO | operand mux |
| `operand_b_sel_e` | RS2、IMM | operand mux |
| `branch_op_e` | EQ、NE、LT、GE、LTU、GEU | decoder → branch unit |
| `control_flow_e` | NONE、BRANCH、JAL、JALR | decoder → PC control |
| `writeback_sel_e` | ALU、PC_PLUS_4、MEM | writeback mux |
| `mem_op_e` | NONE、LOAD、STORE | decoder → LSU |
| `mem_size_e` | BYTE、HALF、WORD | decoder → LSU |
| `system_op_e` | NONE、ECALL、EBREAK、FENCE | decoder → core control |

枚举默认值本身不等于安全控制。Decoder 仍必须在每次组合计算开始时显式选择
`MEM_NONE`、`CF_NONE` 和关闭写使能。

### 4.3 Makefile 模式

每个模块建立独立 source list、编译产物和 phony target。例如：

```text
<MODULE>_SRCS = package + RTL + TB
test-<module> = compile, then run vvp
test = 所有模块 target
clean = 删除所有生成的仿真产物
```

完成标准：

- package 能被空的模块和 TB import；
- `make test-<module>` 能编译并运行最小 smoke test；
- 生成文件只进入 `build/`，且 build 被 gitignore。

## 5. 阶段二：实现整数 ALU

### 5.1 接口与职责

ALU 输入两个 32-bit operand 和一个 `alu_op_e`，输出一个 32-bit result。ALU 不知道
operand 来自 rs1、rs2、PC 还是 immediate，也不写 register file。

### 5.2 每个操作的精确语义

| ALU op | 结果 | 注意事项 |
|---|---|---|
| ADD | `lhs + rhs` | 32-bit 自然截断，可用于算术和地址 |
| SUB | `lhs - rhs` | 32-bit 二进制补码 |
| SLL | `lhs << rhs[4:0]` | 只使用低五位 shift amount |
| SLT | signed `lhs < rhs ? 1 : 0` | 两个 operand 都按 signed 32-bit 解释 |
| SLTU | unsigned `lhs < rhs ? 1 : 0` | 默认 logic vector 即 unsigned |
| XOR | `lhs ^ rhs` | 逐 bit |
| SRL | `lhs >> rhs[4:0]` | 左侧补 0 |
| SRA | signed `lhs >>> rhs[4:0]` | 复制 lhs bit 31 |
| OR | `lhs \| rhs` | 逐 bit |
| AND | `lhs & rhs` | 逐 bit |

SRA 必须先把 lhs 转成 signed；SLT 也必须显式进行 signed comparison。SLTU 不能复用
SLT 的 signed 结果。

### 5.3 实现步骤

1. 新建 `rtl/backend/rv32_alu.sv`；
2. 在 `always_comb` 开头令 result 为 0；
3. 对 `alu_op_i` 写 case；
4. 所有 shift 都使用 `rhs_i[4:0]`；
5. 比较结果写成完整 32-bit 的 0 或 1；
6. 新建 `tb/unit/rv32_alu_tb.sv`，为每个 op 写 directed test。

### 5.4 必测向量

| 场景 | 输入 | 期望 |
|---|---|---|
| ADD overflow 截断 | `0xffffffff + 1` | `0x00000000` |
| SUB | `3 - 5` | `0xfffffffe` |
| SLL shamt masking | rhs 33 | 等价于左移 1 |
| SLT | `0xffffffff` 与 1 | 1，因为 signed -1 < 1 |
| SLTU | `0xffffffff` 与 1 | 0 |
| SRL | `0x80000000 >> 1` | `0x40000000` |
| SRA | signed `0x80000000 >>> 1` | `0xc0000000` |

完成标准：十种操作全部通过，Yosys 不报告 latch。

## 6. 阶段三：实现 32×32 register file

### 6.1 架构行为

RV32I 有 32 个 32-bit integer register：

- x0 永远读取为 0；
- x1–x31 保存状态；
- 两个组合读端口同时读取 rs1 和 rs2；
- 一个同步写端口在 `posedge clk` 写 rd；
- `write_enable=0` 不修改状态；
- 写 rd=x0 必须被忽略。

### 6.2 实现步骤

1. 声明 `logic [31:0] regs [0:31]`；
2. 读端口地址为 0 时直接输出 0，否则读取数组；
3. 在 `always_ff @(posedge clk)` 中，仅当 `write_enable && rd_addr != 0` 时写数组；
4. 不要通过普通写操作改变 regs[0]；
5. 复位策略必须和 core 合同一致。若模块提供 reset，应清除 x1–x31；若不提供 reset，
   TB 不应假设未写寄存器具有确定值。

### 6.3 Testbench 时序

```text
先设置 write_enable、rd_addr、write_data
等待 posedge
关闭 write_enable
设置 read address
等待 #1
检查 read data
```

必测：

- 分别写读 x1 和 x31；
- 同时从两个端口读取不同寄存器；
- 写使能为 0 时保持旧值；
- 尝试写 x0 后两个读端口仍返回 0；
- 连续两个时钟写不同寄存器不会互相覆盖。

## 7. 阶段四：实现 immediate generator

### 7.1 为什么独立成模块

RISC-V 的 immediate bit 在不同格式中排列不同，但生成结果始终是 32 bit。Decoder 只
输出 immediate 类型；generator 根据 instruction 和 `imm_kind_i` 完成拼接。

### 7.2 生成公式

| 类型 | 使用指令 | 32-bit 生成公式 |
|---|---|---|
| I | OP-IMM、load、JALR | `{{20{inst[31]}}, inst[31:20]}` |
| S | store | `{{20{inst[31]}}, inst[31:25], inst[11:7]}` |
| B | branch | `{{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0}` |
| U | LUI、AUIPC | `{inst[31:12], 12'b0}` |
| J | JAL | `{{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0}` |

I、S、B、J 都进行符号扩展。B 和 J 的最低位固定为 0，因为 instruction address 至少
两字节对齐。U-type 不是符号扩展：它直接把 instruction 高 20 bit 放到结果高位。

### 7.3 实现和测试

1. 新建 `rv32_imm_gen.sv`，默认输出 0；
2. 按 `imm_kind_i` 写 case；
3. 每种格式至少测试一个正 immediate 和一个负 immediate；
4. B/J 测试必须确认 bit 0 为 0；
5. S/B 的 immediate 被拆开，TB 应选择能暴露 bit 重排错误的值，而不是只测 0；
6. `IMM_NONE` 必须输出 0。

完成标准：I/S/B/U/J 的正负边界和 bit 排列均通过。

## 8. 阶段五：实现基础 decoder

### 8.1 Decoder 接口

Decoder 输入 `instr_i[31:0]`，输出：

- rs1、rs2、rd 地址与 source-used 标志；
- ALU operation；
- operand A/B selector；
- immediate kind；
- control-flow 和 branch operation；
- writeback selector；
- memory operation、size 和 load unsigned；
- register write 和统一的 system event；
- illegal。

字段提取可使用连续赋值，与组合 decode 并行发生。

### 8.2 Decoder 查表顺序

```text
opcode = instruction[6:0]
    |
    +-- funct3 = instruction[14:12]
            |
            +-- 必要时检查 funct7 = instruction[31:25]
```

不能对所有 I-type 指令都检查 funct7。ADDI、SLTI、SLTIU、XORI、ORI、ANDI 的
`instr[31:20]` 整体属于 immediate。只有 shift-immediate 需要检查高七位是否合法。

### 8.3 Register-register ALU

这些指令都读取 rs1、rs2，令 ALU A=RS1、B=RS2，写 rd，不使用 immediate：

| 指令 | opcode | funct3 | funct7 | ALU |
|---|---:|---:|---:|---|
| ADD | `0110011` | `000` | `0000000` | ADD |
| SUB | `0110011` | `000` | `0100000` | SUB |
| SLL | `0110011` | `001` | `0000000` | SLL |
| SLT | `0110011` | `010` | `0000000` | SLT |
| SLTU | `0110011` | `011` | `0000000` | SLTU |
| XOR | `0110011` | `100` | `0000000` | XOR |
| SRL | `0110011` | `101` | `0000000` | SRL |
| SRA | `0110011` | `101` | `0100000` | SRA |
| OR | `0110011` | `110` | `0000000` | OR |
| AND | `0110011` | `111` | `0000000` | AND |

共同控制：

```text
operand_a_sel = OP_A_RS1
operand_b_sel = OP_B_RS2
imm_kind      = IMM_NONE
rs1_used      = 1
rs2_used      = 1
reg_write     = 1
writeback     = WB_ALU
illegal       = 0
```

### 8.4 Immediate ALU

这些指令读取 rs1，令 B=IMM，使用 I-type immediate 并写 rd：

| 指令 | funct3 | 高位限制 | ALU 行为 |
|---|---:|---|---|
| ADDI | `000` | 无 | ADD |
| SLTI | `010` | 无 | signed comparison |
| SLTIU | `011` | 无 | unsigned comparison |
| XORI | `100` | 无 | XOR |
| ORI | `110` | 无 | OR |
| ANDI | `111` | 无 | AND |
| SLLI | `001` | `instr[31:25]=0000000` | SLL |
| SRLI | `101` | `instr[31:25]=0000000` | SRL |
| SRAI | `101` | `instr[31:25]=0100000` | SRA |

共同控制：

```text
operand_a_sel = OP_A_RS1
operand_b_sel = OP_B_IMM
imm_kind      = IMM_I
rs1_used      = 1
rs2_used      = 0
reg_write     = 1
writeback     = WB_ALU
```

SLTIU 的 immediate 仍先按 I-type 符号扩展到 32 bit，然后把两个 32-bit operand 当
unsigned 比较。

### 8.5 LUI 和 AUIPC

| 指令 | 数据来源与结果 | 关键控制 |
|---|---|---|
| LUI | `rd = imm_u` | A=ZERO、B=IMM、ALU_ADD、IMM_U、reg_write=1 |
| AUIPC | `rd = pc + imm_u` | A=PC、B=IMM、ALU_ADD、IMM_U、reg_write=1 |

### 8.6 Decoder TB

每条合法指令不仅检查 ALU op，还要检查所有控制输出，防止后来增加新信号时旧指令出现
意外副作用。至少检查：

- source address 与 used 标志；
- operand selector 和 immediate kind；
- writeback selector 与 register write；
- control flow 为 NONE；
- memory operation 为 NONE；
- illegal=0。

Illegal 测试应选择与合法指令接近的 reserved encoding，并确认 reg_write=0、
mem_op=MEM_NONE、illegal=1。

可使用的示例机器码：

| Machine code | Assembly |
|---:|---|
| `0x002081b3` | `ADD x3, x1, x2` |
| `0x402081b3` | `SUB x3, x1, x2` |
| `0xfff08193` | `ADDI x3, x1, -1` |
| `0x00409193` | `SLLI x3, x1, 4` |
| `0x4040d193` | `SRAI x3, x1, 4` |
| `0x123451b7` | `LUI x3, 0x12345` |
| `0x12345197` | `AUIPC x3, 0x12345` |

## 9. 阶段六：实现 branch、JAL 和 JALR

### 9.1 Conditional branch 的语义

Branch 读取 rs1 和 rs2，不写 rd。条件成立时 PC 变成 `pc + imm_b`，否则为
`pc + 4`。

| 指令 | funct3 | 条件 |
|---|---:|---|
| BEQ | `000` | `rs1 == rs2` |
| BNE | `001` | `rs1 != rs2` |
| BLT | `100` | signed `rs1 < rs2` |
| BGE | `101` | signed `rs1 >= rs2` |
| BLTU | `110` | unsigned `rs1 < rs2` |
| BGEU | `111` | unsigned `rs1 >= rs2` |

Decoder 输出：

```text
control_flow  = CF_BRANCH
branch_op     = 对应比较
operand_a_sel = OP_A_PC
operand_b_sel = OP_B_IMM
imm_kind      = IMM_B
rs1_used      = 1
rs2_used      = 1
reg_write     = 0
```

ALU 可以计算 `pc + imm_b`，branch unit 独立比较 rs1/rs2。不要把 BLT 和 BLTU 合并
为同一种 signed comparison。

### 9.2 JAL

```text
target = pc + imm_j
rd     = pc + 4
```

JAL 不读取 rs1/rs2。Decoder 选择 PC+IMM 计算 target，同时选择 `WB_PC_PLUS_4`
写 rd。rd=x0 时形成不保存返回地址的无条件跳转。

### 9.3 JALR

```text
target = (register[rs1] + imm_i) & 0xfffffffe
rd     = pc + 4
```

JALR 读取 rs1、使用 I-type immediate，funct3 必须为 `000`。清除 target bit 0 是
PC target 逻辑的责任；decoder 只输出 `CF_JALR`。

### 9.4 Branch unit TB

每一种比较至少测试真和假，并专门选择能区分 signed/unsigned 的输入：

```text
lhs = 0xffffffff
rhs = 0x00000001
```

此时 signed lhs=-1，应满足 LT；unsigned lhs 很大，不满足 LTU。Decoder TB 还应测试
reserved branch funct3 和非零 JALR funct3 保持 illegal。

## 10. 阶段七：实现 load/store decoder 与 LSU

### 10.1 先区分 ISA 和项目内部接口

ISA 规定程序能观察到的内存结果，但不会规定 RTL 必须有 `store_mask_o`。本教程采用
一个 aligned 32-bit memory port，LSU 负责把 byte-addressed 指令转换成该接口。

| 内容 | 来源 |
|---|---|
| SB 存 rs2 低 8 bit，SH 存低 16 bit，SW 存全部 32 bit | RV32I |
| LB/LH 符号扩展，LBU/LHU 零扩展 | RV32I |
| 低有效 byte 位于较低地址 | little-endian |
| memory port 一次传输一个对齐的 32-bit word | 项目接口 |
| 四位 mask 分别控制四个 byte lane | 项目接口 |
| 不拆分跨 word 访问，输出 misaligned | 本教程采用的 LSU 策略 |

### 10.2 每条指令读什么、写到哪里

有效地址：

```text
load address  = register[rs1] + sign_extend(imm_i)
store address = register[rs1] + sign_extend(imm_s)
```

用 `M8[a]` 表示地址 a 处的一个 byte：

| 指令 | 精确行为 |
|---|---|
| LB | 读取 `M8[address]`，复制 bit 7 到高 24 bit，写 rd |
| LBU | 读取 `M8[address]`，高 24 bit 补 0，写 rd |
| LH | `M8[address]` 为低 byte，`M8[address+1]` 为高 byte，signed 16-to-32 扩展后写 rd |
| LHU | 读取与 LH 相同的两个 byte，zero 16-to-32 扩展后写 rd |
| LW | 读取 address 到 address+3 的四个 byte，组合成 32 bit 写 rd |
| SB | `M8[address] = rs2[7:0]`，其他 byte 不变 |
| SH | `M8[address] = rs2[7:0]`，`M8[address+1] = rs2[15:8]` |
| SW | 从低地址到高地址依次写 rs2 的 `[7:0]`、`[15:8]`、`[23:16]`、`[31:24]` |

例如 `x1=0x1000`、`x2=0xa1b2c3d4`：

| 指令 | 内存变化 |
|---|---|
| `SB x2,2(x1)` | `M8[0x1002]=0xd4` |
| `SH x2,2(x1)` | `M8[0x1002]=0xd4`，`M8[0x1003]=0xc3` |
| `SW x2,0(x1)` | 地址 0x1000–0x1003 依次写 d4、c3、b2、a1 |

SH 存的是 rs2 的低 16 bit `0xc3d4`。Little-endian 把较低 byte `0xd4` 放在
较低地址，把 `0xc3` 放在下一个地址。

### 10.3 Decoder 控制

| 指令组 | A/B | IMM | rs1/rs2 used | reg write | writeback | mem op |
|---|---|---|---|---:|---|---|
| LB/LH/LW/LBU/LHU | RS1/IMM | I | 1/0 | 1 | WB_MEM | MEM_LOAD |
| SB/SH/SW | RS1/IMM | S | 1/1 | 0 | 无有效写回 | MEM_STORE |

所有合法 load/store 使用 ALU_ADD 计算 byte address。

| 指令 | opcode | funct3 | size | unsigned |
|---|---:|---:|---|---:|
| LB | `0000011` | `000` | BYTE | 0 |
| LH | `0000011` | `001` | HALF | 0 |
| LW | `0000011` | `010` | WORD | 0 |
| LBU | `0000011` | `100` | BYTE | 1 |
| LHU | `0000011` | `101` | HALF | 1 |
| SB | `0100011` | `000` | BYTE | 无意义，保持 0 |
| SH | `0100011` | `001` | HALF | 无意义，保持 0 |
| SW | `0100011` | `010` | WORD | 无意义，保持 0 |

Load funct3 011/110/111 和 store funct3 011/100/101/110/111 为 reserved，必须保持
illegal=1、mem_op=MEM_NONE、reg_write=0。

Decoder TB 可使用：

| Machine code | Assembly |
|---:|---|
| `0x00808183` | `LB x3,8(x1)` |
| `0x00809183` | `LH x3,8(x1)` |
| `0x0080a183` | `LW x3,8(x1)` |
| `0x0080c183` | `LBU x3,8(x1)` |
| `0x0080d183` | `LHU x3,8(x1)` |
| `0x00208423` | `SB x2,8(x1)` |
| `0x00209423` | `SH x2,8(x1)` |
| `0x0020a423` | `SW x2,8(x1)` |

### 10.4 LSU 接口合同

| 信号 | 来源或去向 | 含义 |
|---|---|---|
| mem_op_i | decoder | NONE、LOAD 或 STORE |
| mem_size_i | decoder | BYTE、HALF 或 WORD |
| load_unsigned_i | decoder | byte/half load 是否零扩展 |
| addr_i | ALU | 完整 byte address |
| store_value_i | register file rs2 | store 数据 |
| load_word_i | memory/cache | 返回的 aligned 32-bit word |
| aligned_addr_o | memory/cache | `{addr_i[31:2],2'b00}` |
| store_word_o | memory/cache | 移动到目标 byte lane 后的数据 |
| store_mask_o | memory/cache | 四个 byte lane 的写使能 |
| load_value_o | writeback | 选择和扩展后的 32-bit 结果 |
| misaligned_o | core control | 访问跨越本单元支持的 word 边界 |

LSU 不负责 cache hit/miss、请求重试、refill 或异常退休。

### 10.5 Address、lane 和 mask

```text
word bits      [31:24]     [23:16]     [15:8]      [7:0]
byte lane          3           2           1           0
address offset     3           2           1           0
```

`store_mask_o[i]` 控制 `store_word_o` 的第 i 个 byte。Mask 为 0 的 byte 保持原值。
数据必须移动到 mask 打开的同一个 lane。

假设 `store_value_i=0xa1b2c3d4`：

| 操作 | offset | aligned | store word | mask | 修改地址 |
|---|---:|---|---:|---:|---|
| SB | 0 | 是 | `0x000000d4` | `0001` | aligned+0 |
| SB | 1 | 是 | `0x0000d400` | `0010` | aligned+1 |
| SB | 2 | 是 | `0x00d40000` | `0100` | aligned+2 |
| SB | 3 | 是 | `0xd4000000` | `1000` | aligned+3 |
| SH | 0 | 是 | `0x0000c3d4` | `0011` | aligned+0、+1 |
| SH | 1 | 否 | 0 | `0000` | 不写 |
| SH | 2 | 是 | `0xc3d40000` | `1100` | aligned+2、+3 |
| SH | 3 | 否 | 0 | `0000` | 不写 |
| SW | 0 | 是 | `0xa1b2c3d4` | `1111` | aligned+0 到 +3 |
| SW | 1/2/3 | 否 | 0 | `0000` | 不写 |

Alignment：

| size | 合法 offset | misaligned |
|---|---|---|
| BYTE | 0、1、2、3 | 0 |
| HALF | 0、2 | `addr_i[0]` |
| WORD | 0 | `\|addr_i[1:0]` |

未对齐 store 必须输出 mask=0000，避免只修改跨 word 数据的一部分。

### 10.6 Load selection 与 extension

假设 `load_word_i=0x80ff7f01`：

```text
offset 0 -> byte 0x01
offset 1 -> byte 0x7f
offset 2 -> byte 0xff
offset 3 -> byte 0x80
```

| 操作 | offset | 原始值 | load value |
|---|---:|---:|---:|
| LB | 2 | `0xff` | `0xffffffff` |
| LBU | 2 | `0xff` | `0x000000ff` |
| LB | 3 | `0x80` | `0xffffff80` |
| LBU | 3 | `0x80` | `0x00000080` |
| LH | 0 | `0x7f01` | `0x00007f01` |
| LH | 2 | `0x80ff` | `0xffff80ff` |
| LHU | 2 | `0x80ff` | `0x000080ff` |
| LW | 0 | `0x80ff7f01` | `0x80ff7f01` |

符号扩展：

```text
signed byte = {{24{selected_byte[7]}}, selected_byte}
signed half = {{16{selected_half[15]}}, selected_half}
```

### 10.7 LSU 实现顺序

1. 输出安全默认值：store word=0、mask=0、load value=0、misaligned=0；
2. 连续生成 aligned address；
3. 根据 size 和 address 低位检测 misalignment；
4. 仅对 aligned MEM_STORE 生成 store word/mask；
5. 仅对 aligned MEM_LOAD 选择 byte/halfword 并扩展；
6. MEM_NONE、load/store 的相反输出和未对齐结果保持 0；
7. TB 覆盖上述全部表项，并检查 load 不产生 store mask、store 不产生 load value。

完成标准：decoder 和 LSU 单测全部通过；reserved encoding 无副作用；Yosys 无 latch。

## 11. 阶段八：实现 FENCE、ECALL 与环境事件

### 11.1 ECALL

ECALL 完整 encoding 为 `0x00000073`。它不读普通源寄存器、不写 rd、不访问内存，
而是向 core control 报告 environment call。若项目尚未实现 privileged trap state，
可以先输出 `SYS_ECALL` 事件，由 testbench 或 bare-metal environment 观察；不能把它
误当作普通 ALU 指令。

### 11.2 EBREAK

EBREAK 完整 encoding 为 `0x00100073`，行为与 ECALL 分开编码。测试环境可以用它停止
程序，但 RTL 仍应输出明确事件并关闭 register/memory side effect。

### 11.3 FENCE

FENCE opcode=`0001111`、funct3=`000`。它不产生算术结果；它要求后续相关 memory
operation 在先前相关 operation 可观察之后发生。

在阻塞式、一次只允许一个 memory request 的顺序 core 中，实现步骤为：

1. Decoder 识别 FENCE 并输出 `SYS_FENCE`；
2. 不读取 rs1/rs2，不写 rd，不产生 memory write；
3. Core 只有在先前 memory request 已完成且接口 idle 时允许 FENCE 完成；
4. FENCE 完成后才允许后续 memory instruction 发起请求。

如果 core 尚无 memory handshake，就不能仅靠 decoder 声称实现了 FENCE。FENCE.I 属于
Zifencei，不在本教程范围内。

建议不要为每种事件分别增加一个布尔输出，而是在 package 中定义互斥枚举：

```systemverilog
typedef enum logic [1:0] {
  SYS_NONE,
  SYS_ECALL,
  SYS_EBREAK,
  SYS_FENCE
} system_op_e;
```

Decoder 在组合逻辑开头选择 `SYS_NONE`，只对支持的完整 encoding 改为对应事件。这样
普通指令和非法指令都不会残留上一次的 system event，也不会同时声明多个互斥事件。

### 11.4 测试

- 精确匹配 ECALL 和 EBREAK；
- 相近的 SYSTEM encoding 保持 illegal；
- 事件指令的 reg_write=0、mem_op=MEM_NONE；
- 用一个延迟 memory model 证明 FENCE 等待旧请求完成；
- 证明 FENCE 不会永久阻塞空闲接口。

## 12. 阶段九：实现 RV32M

乘法器的算法原理、33-bit signedness normalization、Radix-4 Booth 分组、carry-save
compression、三级流水和验证方法见
[Radix-4 Booth 流水乘法器教程](radix4-booth-multiplier.md)。

### 12.1 Encoding

所有 M 指令：

```text
opcode = 0110011
funct7 = 0000001
```

| 指令 | funct3 | 精确结果 |
|---|---:|---|
| MUL | `000` | 64-bit 乘积低 32 bit |
| MULH | `001` | signed×signed 乘积高 32 bit |
| MULHSU | `010` | signed rs1×unsigned rs2 乘积高 32 bit |
| MULHU | `011` | unsigned×unsigned 乘积高 32 bit |
| DIV | `100` | signed 商，向 0 截断 |
| DIVU | `101` | unsigned 商 |
| REM | `110` | signed 余数，符号跟 dividend |
| REMU | `111` | unsigned 余数 |

### 12.2 乘法为什么需要 64 bit 中间值

两个 32-bit 数相乘最多需要 64 bit。MUL 选择 bits `[31:0]`；MULH/MULHSU/MULHU
选择 `[63:32]`。不能先把乘积截断到 32 bit 再计算高半。

Signedness 必须在扩展到 64 bit 之前确定：

- signed operand 做符号扩展；
- unsigned operand 做零扩展；
- MULHSU 的两个输入扩展方式不同。

### 12.3 除法特殊情况

除法器的 restoring algorithm、逐周期寄存器变化、signed magnitude 转换、状态机、
特殊情况和测试顺序见
[Radix-2 迭代除法器教程](radix2-iterative-divider.md)。

| 条件 | DIV/DIVU | REM/REMU |
|---|---|---|
| divisor=0 | `0xffffffff` | dividend |
| signed `0x80000000 / 0xffffffff` | `0x80000000` | 0 |

这些情况不产生 arithmetic trap。

### 12.4 组合或多周期接口

为了避免组合除法成为长 critical path，推荐使用 multicycle handshake：

```text
start_i  + operands + operation
busy_o
done_o
result_o
```

要求：

- 仅在 idle 时接受 start；
- busy 期间保存 operands 和 operation；
- done 精确定义为一个周期脉冲或 valid/ready 合同；
- 除法迭代次数和暂停行为写入接口注释；
- core 在 result valid 前不能写回或退休该指令。

### 12.5 RV32M TB

至少覆盖：

- 0、1、-1、最大正数和最小负数；
- 四种乘法的高低半与 signedness；
- 正/负 dividend 和 divisor 的 DIV/REM；
- 除 0；
- signed overflow；
- back-to-back request；
- busy 时重复 start 的处理；
- done 和 result 的周期关系。

Decoder TB 同时确认 funct7=`0000001` 才进入 M extension，其他相近 encoding 保持
illegal。

## 13. 模块集成前检查清单

完成上述模块后，再开始 reference core 或流水线数据通路集成。集成前逐项确认：

- ALU、regfile、immediate generator、decoder、branch unit、LSU、M unit 均有独立 TB；
- Decoder 每条合法指令都定义 rs used、operand selector、writeback 和副作用；
- Illegal 指令不会写 register 或 memory；
- x0 在所有写回路径上保持 0；
- branch/JAL/JALR 同时定义 target 和 pc+4 写回；
- load address 来自 rs1+I immediate，store address 来自 rs1+S immediate；
- load 写回使用 LSU result，store 不进入 register writeback；
- memory request 的 valid/ready、返回数据和异常时序已形成书面接口合同；
- multicycle unit 的 busy/done 能阻止过早写回；
- 所有单测、完整回归和 Yosys check 通过。

集成 core 时推荐按以下顺序：

1. PC 与 instruction memory；
2. Decode、register read 和 immediate；
3. Operand mux 与 ALU；
4. ALU writeback；
5. Branch/JAL/JALR PC redirect；
6. Load/store memory handshake 和 writeback；
7. ECALL/EBREAK/FENCE 事件；
8. Multicycle RV32M stall 和 writeback；
9. 指令级程序测试；
10. commit trace 与 differential verification。

## 14. 完整 RV32IM 指令索引

| 类别 | 指令 |
|---|---|
| Register ALU | ADD、SUB、SLL、SLT、SLTU、XOR、SRL、SRA、OR、AND |
| Immediate ALU | ADDI、SLTI、SLTIU、XORI、ORI、ANDI、SLLI、SRLI、SRAI |
| Upper immediate | LUI、AUIPC |
| Branch | BEQ、BNE、BLT、BGE、BLTU、BGEU |
| Jump | JAL、JALR |
| Load | LB、LH、LW、LBU、LHU |
| Store | SB、SH、SW |
| Environment/order | FENCE、ECALL、EBREAK |
| RV32M multiply | MUL、MULH、MULHSU、MULHU |
| RV32M divide | DIV、DIVU、REM、REMU |

每次新增指令都应回到其对应章节，从“可观察语义”推导控制信号和数据通路，再编写
self-checking test。不要只根据指令名称猜测 RTL，也不要只让仿真编译通过而不检查全部
副作用。
