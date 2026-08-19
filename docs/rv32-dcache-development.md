# RV32 L1 D-cache 开发教程

本文档说明如何在现有 pipeline data-memory port 和 backing memory 之间实现第一版 L1 D-cache。目标不是复制 I-cache 后改几个端口，而是理解 D-cache 为什么需要 store merge、dirty state、write-back、write-allocate 和更严格的错误顺序。

第一版配置固定为设计基线：

| 项目 | 第一版 D-cache |
|---|---:|
| 容量 | 32 KiB |
| Line size | 32 byte |
| Associativity | Direct-mapped |
| CPU access width | 一个32-bit aligned word，带4-bit byte mask |
| Write policy | Write-back |
| Store miss policy | Write-allocate |
| Miss handling | Blocking，最多一个 outstanding transaction |

容量和 line size 仍通过 parameter 表达。完成并验证 direct-mapped baseline 后，再考虑2-way、64-byte line 或 non-blocking cache。

## 1. D-cache 为什么比 I-cache 复杂

I-cache 只需要回答一个问题：“这个地址对应的 instruction 是否在 cache 中？”如果不在，就从 lower memory 读完整 line。

D-cache 同时面对 load 和 store：

| 情况 | I-cache | D-cache |
|---|---|---|
| Hit | 返回 instruction | load 返回 data；store 修改部分 byte |
| Line state | valid、tag、data | valid、dirty、tag、data |
| Miss | refill | 可能先 writeback victim，再 refill |
| Refill 后 | 返回 word | load 返回 word；store merge 后置 dirty |
| Lower write | 没有 | dirty eviction 需要整 line writeback |
| 错误顺序 | refill error | writeback error 和 refill error 必须区分 |

所以复杂度主要来自控制状态和验证组合，而不是地址分解本身。第一版仍然是 blocking cache，因此不需要 MSHR、多个 miss 合并或 load/store queue。

## 2. D-cache 与 LSU 的职责边界

现有 `rv32_lsu.sv` 已经完成 RISC-V load/store 的指令语义：

- 检查 byte、halfword 和 word alignment；
- 把原始 byte address 对齐到32-bit word address；
- 把 SB、SH、SW 的 `rs2` 数据移动到正确 byte lane；
- 产生4-bit store mask；
- 从返回 word 中选择 byte/halfword，并做 signed 或 unsigned extension。

D-cache 不应重复这些工作。它看到的 CPU request 已经是一个 aligned 32-bit transaction：

```text
Load : write=0, addr=aligned address, wstrb=0000
SB   : write=1, addr=aligned address, wstrb=0001/0010/0100/1000
SH   : write=1, addr=aligned address, wstrb=0011 或 1100
SW   : write=1, addr=aligned address, wstrb=1111
```

例如源程序执行：

```text
SB x5, 1(x6)
```

假设 `x6 + 1 = 0x1041` 且 `x5[7:0] = 0xaa`，LSU 送给 D-cache 的信号应为：

```text
addr  = 0x00001040
wdata = 0x0000aa00
wstrb = 0010
```

D-cache 只根据 `wstrb[1]` 替换 cached word 的 `[15:8]`，不再解释这条指令是 SB。

## 3. CPU 和 lower-memory interface

`rtl/cache/rv32_dcache.sv` 的 CPU side 与 pipeline dmem port 一一对应：

| Signal | 含义 |
|---|---|
| `cpu_req_valid_i` | CPU 正在提供一个 load/store request |
| `cpu_req_ready_o` | D-cache 本周期可以接受 request |
| `cpu_req_addr_i` | 已对齐的32-bit byte address |
| `cpu_req_write_i` | 0 为 load，1 为 store |
| `cpu_req_wdata_i` | 已移动到正确 byte lane 的 store data |
| `cpu_req_wstrb_i[3:0]` | 每一位控制对应8-bit byte lane |
| `cpu_resp_valid_o` | 当前 request 已完成 |
| `cpu_resp_rdata_o` | load 返回的完整32-bit word；store 时忽略 |
| `cpu_resp_error_o` | backing access 失败 |

Lower-memory side 使用同样的32-bit request/response protocol。区别在于 cache refill 发出 read，而 dirty eviction 发出 write：

```text
Refill read    : mem_req_write_o=0, mem_req_wstrb_o=0000
Victim write  : mem_req_write_o=1, mem_req_wstrb_o=1111
```

