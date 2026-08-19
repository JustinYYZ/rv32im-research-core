# RV32 L1 Cache 开发教程

本文档以 direct-mapped blocking I-cache 为主线，说明 L1 cache 的通用 geometry、refill 和 pipeline integration。Write-back D-cache 的 masked store、write-allocate、dirty eviction 和错误顺序见 [RV32 L1 D-cache 开发教程](rv32-dcache-development.md)。2-way associativity、64-byte line 和 unified L2 属于后续结构扩展。

## 1. 开发目标和边界

最终 L1 目标配置为：

| 项目 | L1 I-cache | L1 D-cache |
|---|---:|---:|
| 容量 | 32 KiB | 32 KiB |
| 最终 associativity | 2-way | 2-way |
| 最终 line size | 64 byte | 64 byte |
| 写策略 | 只读 | Write-back、write-allocate |
| 第一版 miss handling | Blocking | Blocking |

Direct-mapped baseline 的 I-cache 和 D-cache 都使用32 KiB 容量和32-byte line。它们是后续 PPA、miss rate 和 associativity 实验的基线，不是临时代码；容量与 line size 均通过 parameter 表达。

当前第一版暂不包含：

- 多个同时在途的 miss；
- MSHR；
- prefetcher；
- coherence；
- virtual address translation；
- ECC；
- 真实 SRAM macro 实例。

## 2. Cache 在现有系统中的位置

加入 I-cache 前：

```text
Pipeline instruction port → rv32_simple_memory
```

加入后：

```text
Pipeline instruction port → rv32_icache → backing memory
```

CPU 侧继续使用原来的单请求 blocking protocol。Pipeline 不知道一次 response 来自 cache hit 还是 refill，只会在没有 response 时等待。

I-cache CPU 侧信号：

| 信号 | 方向 | 含义 |
|---|---|---|
| `cpu_req_valid_i` | CPU → Cache | CPU 提供一个取指地址 |
| `cpu_req_ready_o` | Cache → CPU | Cache 本周期能够接受请求 |
| `cpu_req_addr_i` | CPU → Cache | 32-bit byte address |
| `cpu_resp_valid_o` | Cache → CPU | 取指结果在本周期有效 |
| `cpu_resp_data_o` | Cache → CPU | 返回的32-bit instruction |
| `cpu_resp_error_o` | Cache → CPU | 下级访问发生 access fault |

Memory 侧同样采用 request/response handshake，但每次只读一个32-bit word。32-byte line miss 因此需要8次下级读取。

## 3. 第一版 Cache Geometry

默认参数：

```text
ADDR_WIDTH  = 32
CACHE_BYTES = 32 × 1024 = 32768
LINE_BYTES  = 32
WORD_BYTES  = 4
```

由此得到：

```text
WORDS_PER_LINE = LINE_BYTES / WORD_BYTES = 8
SET_COUNT      = CACHE_BYTES / LINE_BYTES = 1024
OFFSET_BITS    = log2(LINE_BYTES) = 5
INDEX_BITS     = log2(SET_COUNT) = 10
WORD_INDEX_BITS= log2(WORDS_PER_LINE) = 3
TAG_BITS       = 32 - INDEX_BITS - OFFSET_BITS = 17
```

Direct-mapped 每个 set 只有一条 line，因此 line count 与 set count 相同。地址拆分为：

```text
31                    15 14             5 4              0
+-----------------------+----------------+----------------+
|       Tag[16:0]       |  Index[9:0]    |  Offset[4:0]   |
+-----------------------+----------------+----------------+
```

Offset 内部继续解释为：

```text
address[4:2]：32-byte line 中的第几个32-bit word
address[1:0]：word 中的 byte offset，正常取指必须为 2'b00
```

不要在 RTL 中直接写死 `[14:5]` 和 `[31:15]`。固定切片便于第一眼理解，但之后把 line size 改成64 byte 时会失效。RTL 应由 `$clog2` localparam 推导位宽。

## 4. C1：地址分解

实现时先完成地址分解并通过对应测试，再加入数组、hit path 和状态机。这样可以独立验证纯地址函数，避免把 geometry 错误与控制逻辑错误混在一起。

