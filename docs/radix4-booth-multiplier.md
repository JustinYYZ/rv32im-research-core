# Radix-4 Booth 流水乘法器：从算法到 SystemVerilog

本文说明本项目的 RV32M 高吞吐整数乘法器。目标不是给出一份可以直接复制的
完整答案，而是解释每一层硬件为什么存在、输入输出是什么，以及应该按什么顺序把它
实现并验证。

对应文件：

- `rtl/backend/rv32_multiplier.sv`
- `tb/unit/rv32_multiplier_tb.sv`
- `rtl/pkg/rv32_pkg.sv`

计划中的最终结构为：

```text
request
   |
   v
33-bit signedness normalization
   |
   v
Radix-4 Booth recoding and partial products
   |
   v
carry-save Wallace/Dadda-style reduction
   |
   v
final carry-propagate addition
   |
   v
MUL/MULH/MULHSU/MULHU result selection
```

接口目标是固定三周期响应，并允许每周期接收一条新乘法。这里的“三周期”是指请求在
上升沿 `N` 被接受后，结果和 `resp_valid_o` 在上升沿 `N+3` 出现。

## 1. 先区分三个性能概念

### 1.1 Latency

Latency 是一条请求从接受到产生结果需要多久。本项目目标：

```text
latency = 3 cycles
```

### 1.2 Initiation interval

Initiation interval，简称 II，是两条请求之间至少相隔多少周期。本项目目标：

```text
II = 1 cycle
```

因此，流水线填满之后可以出现：

```text
cycle N:   accept A
cycle N+1: accept B
cycle N+2: accept C
cycle N+3: accept D, return A
cycle N+4: accept E, return B
```

一条操作仍有三周期 latency，但吞吐率可以达到每周期一个结果。

### 1.3 Clock period

流水线只有在寄存器真正切开组合逻辑时才会提高频率。把三个寄存器全部放在一个完整
组合乘法器之后，只会增加 latency，不会缩短乘法器本身的 critical path。

## 2. RV32M 四条乘法指令

两个 32-bit 操作数的完整乘积最多需要 64 bit。四条指令只是对 signedness 和最终选择
的 32 bit 不同。

| Operation | lhs | rhs | Result |
|---|---|---|---|
| `MUL` | 任意 bit pattern | 任意 bit pattern | 完整乘积 `[31:0]` |
| `MULH` | signed | signed | signed product `[63:32]` |
| `MULHSU` | signed | unsigned | mixed product `[63:32]` |
| `MULHU` | unsigned | unsigned | unsigned product `[63:32]` |

`MUL` 不需要区分 signed 和 unsigned，因为相同输入 bit pattern 的乘积低 32 bit 相同。
差异只会出现在高位。

RISC-V 建议软件在同时需要完整乘积高低两半时，先发出 `MULH[[S]U]`，再发出 `MUL`。
后续 OoO core 可以识别这对指令并共享一次完整 64-bit 乘法，但第一版不需要实现融合。

## 3. 为什么统一扩展为 33 bit

SystemVerilog 中 signedness 和表达式宽度很容易产生隐式行为。一个比较清晰的方案是先把
每个输入显式扩展为 33 bit，再把它当作 signed 数进入统一乘法数据通路。

```text
signed input:   {input[31], input[31:0]}
unsigned input: {1'b0,      input[31:0]}
```

例如：

```text
32'hffff_ffff interpreted as signed   -> 33'b1_111...111 = -1
32'hffff_ffff interpreted as unsigned -> 33'b0_111...111 = 4294967295
```

虽然第二个扩展结果也存放在 `logic signed [32:0]` 中，但它的最高位为 0，所以仍然是正数。

操作对应的扩展方式为：

```text
MD_MUL:    lhs zero-extend, rhs zero-extend
MD_MULH:   lhs sign-extend, rhs sign-extend
MD_MULHSU: lhs sign-extend, rhs zero-extend
MD_MULHU:  lhs zero-extend, rhs zero-extend
```

通用的 signed 33×33 乘法结果宽度为 66 bit，因此项目定义：

```systemverilog
localparam int unsigned PRODUCT_WIDTH = 66;
```

原始 RV32 乘积仍只占结果的低 64 bit。`[65:64]` 是统一扩展带来的保护位，不能在部分积
生成或压缩中途提前丢弃。

