# Radix-2 迭代除法器：从竖式除法到 SystemVerilog

本文说明本项目的 RV32M 多周期整数除法器。对应文件为：

- `rtl/backend/rv32_divider.sv`
- `tb/unit/rv32_divider_tb.sv`

目标是实现 `DIV`、`DIVU`、`REM` 和 `REMU`，使用一个 33-bit
加减法数据通路，每周期生成一个商 bit。第一版优先保证接口、特殊情况和符号语义正确；
只有实际 STA 证明除法器迭代路径不满足目标频率后，才考虑 Radix-4、SRT 或更激进的实现。

## 1. 为什么不写组合除法

直接写：

```systemverilog
quotient = lhs / rhs;
remainder = lhs % rhs;
```

语义虽然简单，但综合后的组合路径通常很长，而且不同工具和 PDK 的实现差异较大。迭代
除法器只保留一份比较/减法硬件，重复使用 32 次：

```text
较小面积 + 较容易提高频率 + 多周期 latency
```

它不会像三级 multiplier 一样每周期接收一条请求。divider 忙碌时，
`req_ready_o=0`；未来 OoO core 仍可让 ALU、乘法器和 LSU 继续执行。

## 2. 接口合同

```systemverilog
input  logic                   clk_i;
input  logic                   rst_i;
input  logic                   req_valid_i;
output logic                   req_ready_o;
input  rv32_pkg::muldiv_op_e   op_i;
input  logic [31:0]            lhs_i;
input  logic [31:0]            rhs_i;
output logic                   resp_valid_o;
output logic [31:0]            result_o;
```

请求只在时钟上升沿满足以下条件时被接收：

```text
accept = req_valid_i && req_ready_o
```

第一版采用三个状态：

```text
IDLE -> RUN -> RESPOND -> IDLE
  \------ special ------^
```

- `IDLE`：`req_ready_o=1`，可以接收请求；
- `RUN`：执行 32 次无符号迭代，`req_ready_o=0`；
- `RESPOND`：`resp_valid_o=1` 一个周期，然后回到 `IDLE`。

普通除法从接收到响应需要 33 个周期：32 个迭代周期和 1 个响应周期。除 0 与 signed
overflow 不需要迭代，可以在接收后的下一个周期进入 `RESPOND`。接口是 variable
latency，因此使用者只能根据 `resp_valid_o` 判断结果是否有效。

复位是 synchronous active-high。复位必须取消正在执行的请求，并保证之后不会产生旧响应。

## 3. 四条指令的精确语义

| 指令 | lhs | rhs | 返回值 |
|---|---|---|---|
| `DIV` | signed | signed | quotient |
| `DIVU` | unsigned | unsigned | quotient |
| `REM` | signed | signed | remainder |
| `REMU` | unsigned | unsigned | remainder |

Signed division 向 0 截断。例如：

```text
  7 /  3 =  2, remainder =  1
 -7 /  3 = -2, remainder = -1
  7 / -3 = -2, remainder =  1
 -7 / -3 =  2, remainder = -1
```

因此：

- quotient 的符号为 `lhs_sign XOR rhs_sign`；
- remainder 的符号永远跟 dividend，也就是 `lhs`；
- quotient 和 remainder 的绝对值先用 unsigned divider 计算。

## 4. RISC-V 特殊情况

### 4.1 除数为 0

除 0 不产生 trap：

| 指令 | 结果 |
|---|---|
| `DIV/DIVU` | `32'hffff_ffff` |
| `REM/REMU` | 原始 `lhs` |

必须在进入迭代前识别，否则 unsigned 算法会产生错误或依赖未定义行为。

### 4.2 Signed overflow

32-bit two's-complement 唯一的除法 overflow 是：

```text
0x80000000 / 0xffffffff
INT_MIN      / -1
```

结果固定为：

```text
DIV result = 32'h8000_0000
REM result = 32'h0000_0000
```

同样不产生 trap。

## 5. 先转换成无符号 magnitude

对于 `DIV` 和 `REM`：

```text
dividend_magnitude = abs(lhs)
divisor_magnitude  = abs(rhs)
quotient_negative  = lhs[31] XOR rhs[31]
remainder_negative = lhs[31]
```

对于 `DIVU` 和 `REMU`：

```text
dividend_magnitude = lhs
divisor_magnitude  = rhs
quotient_negative  = 0
remainder_negative = 0
```

32-bit magnitude 可以用二进制补码求绝对值：

```systemverilog
magnitude = value[31] ? (~value + 32'd1) : value;
```

`abs(INT_MIN)` 的 bit pattern 仍是 `32'h8000_0000`。它不能表示成 signed 正数，
但作为 unsigned magnitude 正好表示 2147483648，所以迭代数据通路应按 unsigned 处理。

## 6. Restoring division 的寄存器

推荐状态：

```systemverilog
logic [32:0] remainder_q;
logic [31:0] quotient_q;
logic [31:0] divisor_q;
logic [5:0]  iteration_q;
logic        quotient_negative_q;
logic        remainder_negative_q;
logic        return_remainder_q;
```

各寄存器的职责：

| 寄存器 | 接收请求时 | 完成时 |
|---|---|---|
| `remainder_q` | 0 | unsigned remainder magnitude |
| `quotient_q` | dividend magnitude | unsigned quotient magnitude |
| `divisor_q` | divisor magnitude | 保持不变 |
| `iteration_q` | 0 | 31 后完成最后一轮 |
| sign flags | 根据原始输入计算 | 用于最后恢复符号 |
| `return_remainder_q` | REM/REMU 为 1 | 选择返回商或余数 |