每个 accepted lower request 都必须等待一个 `mem_resp_valid_i`，之后才能发下一个 word。这样与现有 simple memory 的单 outstanding protocol 一致。

## 4. D1：地址分解

D-cache 和 I-cache 使用相同 geometry：

```text
CACHE_BYTES    = 32768
LINE_BYTES     = 32
WORD_BYTES     = 4
WORDS_PER_LINE = 8
SET_COUNT      = 1024
OFFSET_BITS    = 5
INDEX_BITS     = 10
TAG_BITS       = 17
```

地址仍分为：

```text
31                    15 14             5 4              0
+-----------------------+----------------+----------------+
|       Tag[16:0]       |  Index[9:0]    |  Offset[4:0]   |
+-----------------------+----------------+----------------+
```

地址分解逻辑需要驱动以下信号：

```systemverilog
cpu_req_offset
cpu_req_index
cpu_req_word_index
cpu_req_tag
cpu_req_line_base
```

关系为：

```text
offset    = address 最低 OFFSET_BITS
index     = 从 OFFSET_BITS 开始的 INDEX_BITS
wordIndex = 从 bit 2 开始的 WORD_INDEX_BITS
tag       = address 最高 TAG_BITS
lineBase  = address 低 OFFSET_BITS 清零
```

不要写死 `[14:5]`。使用 localparam 和 indexed part-select，保证之后改变容量或 line size 时不需要重写地址切片。

DT1 使用与 I-cache 相同的 directed cases：

| Address | Tag | Index | Offset | Word index | Line base |
|---:|---:|---:|---:|---:|---:|
| `0x00000000` | `0x00000` | `0x000` | `0x00` | `0` | `0x00000000` |
| `0x0000104c` | `0x00000` | `0x082` | `0x0c` | `3` | `0x00001040` |
| `0x0000904c` | `0x00001` | `0x082` | `0x0c` | `3` | `0x00009040` |
| `0x00007ffc` | `0x00000` | `0x3ff` | `0x1c` | `7` | `0x00007fe0` |

完成 DT1 时，在 `check_address_fields()` 中：

1. 把 `address` 赋给 `cpu_req_addr`；
2. 等待 `#1` 让组合逻辑稳定；
3. 使用 `!==` 检查五个 `dut.cpu_req_*` 信号；
4. 调用表中的四组 case，覆盖不同 tag、index 和 line offset。

在分阶段实现时，DT1 只证明 parameter geometry 正确，不代表 request/response 控制已经完成。

## 5. D2：数组、Load Hit 和 Store Hit

Direct-mapped D-cache 需要四组 array：

```text
valid_array[SET_COUNT]
dirty_array[SET_COUNT]
tag_array[SET_COUNT][TAG_BITS]
data_array[SET_COUNT][LINE_BITS]
```

Load hit 条件为：

```text
hit = valid_array[index] && tag_array[index] == request_tag
```

命中后用 word index 从256-bit line 选择一个32-bit word，并通过 `cpu_resp_rdata_o` 返回。

Store hit 不能直接执行：

```systemverilog
cached_word = cpu_req_wdata_i;
```

因为 SB/SH 只允许修改部分 byte。正确关系是对每个 lane 独立判断：

```text
for lane = 0..3:
    if saved_wstrb[lane] == 1:
        new_word[lane*8 +: 8] = saved_wdata[lane*8 +: 8]
    else:
        new_word[lane*8 +: 8] = old_word[lane*8 +: 8]
```

然后把 merged word 写回 line 中原来的 word position：

```text
data_array[index][word_index * 32 +: 32] = merged_word
dirty_array[index] = 1
```

Store hit 不访问 lower memory，但仍必须向 CPU 返回一次 successful response，否则 pipeline 会一直等待。

D2 必须先把 CPU request 保存到寄存器，再进行 lookup。至少保存：

```text
request_addr_q
request_write_q
request_wdata_q
request_wstrb_q
```

原因与 I-cache 相同：request handshake 后，CPU 输入在后续周期可以改变，cache 不能继续依赖 live input。

DT2 至少测试：

- load hit 返回正确 word；
- store byte 分别修改四个 lane；
- store halfword 修改低/高两个 lane；
- store word 替换完整 word；
- 未被 mask 选中的 byte 保持不变；
- 每个 store hit 设置 dirty；
- hit 不产生 lower-memory request；
- busy 时 `cpu_req_ready_o=0`。