## 4. 普通部分积为什么不够快

最直接的 unsigned 乘法是：乘数每有一个 bit 为 1，就生成一行移位后的被乘数。

```text
A × B = B[0]·A + B[1]·(A<<1) + ... + B[31]·(A<<31)
```

32-bit 乘法最多产生 32 行部分积。如果用普通加法器依次相加，carry 会在每个加法器中
从低位传播到高位，critical path 很长。

高速乘法器分别解决两个问题：

1. Booth recoding 减少部分积行数；
2. carry-save tree 避免在压缩阶段传播完整 carry。

## 5. Radix-4 Booth recoding

### 5.1 Booth 的核心观察

一串连续的 1 可以改写成一次加法和一次减法。例如：

```text
00111100 = 01000000 - 00000100
```

因此，与其为连续四个 1 生成四行部分积，不如生成一个正部分积和一个负部分积。

Radix-4 modified Booth 每次观察乘数的两个新 bit，同时保留一个重叠 bit。每组 3 bit
选择被乘数的五种倍数之一：

| Booth code | Selected multiple |
|---|---:|
| `000` | `0` |
| `001` | `+A` |
| `010` | `+A` |
| `011` | `+2A` |
| `100` | `-2A` |
| `101` | `-A` |
| `110` | `-A` |
| `111` | `0` |

`2A` 是左移一位；负数使用二进制补码。每个相邻 Booth group 负责两个乘数 bit，因此第
`i` 个部分积最终左移 `2*i`。

### 5.2 一个手算例子

考虑 4-bit signed 乘数 `B=-3=4'b1101`。在最低位下面补一个 0：

```text
B bits:       1 1 0 1
appended bit:         0
```

从低位开始分组：

```text
group 0 = {B[1], B[0], 0} = 010 -> +A
group 1 = {B[3], B[2], B[1]} = 110 -> -A, shifted left 2
```

所以：

```text
A + (-A << 2) = A - 4A = -3A
```

对于 unsigned `4'b1101=13`，不能把最高位 1 当作符号。必须在顶部补 0，于是还会产生
一个最高 group：

```text
+A + (-A << 2) + (A << 4) = A - 4A + 16A = 13A
```

这就是统一扩展为 33 bit 的重要原因：unsigned 32-bit 最大值需要第 33 位 0，不能被
误解成负数。

### 5.3 32-bit 实现中的精确分组

`rhs_ext` 有 33 bit。为了生成所有 group，在底部补 0，并在顶部复制其符号位：

```systemverilog
logic [34:0] booth_bits;

booth_bits = {rhs_ext[32], rhs_ext, 1'b0};
```

总共有 17 个 group：

```systemverilog
localparam int unsigned BOOTH_GROUPS = 17;

code_i = booth_bits[2*i +: 3];  // i = 0 ... 16
```

其中：

```text
i=0  -> booth_bits[2:0]
i=1  -> booth_bits[4:2]
...
i=16 -> booth_bits[34:32]
```

每一组产生一个 `PRODUCT_WIDTH` 宽度的 signed partial product：

```text
partial_product[i] = selected_multiple(A) <<< (2*i)
```

第一版应直接把负部分积完整符号扩展到 66 bit。更紧凑的 sign-correction 编码可以以后
再做；不要同时调试 Booth recoding、符号修正和压缩树。

### 5.4 推荐的 Booth helper

可以先写一个只负责选择倍数的 function，先用小位宽单测它，再接入 17 个 group：

```systemverilog
function automatic logic signed [PRODUCT_WIDTH-1:0] booth_multiple(
  input logic [2:0] code,
  input logic signed [PRODUCT_WIDTH-1:0] multiplicand
);
  // TODO: 根据 Booth table 返回 0、A、2A、-A 或 -2A。
endfunction
```

这个 function 不负责 `2*i` 的位置移位。把“选择倍数”和“放到正确权重”分开，更容易
从波形判断错误来自哪里。

## 6. Carry-save compression

### 6.1 普通加法的问题

如果写成：

```text
((((pp0 + pp1) + pp2) + pp3) + ...)
```

每一级都可能产生一次完整 carry propagation，延迟随部分积数量快速增加。