需要驱动五个内部信号：

```systemverilog
cpu_req_offset
cpu_req_index
cpu_req_word_index
cpu_req_tag
cpu_req_line_base
```

推荐使用 continuous assignment。伪代码关系如下：

```text
offset    = address最低OFFSET_BITS
index     = 从OFFSET_BITS开始的INDEX_BITS
wordIndex = 从bit 2开始的WORD_INDEX_BITS
tag       = address最高TAG_BITS
lineBase  = address低OFFSET_BITS清零
```

SystemVerilog 的 indexed part-select 可以避免写死位置：

```systemverilog
vector[base +: width]  // 从base向高位选择width位
vector[base -: width]  // 从base向低位选择width位
```

因此实现时可以从以下表达式推导，而不是照抄固定 bit number：

```text
address[OFFSET_BITS +: INDEX_BITS]
address[ADDR_WIDTH-1 -: TAG_BITS]
address[2 +: WORD_INDEX_BITS]
```

Line base 的定义是包含该地址的 cache line 首地址。例如：

```text
address   = 0x0000104c
line base = 0x00001040
```

因为32-byte line 的起始地址必须是32的整数倍，低5 bit全部清零。

## 5. T1：地址分解 Testbench

`tb/cache/rv32_icache_tb.sv` 中的 `check_address_fields()` 接收地址和五个期望值。第一版允许通过 `dut.cpu_req_*` 层次化引用检查内部组合信号；完成 cache 外部行为后，主要测试应只观察端口。

Task 应完成：

```text
cpu_req_addr = address
等待一个很短的组合稳定时间
逐个使用 !== 比较内部字段
错误时输出原地址、字段名、expected和actual
```

建议 directed cases：

| Address | Tag | Index | Offset | Word index | Line base |
|---:|---:|---:|---:|---:|---:|
| `0x00000000` | `0x00000` | `0x000` | `0x00` | `0` | `0x00000000` |
| `0x0000104c` | `0x00000` | `0x082` | `0x0c` | `3` | `0x00001040` |
| `0x0000904c` | `0x00001` | `0x082` | `0x0c` | `3` | `0x00009040` |
| `0x00007ffc` | `0x00000` | `0x3ff` | `0x1c` | `7` | `0x00007fe0` |

`0x104c` 和 `0x904c` 刻意具有相同 Index、Offset 和 Word index，但 Tag 不同。Conflict replacement 测试复用这对地址。

在只验证 C1/T1 时，可以先调用这四个 case；随后保留它们作为永久 geometry regression，再继续添加外部端口行为测试。

## 6. C2：数组和 Hit Path

Direct-mapped I-cache 需要三组存储：

```text
valid_array[SET_COUNT]
tag_array[SET_COUNT][TAG_BITS]
data_array[SET_COUNT][LINE_BITS]
```

默认容量下：

```text
valid：1024 bit
tag：  1024 × 17 bit
data： 1024 × 256 bit = 32 KiB
```

一次 lookup：

```text
使用index读取valid、stored tag和line data
                 ↓
hit = valid && stored_tag == request_tag
                 ↓
使用word index从line中选择32-bit instruction
```

不要使用八层 case 手工选择 word。可以用 variable indexed part-select，起始位置为 `word_index * 32`。

功能模型可以先使用 SystemVerilog unpacked array。最终 OpenROAD PPA 评估时，data array 应替换或映射到 SRAM macro；32 KiB data array 如果全部综合为 flip-flop，面积和功耗没有代表性。

## 7. C3：Blocking Miss Refill

Miss 时必须保存原请求信息，因为 CPU 地址可能在后续周期改变。至少需要：

```text
request address/tag/index/word index
refill line base
refill word counter
refill buffer
refill error flag
current state
```

状态流：

```text
IDLE
  ↓ 接受CPU请求
LOOKUP
  ├─ hit  → RESPONSE
  └─ miss → REFILL_REQUEST
                 ↓ request handshake
             REFILL_WAIT
                 ↓ response
       counter不是最后一个 → REFILL_REQUEST
       counter是最后一个   → 写array → RESPONSE
```

Lower request address 为：

```text
saved_line_base + refill_word_count * 4
```