## 6. D3：Clean Miss、Refill 和 Write-allocate

Miss 不一定需要 writeback：

| 当前 set 状态 | 下一步 |
|---|---|
| invalid | 直接 refill |
| valid、tag 不同、dirty=0 | 直接 refill |
| valid、tag 不同、dirty=1 | 先 writeback，再 refill |

D3 只实现前两种 clean miss。与 I-cache 一样，使用单独 `refill_buffer_q` 收集8个 lower read response。最后一个 word 返回后，不要让 array 中出现半条新 line；先完成 buffer，再一次性安装 tag、data 和 valid。

Load miss 完成过程：

```text
save CPU load request
        ↓
lookup miss and victim clean
        ↓
read word 0 ... word 7 into refill buffer
        ↓
atomically install new line, dirty=0
        ↓
return requested word to CPU
```

Store miss 使用 write-allocate：

```text
save CPU store request
        ↓
refill complete line
        ↓
merge saved store data/mask into requested word
        ↓
install line with dirty=1
        ↓
return successful response
```

为什么 store miss 不能只把 store word 放进空 line？因为同一 line 中其他7个 word 仍包含 lower memory 的有效数据。以后读取那些 word 时必须得到正确值，所以先 refill，再 merge store。

DT3 需要检查 accepted lower requests，而不是 `mem_req_valid_o` 保持了多少周期：

```text
accepted = mem_req_valid_o && mem_req_ready_i
```

测试矩阵：

- cold load miss 恰好产生8个 read；
- refill 地址依次为 line base + 0、4、...、28；
- refill 后同 line load hit 不访问 lower memory；
- clean conflict miss 覆盖旧 line；
- cold store miss 先读8个 word；
- refill 后只有 masked byte 被修改；
- store-allocated line 标记 dirty；
- response data/error 与 request 类型一致。

## 7. D4：Dirty Victim Writeback

这是 D-cache 相比 I-cache 最关键的新路径。发生 tag mismatch 时，array 中的 tag 属于旧 line，CPU request tag 属于新 line。必须同时保存两套 metadata：

```text
requested line: request_tag, request_index, request_line_base
victim line:    victim_tag_q, victim_line_q, lookup_dirty
```

Victim line base 必须由旧 tag 重建：

```text
victim_line_base = {victim_tag, request_index, OFFSET_BITS 个 0}
```

不能使用新 request 的 line base，否则会把旧数据写到新地址，造成 silent memory corruption。

Dirty miss 状态顺序：

```text
IDLE
  ↓ save CPU request
LOOKUP
  ↓ miss && victim valid && victim dirty
WRITEBACK_REQUEST
  ↓ lower request accepted
WRITEBACK_WAIT
  ↓ lower write response
  ├─ more victim words → WRITEBACK_REQUEST
  └─ last victim word  → REFILL_REQUEST
REFILL_REQUEST / REFILL_WAIT
  ↓ collect new line
REFILL_INSTALL
  ↓ replay saved load/store
RESPONSE
```

每次 victim write 使用：

```text
mem_req_addr_o  = victim_line_base + transfer_count * 4
mem_req_write_o = 1
mem_req_wdata_o = victim_line_q[transfer_count_q * 32 +: 32]
mem_req_wstrb_o = 1111
```

即使最初使 line 变 dirty 的只是 SB，writeback 也写完整32-bit word。Cache line 已保存 merge 后的完整 word，因此 full-word writeback 最简单且正确。

### Backpressure

当 `mem_req_valid_o=1` 且 `mem_req_ready_i=0` 时，以下信号必须保持：

- request type 不变；
- address 不变；
- write data 和 strobe 不变；
- transfer counter 不增加。

只有 handshake 后才能进入 WAIT，只有 response 后才能开始下一个 word。

### Error policy

第一版采用保守、可恢复的行为：

- writeback error：立即停止 miss，不开始 refill，保留旧 valid/dirty line，向 CPU 返回 error；
- refill error：不安装部分 line，保留原 array entry，向 CPU 返回 error；
- 成功 refill：最后一次性替换旧 entry。

为了实现 refill error 时保留旧 line，不要在 miss 开始时提前清除 valid、dirty 或覆盖 tag/data。