### 6.2 3:2 compressor

3:2 compressor 接收三个同宽数字，输出两个数字，同时保持总数值不变：

```text
a + b + c = sum + carry
```

按 bit 写可以表示为：

```systemverilog
sum   = a ^ b ^ c;
carry = ((a & b) | (a & c) | (b & c)) << 1;
```

这里 `carry` 已经左移一位。后续最终相加时不要再次左移，否则结果会扩大一倍。

这个操作每一列只经过一个 full-adder 级，不需要让 carry 在 66 bit 中横向传播。因此可以
并行地把很多行压缩成两行，最后才进行一次普通加法：

```text
17 partial-product rows
        |
        v
multiple 3:2 compression levels
        |
        v
sum_row + carry_row
        |
        v
full product
```

### 6.3 容易实现的 Wallace-style 行压缩

先把每三行压成两行，剩余一行或两行直接传到下一层。行数大致变化为：

```text
17 -> 12 -> 8 -> 6 -> 4 -> 3 -> 2
```

这不是按每一列做最少 compressor 的严格 Dadda 布局，但算法清晰，适合作为第一个可验证
的手写压缩树。每一层必须只读取上一层，不能在同一个 `always_comb` 中意外形成反馈。

### 6.4 严格 Dadda 的目标列高

Dadda tree 不是看到三个位就立刻压缩，而是让每一级的最大列高依次满足目标：

```text
2, 3, 4, 6, 9, 13, 19, ...
```

对于最高列高不超过 17 的输入矩阵，实际从高到低使用：

```text
13 -> 9 -> 6 -> 4 -> 3 -> 2
```

每一级只使用足够的 half adder 和 full adder 把超过目标高度的列压下来。与立即压缩的
Wallace tree 相比，Dadda 通常减少 compressor 数量，但实现时必须逐列追踪 sum 和 carry
进入下一列，代码和验证都会更复杂。

推荐开发顺序：

1. 整行 3:2 CSA tree；
2. 确认所有随机乘积正确；
3. 保存综合面积和时序；
4. 再替换成严格 Dadda column schedule；
5. 比较面积、critical path 和布线结果。

## 7. 最终 carry-propagate adder

压缩树最后得到两行：

```text
product = sum_row + carry_row
```

这是数据通路中唯一必须跨完整宽度传播 carry 的位置。第一版直接使用 `+`，让 Yosys 和
technology mapping 决定结构。若 post-synthesis 或 post-route timing 显示它是关键路径，
再比较：

- carry-select adder；
- Brent-Kung parallel-prefix adder；
- Kogge-Stone parallel-prefix adder。

不要在没有 timing report 时先手写最复杂的前缀加法器。更复杂的结构可能因为扇出和
布线拥塞，在布局布线后反而没有优势。

## 8. 三级流水如何划分

概念上有三个计算阶段：

| Stage | Main work | Registered state |
|---|---|---|
| 0 | signedness、Booth recoding、部分积生成 | partial products、op、valid |
| 1 | carry-save reduction | sum row、carry row、op、valid |
| 2 | final addition、RV32M result select | result、response valid |

请求在上升沿 `N` 被接受后，可以把输入先保存在请求寄存器中，然后让三个计算阶段在
`N→N+1`、`N+1→N+2` 和 `N+2→N+3` 之间执行。接口因此在 `N+3` 返回结果。

如果综合报告显示 stage 1 的 compressor levels 太多，可以把一部分 compression 移到
stage 0；接口 latency 不变，只是重新平衡寄存器两侧的组合逻辑。流水边界应该由 timing
data 决定，不应只按照算法名称划分。

### 8.1 Valid 必须和数据一起移动

需要同时流水以下状态：

```text
valid
operation
partial product / compressed rows
```

如果只流水 product、不流水 `op`，连续执行 `MUL` 和 `MULH` 时会用后一个 operation
选择前一个 product 的高低半。

### 8.2 Bubble 也必须移动

当某周期 `req_valid_i=0` 时，该位置是一个 bubble。三周期后 `resp_valid_o` 也必须为
0。数据寄存器可以保留旧值，但只要 valid 为 0，core 就不能把它当作新结果。

### 8.3 Reset

