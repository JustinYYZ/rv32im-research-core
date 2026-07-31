<!-- SPDX-License-Identifier: Apache-2.0 -->

# RV32IM Instruction Encoding and Decoder Table

本文档是本项目实现 RV32IM decoder 时使用的查表手册。它只覆盖本项目目标中的
RV32I 基础整数指令和 M 乘除扩展，不包含 A、F、D、C、V、Zicsr 或其他扩展。

权威定义以 RISC-V International 发布的规范为准：

- [RV32I Base Integer Instruction Set](https://docs.riscv.org/reference/isa/unpriv/rv32.html)
- [M Extension for Integer Multiplication and Division](https://docs.riscv.org/reference/isa/unpriv/m-st-ext.html)
- [RV32/64 Instruction Set Listings](https://docs.riscv.org/reference/isa/unpriv/rv-32-64g.html)

## 0. 开发路线：先看这里

本文档同时包含“开发任务”和“ISA 查表资料”。实际开发时先看本节确定当前任务，
再到后面的对应章节查 encoding。不要按照整张 ISA 表从上到下直接实现。

| Milestone | 状态 | 本阶段内容 | 主要修改文件 |
|---|---|---|---|
| 1 | 已完成 | ADD、SUB、ADDI、LUI、AUIPC、EBREAK | decoder、decoder TB |
| 2 | 已完成 | 补齐 SLL、SLT、SLTU、XOR、SRL、SRA、OR、AND | decoder、decoder TB |
| 3 | 已完成 | 补齐 RV32I immediate ALU 指令 | decoder、decoder TB |
| 4 | **下一步** | 增加 S、B、J immediate 生成 | immediate generator、对应 TB |
| 5 | 后续 | branch、JAL 和 JALR | package、decoder、branch/jump 单元及 TB |
| 6 | 后续 | load 和 store | package、decoder、LSU 及 TB |
| 7 | 后续 | FENCE 和 ECALL | decoder、core control 及 TB |
| 8 | 后续 | RV32M 乘除法指令 | package、decoder、mul/div 单元及 TB |

### Milestone 4 的具体任务

下一步只修改 `rtl/frontend/rv32_imm_gen.sv` 和
`tb/unit/rv32_imm_gen_tb.sv`，补齐：

```text
IMM_S  IMM_B  IMM_J
```

`imm_kind_e` 已经定义了这三种类型，本阶段不需要修改 package
或 decoder。任务是把分散的 instruction bit 重排成 32-bit 有符号 immediate。

验收要求：

1. 实现 IMM_S、IMM_B 和 IMM_J，保留已有 IMM_I、IMM_U 和 IMM_NONE 行为；
2. 每种新格式都测试正数和负数，覆盖符号扩展；
3. B-type 和 J-type 测试最低位固定为零；
4. S-type 测试分散在 `[31:25]` 和 `[11:7]` 的两段 immediate；
5. `make test` 全部通过，Yosys 不产生 latch。

完成一个 milestone 后，只更新本节的状态和“下一步”标记。这样下次打开文档即可直接
找到要做的内容，而不需要重新搜索整份 ISA 表。

## 1. Decoder 的查表顺序

一条指令通常不能只看 opcode。推荐按照下面的顺序判断：

```text
instruction
    |
    +-- opcode = instruction[6:0]       确定指令大类
            |
            +-- funct3 = instruction[14:12]
                    |
                    +-- funct7 = instruction[31:25]
```

例如 ADD 和 SUB 的 opcode、funct3 都相同，只能通过 funct7 区分：

```text
ADD: opcode=0110011, funct3=000, funct7=0000000
SUB: opcode=0110011, funct3=000, funct7=0100000
```

Decoder 应先给所有控制输出安全默认值：

```text
reg_write = 0
memory_write = 0
ebreak = 0
illegal = 1
```

只有完整匹配一条合法指令后，才清除 `illegal` 并打开相应副作用。

## 2. 固定字段位置

RISC-V 把寄存器字段固定在相同位置，方便硬件并行提取：

| 字段 | Instruction bits |
|---|---:|
| opcode | `[6:0]` |
| rd | `[11:7]` |
| funct3 | `[14:12]` |
| rs1 | `[19:15]` |
| rs2 | `[24:20]` |
| funct7 | `[31:25]` |

即使某种格式不使用 rs1 或 rs2，也可以照常提取这些 bit，但必须通过
`rs1_used` 和 `rs2_used` 表明它们是否真的是 source operand。

## 3. 六种基础编码格式

### R-type

```text
31       25 24    20 19    15 14  12 11     7 6       0
+----------+--------+--------+------+---------+---------+
|  funct7  |  rs2   |  rs1   |funct3|   rd    | opcode  |
+----------+--------+--------+------+---------+---------+
```

用于寄存器 ALU 和 RV32M 指令，没有 immediate。

### I-type

```text
31                20 19    15 14  12 11     7 6       0
+-------------------+--------+------+---------+---------+
|     imm[11:0]     |  rs1   |funct3|   rd    | opcode  |
+-------------------+--------+------+---------+---------+
```

用于 immediate ALU、load 和 JALR。

### S-type

```text
31       25 24    20 19    15 14  12 11      7 6       0
+----------+--------+--------+------+----------+---------+
| imm[11:5]|  rs2   |  rs1   |funct3| imm[4:0] | opcode  |
+----------+--------+--------+------+----------+---------+
```

用于 store，没有 rd。

### B-type

```text
31       25 24    20 19    15 14  12 11      7 6       0
+----------+--------+--------+------+----------+---------+
|12| 10:5 |  rs2   |  rs1   |funct3| 4:1 |11 | opcode  |
+----------+--------+--------+------+----------+---------+
```

用于 conditional branch。生成的 offset 最低位固定为零。

### U-type

```text
31                                12 11     7 6       0
+-----------------------------------+---------+---------+
|             imm[31:12]            |   rd    | opcode  |
+-----------------------------------+---------+---------+
```

用于 LUI 和 AUIPC。

### J-type

```text
31                                12 11     7 6       0
+-----------------------------------+---------+---------+
| 20 | 10:1 | 11 |      19:12       |   rd    | opcode
+-----------------------------------+---------+---------+
```

用于 JAL。生成的 offset 最低位固定为零。

## 4. Major opcode 表

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

## 5. 当前已实现的 decoder 指令

Milestone 1 建立了最小 decoder 接口和安全的 illegal 默认行为：

| 指令 | opcode | funct3 | funct7/完整编码 | Operand A | Operand B | ALU | IMM | rs1/rs2 used | 写 rd |
|---|---|---|---|---|---|---|---|---|---|
| ADD | `0110011` | `000` | `0000000` | RS1 | RS2 | ADD | NONE | 1/1 | 1 |
| SUB | `0110011` | `000` | `0100000` | RS1 | RS2 | SUB | NONE | 1/1 | 1 |
| ADDI | `0010011` | `000` | 不检查 | RS1 | IMM | ADD | I | 1/0 | 1 |
| LUI | `0110111` | — | — | ZERO | IMM | ADD | U | 0/0 | 1 |
| AUIPC | `0010111` | — | — | PC | IMM | ADD | U | 0/0 | 1 |
| EBREAK | `1110011` | — | 完整值 `0x00100073` | — | — | — | NONE | 0/0 | 0 |

Milestone 2 补齐了其余 RV32I register-register ALU 指令。它们使用相同的
operand 和写回控制，区别主要在 `funct3`、`funct7` 和 ALU operation：

| 指令 | funct3 | funct7 | ALU |
|---|---:|---:|---|
| SLL | `001` | `0000000` | SLL |
| SLT | `010` | `0000000` | SLT |
| SLTU | `011` | `0000000` | SLTU |
| XOR | `100` | `0000000` | XOR |
| SRL | `101` | `0000000` | SRL |
| SRA | `101` | `0100000` | SRA |
| OR | `110` | `0000000` | OR |
| AND | `111` | `0000000` | AND |

所有 milestone 2 指令都使用：

```text
Operand A = RS1
Operand B = RS2
IMM = NONE
rs1_used = 1
rs2_used = 1
reg_write = 1
```

Milestone 3 补齐了其余 RV32I immediate ALU 指令：SLTI、SLTIU、XORI、
ORI、ANDI、SLLI、SRLI 和 SRAI。它们都使用 RS1 和 IMM 作为 ALU
operand，并写回 rd。Shift-immediate 指令还会校验 `instr[31:25]`；
详细 encoding 见第 11 节。

当前回归测试使用的示例机器码：

| Machine code | Assembly |
|---:|---|
| `0x002081b3` | `ADD x3, x1, x2` |
| `0x402081b3` | `SUB x3, x1, x2` |
| `0x002091b3` | `SLL x3, x1, x2` |
| `0x0020a1b3` | `SLT x3, x1, x2` |
| `0x0020b1b3` | `SLTU x3, x1, x2` |
| `0x0020c1b3` | `XOR x3, x1, x2` |
| `0x0020d1b3` | `SRL x3, x1, x2` |
| `0x4020d1b3` | `SRA x3, x1, x2` |
| `0x0020e1b3` | `OR x3, x1, x2` |
| `0x0020f1b3` | `AND x3, x1, x2` |
| `0xfff08193` | `ADDI x3, x1, -1` |
| `0xfff0a193` | `SLTI x3, x1, -1` |
| `0xfff0b193` | `SLTIU x3, x1, -1` |
| `0x0550c193` | `XORI x3, x1, 0x55` |
| `0x0550e193` | `ORI x3, x1, 0x55` |
| `0x0550f193` | `ANDI x3, x1, 0x55` |
| `0x00409193` | `SLLI x3, x1, 4` |
| `0x0040d193` | `SRLI x3, x1, 4` |
| `0x4040d193` | `SRAI x3, x1, 4` |
| `0x123451b7` | `LUI x3, 0x12345` |
| `0x12345197` | `AUIPC x3, 0x12345` |
| `0x00100073` | `EBREAK` |

## 6. U-type 与跳转

| 指令 | opcode | funct3 | 格式 | 读取 | 写回/效果 |
|---|---:|---:|---|---|---|
| LUI | `0110111` | — | U | 无 | `rd = imm_u` |
| AUIPC | `0010111` | — | U | PC | `rd = pc + imm_u` |
| JAL | `1101111` | — | J | PC | `rd = pc+4; pc = pc+imm_j` |
| JALR | `1100111` | `000` | I | rs1, PC | `rd = pc+4; pc = (rs1+imm_i) & ~1` |

JALR 的 funct3 必须为 `000`，其他 funct3 编码应视为非法。

## 7. Conditional branch

所有 branch 使用 opcode `1100011` 和 B-type immediate，不写 rd。

| 指令 | funct3 | 读取 | 跳转条件 |
|---|---:|---|---|
| BEQ | `000` | rs1, rs2 | `rs1 == rs2` |
| BNE | `001` | rs1, rs2 | `rs1 != rs2` |
| BLT | `100` | rs1, rs2 | signed `rs1 < rs2` |
| BGE | `101` | rs1, rs2 | signed `rs1 >= rs2` |
| BLTU | `110` | rs1, rs2 | unsigned `rs1 < rs2` |
| BGEU | `111` | rs1, rs2 | unsigned `rs1 >= rs2` |

条件成立时：

```text
pc_next = pc + imm_b
```

条件不成立时：

```text
pc_next = pc + 4
```

## 8. Load

所有 load 使用 opcode `0000011` 和 I-type immediate：

```text
address = rs1 + imm_i
```

| 指令 | funct3 | 读取宽度 | 扩展方式 | 写回 |
|---|---:|---:|---|---|
| LB | `000` | 8-bit | sign extension | rd |
| LH | `001` | 16-bit | sign extension | rd |
| LW | `010` | 32-bit | 不扩展 | rd |
| LBU | `100` | 8-bit | zero extension | rd |
| LHU | `101` | 16-bit | zero extension | rd |

## 9. Store

所有 store 使用 opcode `0100011` 和 S-type immediate：

```text
address = rs1 + imm_s
```

| 指令 | funct3 | 写入数据 | 写 rd |
|---|---:|---|---:|
| SB | `000` | `rs2[7:0]` | 0 |
| SH | `001` | `rs2[15:0]` | 0 |
| SW | `010` | `rs2[31:0]` | 0 |

## 10. Milestone 2 查表：Register ALU

所有寄存器 ALU 指令使用 opcode `0110011` 和 R-type 格式。

| 指令 | funct3 | funct7 | 操作 |
|---|---:|---:|---|
| ADD | `000` | `0000000` | `rd = rs1 + rs2` |
| SUB | `000` | `0100000` | `rd = rs1 - rs2` |
| SLL | `001` | `0000000` | logical left shift |
| SLT | `010` | `0000000` | signed comparison |
| SLTU | `011` | `0000000` | unsigned comparison |
| XOR | `100` | `0000000` | bitwise XOR |
| SRL | `101` | `0000000` | logical right shift |
| SRA | `101` | `0100000` | arithmetic right shift |
| OR | `110` | `0000000` | bitwise OR |
| AND | `111` | `0000000` | bitwise AND |

## 11. Milestone 3 查表：Immediate ALU

所有 immediate ALU 指令使用 opcode `0010011` 和 I-type 格式。

| 指令 | funct3 | `instr[31:25]` | 操作 |
|---|---:|---:|---|
| ADDI | `000` | immediate | `rd = rs1 + imm_i` |
| SLTI | `010` | immediate | signed `rd = (rs1 < imm_i)` |
| SLTIU | `011` | immediate | unsigned `rd = (rs1 < imm_i)` |
| XORI | `100` | immediate | `rd = rs1 ^ imm_i` |
| ORI | `110` | immediate | `rd = rs1 \| imm_i` |
| ANDI | `111` | immediate | `rd = rs1 & imm_i` |
| SLLI | `001` | `0000000` | `rd = rs1 << instr[24:20]` |
| SRLI | `101` | `0000000` | logical right shift |
| SRAI | `101` | `0100000` | arithmetic right shift |

注意：

- ADDI、SLTI、SLTIU、XORI、ORI、ANDI 的 `instr[31:20]` 整体都是 immediate；
  不得把 `instr[31:25]` 当 funct7 检查。
- SLTIU 先对 I-type immediate 做符号扩展，然后执行 unsigned comparison。
- shift-immediate 的 shift amount 是 `instr[24:20]`。

## 12. RV32M

所有 M 指令使用：

```text
opcode = 0110011
funct7 = 0000001
```

| 指令 | funct3 | 输入解释 | 输出 |
|---|---:|---|---|
| MUL | `000` | 32×32-bit | 乘积低 32 位 |
| MULH | `001` | signed × signed | 乘积高 32 位 |
| MULHSU | `010` | signed rs1 × unsigned rs2 | 乘积高 32 位 |
| MULHU | `011` | unsigned × unsigned | 乘积高 32 位 |
| DIV | `100` | signed | 商，向零舍入 |
| DIVU | `101` | unsigned | 商 |
| REM | `110` | signed | 余数 |
| REMU | `111` | unsigned | 余数 |

除法特殊情况：

| 条件 | DIV/DIVU 结果 | REM/REMU 结果 |
|---|---|---|
| divisor = 0 | `0xffffffff` | dividend |
| signed `0x80000000 / -1` | `0x80000000` | `0x00000000` |

RV32M 的除零和 signed overflow 不产生 arithmetic trap。

## 13. SYSTEM 与 memory ordering

| 指令 | opcode | 识别条件 | 项目中的行为 |
|---|---:|---|---|
| FENCE | `0001111` | `funct3=000` | 等待先前 memory operation 完成 |
| ECALL | `1110011` | 完整值 `0x00000073` | environment request/trap |
| EBREAK | `1110011` | 完整值 `0x00100073` | breakpoint；测试环境可用于停止 |

补充说明：

- `FENCE.I` 属于 Zifencei，不是严格 RV32IM 的一部分。
- CSR 指令属于 Zicsr，本项目当前范围不包含。
- NOP 不是新的硬件操作；标准 NOP 是 `ADDI x0, x0, 0`。
- 写 rd=x0 的普通指令仍可正常执行，只是 regfile 忽略最终写入。

## 14. Immediate 生成公式

| 类型 | 使用指令 | 32-bit 生成公式 |
|---|---|---|
| I | OP-IMM、load、JALR | `{{20{inst[31]}}, inst[31:20]}` |
| S | store | `{{20{inst[31]}}, inst[31:25], inst[11:7]}` |
| B | branch | `{{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0}` |
| U | LUI、AUIPC | `{inst[31:12], 12'b0}` |
| J | JAL | `{{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0}` |

## 15. 每个 milestone 的工作方式

每次开发都按相同顺序进行：

1. 从第 0 节确认唯一的“下一步”；
2. 在对应查表章节确认 opcode、funct3、funct7 和 immediate 类型；
3. 如果现有控制信号无法表达该指令，先扩展 package 和 decoder interface；
4. 修改 decoder 或对应执行模块；
5. 新建下一个累计 milestone test，并保留所有旧测试；
6. 测试合法 encoding 和至少一个相近的 reserved encoding；
7. 运行 `make test` 和 Yosys 检查。

不要为了消除 case 中未枚举的组合而把所有 bit pattern 写出来。Decoder 在进入 case
前设置安全默认值即可：未识别或 reserved encoding 保持 `illegal=1`，同时关闭
register write、memory write 和其他 architectural side effect。