`mem_req_valid_o && !mem_req_ready_i` 时，request address 和 valid 必须保持不变。每个 accepted request 只能对应一个 response，不能在等待 response 时重复发送同一个 word。

## 8. C4：Reset、Backpressure 和 Error

Reset 必须让所有 valid bit 变为0。Data 和 tag 不需要全部清零，因为 valid=0 时它们不会形成 hit。这样更接近真实 SRAM 使用方式，也减少无意义 reset logic。

如果任意 refill word 返回 `mem_resp_error_i=1`：

1. 记录该 miss 失败；
2. 不把失败 line 标为 valid；
3. 向 CPU 返回一次 `cpu_resp_valid_o=1` 和 `cpu_resp_error_o=1`；
4. 返回 IDLE，允许后续请求继续执行。

本实现采用第一个 error 后立即终止当前 refill：旧 line 不被破坏，失败 line 不会变为 valid，CPU 收到一次 error response。这样不会在已经确定失败后继续产生无用的下级访问。

## 9. C5：Pipeline Integration 和 Differential Checking

集成顶层 `rtl/core/rv32_pipeline_icache_top.sv` 将 pipeline instruction port 接到 I-cache CPU side，并将 I-cache memory side 暴露为 backing instruction-memory port。Data-memory 和 architectural commit ports 直接穿过 wrapper。

集成验证包括：

- 全部 pipeline directed regression；
- reference-vs-pipeline commit differential test；
- 带 cold miss 的有限总周期 timeout；
- 同一 cache line 内连续取指只产生一次8-word refill；
- 跨 line 的 JAL redirect 产生第二次 refill，且错误路径指令不提交；
- 下级 instruction request 计数。

Commit trace 必须保持完全一致。允许变化的是 cycle count 和 backing-memory request 数量。

当前 baseline 不在可综合 I-cache 中加入硬件性能计数器，以免影响 PPA。Testbench 统计 accepted backing-memory requests。需要进行性能研究时，可以增加以下可关闭计数器：

```text
access_count
hit_count
miss_count
refill_word_count
stall_cycle_count
```

永久关系：

```text
access_count = hit_count + miss_count
```

## 10. 从独立 Cache 到完整 L1

完整 L1 hierarchy 的扩展顺序为：

1. 分别验证 direct-mapped blocking I-cache 和 D-cache；
2. 将两个 L1 cache 接入 pipeline 的 instruction/data ports；
3. 增加 cache flush/invalidate；
4. 比较32-byte和64-byte line；
5. 增加2-way set associativity和 replacement state；
6. 设计 I/D cache 到 unified L2 的仲裁与 line-level protocol。

D-cache 比 I-cache 多出的主要逻辑不是地址分解，而是 store merge、dirty state、victim writeback 和异常/flush 顺序。

## 11. 构建与完成标准

只编译 I-cache testbench：

```bash
make CAD_ENV=/path/to/env.sh compile-icache
```

运行 I-cache 单元测试：

```bash
make CAD_ENV=/path/to/env.sh test-icache
```

只编译或运行 pipeline + I-cache 集成测试：

```bash
make CAD_ENV=/path/to/env.sh compile-pipeline-icache
make CAD_ENV=/path/to/env.sh test-pipeline-icache
```

只编译或运行 standalone D-cache regression：

```bash
make CAD_ENV=/path/to/env.sh compile-dcache
make CAD_ENV=/path/to/env.sh test-dcache
```

`test-icache`、`test-pipeline-icache` 和 `test-dcache` 都纳入总 `make test` 回归。

第一版 direct-mapped I-cache 完成标准：

- parameter geometry 计算正确；
- address split 测试通过；
- cold miss 产生恰好 `WORDS_PER_LINE` 个下级请求；
- refill 后同 line 访问命中且不访问下级 memory；
- 相同 Index、不同 Tag 正确替换；
- backpressure 下 request 稳定且不重复；
- refill error 不产生 valid line；
- reset 后旧 line 不再命中；
- pipeline 集成测试保持正确 commit 顺序，并验证跨 line redirect；
- 原有 pipeline regression 和 reference-vs-pipeline differential test 继续通过。