同步 reset 至少必须清除所有 valid。清除数据寄存器便于观察波形，但从功能上说，失效
数据的具体值并不重要。关键约束是 reset 之后不能出现陈旧 `resp_valid_o`。

## 9. 不要直接从 Booth 开始：先建立 baseline

优化前先使用一次临时的 33×33 `*`：

```text
1. 完成 request/response timing；
2. 完成 signedness extension；
3. 完成 op pipeline；
4. 完成四条指令的 result selection；
5. 让全部 TB 通过；
6. 保存 Yosys/OpenROAD baseline；
7. 保持接口和 TB 不变，替换内部乘法算法。
```

这个 baseline 不是最终实现，但它把两类错误分开：

- 如果 baseline 失败，问题在接口、signedness、位宽、流水或 TB；
- 如果 baseline 通过而 Booth 失败，问题在 recoding、partial product 或 reduction。

没有 baseline 时，面对一个错误结果很难判断错误属于哪一层。

## 10. 推荐的 RTL 实现顺序

### Milestone A：握手和 valid pipeline

只实现：

```text
accept = req_valid_i && req_ready_o
valid_s0 -> valid_s1 -> valid_s2 -> resp_valid_o
```

用 bubble 波形确认固定延迟。此时结果可以暂时保持 0，但测试不能宣称乘法正确。

### Milestone B：baseline 完整乘法

加入 33-bit 扩展、66-bit `*`、op pipeline 和结果选择。先完成单请求测试，再完成连续请求。

### Milestone C：Booth 部分积

暂时不要连接 compression tree。把 17 个 Booth 部分积用普通宽加法求和，并与 baseline
完整 product 比较。这样单独验证 recoding 和 sign extension。

### Milestone D：CSA tree

用整行 3:2 compressor 替换普通求和。每完成一层，都可以在 TB 或波形中检查：

```text
sum(input rows) == sum(output rows)
```

最终验证：

```text
sum(all partial products) == sum_row + carry_row
```

### Milestone E：三级流水

在选定边界插入寄存器，并让 valid 和 op 同步移动。重新执行单请求、back-to-back 和
bubble 测试。

### Milestone F：严格 Dadda 和 timing 调整

只有在前面全部正确后，才按列高目标优化 compressor 数量，并根据 STA 重新平衡流水级。

## 11. Testbench 应覆盖什么

### 11.1 Directed arithmetic cases

以下结果可以作为第一组显式常量：

| Operation | lhs | rhs | Expected result |
|---|---:|---:|---:|
| MUL | `0x00000003` | `0x00000007` | `0x00000015` |
| MUL | `0xffffffff` | `0x00000002` | `0xfffffffe` |
| MUL | `0x80000000` | `0x00000002` | `0x00000000` |
| MULH | `0xfffffffe` | `0x00000003` | `0xffffffff` |
| MULH | `0x80000000` | `0x80000000` | `0x40000000` |
| MULHSU | `0xfffffffe` | `0x00000003` | `0xffffffff` |
| MULHSU | `0xffffffff` | `0xffffffff` | `0xffffffff` |
| MULHU | `0xffffffff` | `0xffffffff` | `0xfffffffe` |

还应覆盖 0、1、最大正数、不同符号组合以及随机输入。

### 11.2 Timing cases

Arithmetic 正确不代表流水正确。TB 还必须独立检查：

- 请求只在 `req_valid && req_ready` 时接受；
- 单请求恰好三周期后返回；
- reset 清空所有在途 valid；
- 连续四周期请求产生连续四周期响应；
- 输入 bubble 三周期后成为输出 bubble；
- operation 和对应 result 没有错位。

### 11.3 Reference model

Directed case 应使用手工写出的 expected constant。随机测试可以在 TB 中使用 64-bit `*`
作为 reference model，但不能只用与 DUT 完全相同的表达式覆盖所有验证，否则共同的位宽
或 signed cast 错误可能同时出现在 DUT 和 checker 中。

## 12. 常见错误

### 12.1 在乘法之后才 cast signed

错误思路：

```systemverilog
$signed(lhs_i * rhs_i)
```

乘法已经按照原表达式的宽度和 signedness 发生，事后 cast 无法恢复丢失的高位。应该先
扩展和 cast operand，再乘。

### 12.2 只为 unsigned 输入保留 32 bit