DT4 必须检查：

- dirty conflict 先产生8个 write，再产生8个 read；
- writeback 使用旧 tag 重建地址；
- 八个 victim word 的顺序、数据和 `1111` strobe 正确；
- writeback 完成前没有 refill request；
- backpressure 时 lower request 稳定且不重复计数；
- writeback error 不破坏旧 line；
- refill error 不安装新 line；
- error 后 cache 可以接受下一条 CPU request。

## 8. Reset 和可综合存储

Reset 必须清除所有 valid bit。Dirty bit 只在 valid=1 时有意义，但第一版建议同时清零，便于 assertion 和 waveform 阅读。Tag/data 不需要 reset：valid=0 时它们不能形成 hit。

不要 reset 32 KiB data array。把整块 data array 放入同步 reset 会阻止多数 SRAM inference，并产生巨大的 reset mux 和 flip-flop 网络。

当前 SystemVerilog array 适合功能仿真。进行有意义的 OpenROAD PPA 前，data array 应映射到 SRAM macro；否则工具可能把32 KiB data storage 展开为寄存器，面积、功耗和频率不代表工业 cache 实现。

## 9. D5：Pipeline Integration

Standalone D-cache 完整通过后，再新建 integration wrapper。不要修改已经验证的 `rv32_pipeline_core.sv`，而是在外部连接：

```text
pipeline imem port → rv32_icache → backing instruction memory
pipeline dmem port → rv32_dcache → backing data memory
```

在 unified L2 出现前，I-cache 和 D-cache 可以暂时保留两组独立 backing ports。将来加入 L2 时再增加仲裁器，把 instruction refill、data refill 和 dirty writeback 转换为 cache-line transaction。

Pipeline 集成测试至少包含：

- load miss 后提交正确 rd value；
- 同 line 第二次 load hit 不增加 backing read count；
- SB/SH/SW hit 后，随后 load 观察到 merged data；
- store miss 使用 write-allocate；
- dirty eviction 后 backing memory 收到修改后的 line；
- data access error 产生与原 pipeline 相同的 precise trap；
- reference-vs-pipeline commit trace 仍按退休顺序一致。

Cache 允许改变 cycle count 和 backing request count，不允许改变 architectural commit 内容。

## 10. 推荐 RTL 状态和寄存器

实现控制器前，先列出状态和必须跨周期保存的信息，再按 request、writeback、refill 和 response 路径逐个填充状态分支。

建议状态：

```text
IDLE
LOOKUP
WRITEBACK_REQUEST
WRITEBACK_WAIT
REFILL_REQUEST
REFILL_WAIT
REFILL_INSTALL
RESPONSE
```

建议寄存器：

```text
state_q
request_addr_q
request_write_q
request_wdata_q
request_wstrb_q
response_rdata_q
response_error_q
transfer_count_q
refill_buffer_q
victim_tag_q
victim_line_q
```

`request_index`、`request_tag`、`request_word_index` 和两个 line base 可以从这些寄存器组合推导，不一定都需要重复保存。原则是：只保存 handshake 后仍必须稳定、且不能从已保存信息重新计算的值。

## 11. 构建命令

只编译 D-cache testbench：

```bash
make CAD_ENV=/path/to/env.sh compile-dcache
```

运行 D-cache self-checking regression：

```bash
make CAD_ENV=/path/to/env.sh test-dcache
```

`test-dcache` 覆盖地址分解、lookup、masked store、clean refill、write-allocate、dirty eviction、backpressure 和 access-error 路径，并已纳入总 `make test` 回归。测试按功能拆分为独立 task，但保持既定调用顺序，因为后续 eviction case 会复用前一 case 建立的 cache state。

## 12. Standalone 完成标准

- parameter geometry 和地址分解通过；
- load hit 和所有 byte-mask store hit 通过；
- cold load/store miss 各产生恰好8个 refill read；
- store miss 正确执行 write-allocate；
- dirty conflict 先8次 writeback，再8次 refill；
- victim address 使用旧 tag 正确重建；
- backpressure 下 request 稳定且没有重复 transaction；
- writeback/refill error 不产生部分安装或 silent data loss；
- reset 后旧 line 不再命中；

完成这些 standalone 检查后，再按 D5 接入 pipeline，并要求 pipeline memory、trap 和 differential regression 继续通过。