`remainder_q` 使用 33 bit，因为左移后需要保留额外一位，并与
`{1'b0, divisor_q}` 比较。

## 7. 每个周期做什么

每轮先把组合的 remainder/quotient 左移一位：

```systemverilog
shifted_remainder = {remainder_q[31:0], quotient_q[31]};
shifted_quotient  = {quotient_q[30:0], 1'b0};
```

然后试减 divisor：

```systemverilog
if (shifted_remainder >= {1'b0, divisor_q}) begin
  remainder_next   = shifted_remainder - {1'b0, divisor_q};
  quotient_next    = shifted_quotient;
  quotient_next[0] = 1'b1;
end else begin
  remainder_next = shifted_remainder;
  quotient_next  = shifted_quotient;
end
```

这和十进制竖式除法相同：把下一位 dividend 拉下来；如果当前 remainder 足够大，就减去
divisor，并把当前 quotient bit 写成 1。

### 7.1 13 / 3 的四位例子

```text
初始：remainder=0000, quotient=1101, divisor=0011
```

| 轮次 | shift 后 remainder | 是否减 3 | 新 remainder | 新 quotient |
|---:|---:|---|---:|---:|
| 0 | 0001 | 否 | 0001 | 1010 |
| 1 | 0011 | 是 | 0000 | 0101 |
| 2 | 0000 | 否 | 0000 | 1010 |
| 3 | 0001 | 否 | 0001 | 0100 |

最终：

```text
quotient = 0100 = 4
remainder = 0001 = 1
```

## 8. 最后一轮的常见 off-by-one 错误

当 `iteration_q==31` 时，本周期仍需完成第 32 次 shift/subtract。输出必须使用
`quotient_next` 和 `remainder_next`，不能使用寄存器中的旧值：

```text
错误：result <- quotient_q
正确：result <- quotient_next
```

然后根据保存的 sign flag 恢复符号：

```systemverilog
signed_quotient =
    quotient_negative_q ? (~quotient_next + 32'd1) : quotient_next;

signed_remainder =
    remainder_negative_q
      ? (~remainder_next[31:0] + 32'd1)
      : remainder_next[31:0];
```

最后由 `return_remainder_q` 选择写入 `result_o` 的值。

## 9. 推荐实现顺序

### Milestone A：接口和状态机

- synchronous reset 回到 `IDLE`；
- 仅 `IDLE` 时 `req_ready_o=1`；
- `RESPOND` 时 `resp_valid_o=1` 一个周期；
- busy 期间不能覆盖已保存请求。

此时不宣称算术正确，TB 应保持主动失败。

### Milestone B：只实现 DIVU

- 初始化 unsigned dividend/divisor；
- 运行 32 次 restoring iteration；
- 输出 quotient；
- 先测试小数和边界值。

### Milestone C：加入 REMU

复用完全相同的迭代结果，只把输出从 `quotient_next` 改为
`remainder_next[31:0]`。

### Milestone D：加入 DIV 和 REM

- 请求进入时转换 magnitude；
- 保存 quotient/remainder sign；
- 最后一轮恢复符号；
- 验证四种正负组合。

### Milestone E：特殊情况与控制验证

- divisor 为 0；
- `INT_MIN / -1`；
- reset 中断正在执行的请求；
- busy 时 `req_ready_o=0`；
- response 是单周期脉冲；
- 响应后能够接受下一条请求。

## 10. Testbench 应覆盖什么

Directed arithmetic：

```text
DIV:   7/3, -7/3, 7/-3, -7/-3
REM:   对应四种 remainder
DIVU:  UINT_MAX/2, 0/非零, 小于 divisor
REMU:  UINT_MAX%2, 0%非零, 小于 divisor
```

特殊情况：

```text
DIV/DIVU by zero
REM/REMU by zero
INT_MIN / -1
INT_MIN % -1
```

控制行为：

- 请求只在 `req_valid_i && req_ready_o` 时接受；
- 正常操作包含精确的 32 次迭代；
- busy 期间 `req_ready_o=0`；
- `resp_valid_o` 只拉高一个周期；
- reset 中断操作后不得产生旧 response。

TB 中的期望常量应由手算或软件参考提前确定。后续可以增加随机参考模型，但不能用随机
测试代替上述边界用例。

## 11. PPA 与后续优化

第一版每周期的主要组合路径是：

```text
33-bit shift/compare/subtract -> next-state mux
```

`make synth-divider` 只证明模块可以综合，不会给出可信频率。必须在目标 PDK 下完成
technology mapping 和 STA，再决定是否优化。

可能的后续方向：

- leading-zero based early-out，减少平均周期数；
- non-restoring division，调整每轮加减结构；
- Radix-4，每周期产生两个 quotient bit；
- SRT divider，使用冗余 digit set；
- 将最终符号恢复移出关键迭代路径。

这些优化会增加验证复杂度。第一版应保持清晰的 32 轮 restoring 算法，作为后续 PPA
比较的功能基准。

## 12. 接入处理器

Decoder 对 `funct7=0000001`、`funct3=100..111` 分别产生：

```text
MD_DIV, MD_DIVU, MD_REM, MD_REMU
```

顺序核必须在 divider 返回结果前阻止该指令写回。OoO 核不需要停止全部执行；issue queue
只等待 divider 的 `req_ready_o`，ROB 保存 destination 和完成状态，divider response
到达后再广播结果并将对应 ROB entry 标记为完成。