`0xffffffff` 在 32-bit signed 中是 -1，在 unsigned 中是 4294967295。unsigned operand
必须在顶部显式补 0，形成正的 33-bit 数。

### 12.3 缺少最高 Booth group

只生成 16 个 group 会把最高位为 1 的 unsigned multiplier 当成负数。33-bit normalized
multiplier 需要 17 个 group。

### 12.4 负部分积没有完整符号扩展

`-A` 和 `-2A` 在左移前后都必须保持 PRODUCT_WIDTH 的二进制补码表示。否则高半乘积
通常错误，而某些 `MUL` 低半测试仍可能碰巧通过。

### 12.5 Carry 被左移两次

如果 compressor 已经产生：

```systemverilog
carry = majority(a, b, c) << 1;
```

最终应直接计算 `sum + carry`，不能再写 `sum + (carry << 1)`。

### 12.6 Op 没有流水

数据、valid 和 operation 必须经过相同数量的寄存器。只要支持 back-to-back request，这个
错误就会立即出现。

### 12.7 把 PASS 建立在空 TB 上

未完成的 TB 应主动失败。只有 directed arithmetic、latency、back-to-back 和 bubble 都
执行后，才能把 `test-multiplier` 加入总 `make test`。

## 13. 综合和时序评估

功能测试通过后，依次保存：

```text
baseline inferred '*'
Booth + simple CSA tree
Booth + strict Dadda tree
pipeline partition adjustments
```

每个版本至少记录：

- combinational cell area；
- register area；
- worst negative slack；
- critical path 起点和终点；
- target clock period；
- post-route maximum frequency；
- 每周期可接受请求数量。

`make synth-multiplier` 只证明 Yosys 可以综合并且结构检查通过，不会给出可信的 1 GHz
结论。频率必须绑定具体 standard-cell library、clock constraint 和 PDK，并完成 OpenROAD
布局布线和 STA。

## 14. 与 decoder 和 OoO core 的关系

乘法器独立通过后，decoder 才增加 `muldiv_op_o`。所有 RV32M 指令满足：

```text
opcode = 0110011
funct7 = 0000001
```

`funct3` 决定八种 `muldiv_op_e`。乘法器只接受 `MD_MUL` 到 `MD_MULHU`；除法操作进入以后
单独实现的 divider。

未来接入 OoO core 时，issue queue 只在 multiplier 可接受时发射请求，ROB/physical
destination tag 与 operation 一起经过相同流水级。当前单元暂时不携带 tag，是为了先把
算术和固定 latency 验证清楚；后续可以在 wrapper 中增加 metadata pipeline，而不修改
Booth/Dadda 数据通路。

## 15. 完成检查表

- [ ] 能手算 Radix-4 Booth table 和一个负数例子；
- [ ] 能解释 unsigned 输入为什么要扩展成 33 bit；
- [ ] baseline 四条乘法全部正确；
- [ ] 17 个 Booth partial products 的普通求和等于 baseline product；
- [ ] 每一级 CSA 前后的数值和相同；
- [ ] 最终 `sum_row + carry_row` 等于完整 product；
- [ ] latency 固定为三周期；
- [ ] back-to-back request 每周期产生一个有序结果；
- [ ] bubble 和 reset 不产生伪响应；
- [ ] Verilator lint 和 Yosys check 通过；
- [ ] 保存 baseline 与 optimized 的面积及时序报告；
- [ ] 完成指定 PDK 下的 post-route STA 后再报告最大频率。

## 参考资料

- [RISC-V Unprivileged ISA：M extension](https://docs.riscv.org/reference/isa/unpriv/m-st-ext.html)
- [A. D. Booth, “A Signed Binary Multiplication Technique,” 1951](https://academic.oup.com/qjmam/article/4/2/236/1874893)
- [L. Dadda, “Some Schemes for Parallel Multipliers,” 1965](https://ieeemilestones.ethw.org/w/images/8/82/Some_schemes_for_parallel_multipliers_%28reprint%29.pdf)
- [C. S. Wallace, “A Suggestion for a Fast Multiplier,” 1964](https://doi.org/10.1109/PGEC.1964.263830)
- [BOOM Execute Pipeline documentation](https://docs.boom-core.org/en/latest/sections/execution-stages.html)
