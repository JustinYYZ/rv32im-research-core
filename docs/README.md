# Documentation Index

Public project documentation is grouped by purpose so that architecture
descriptions, verification references, and reproducible results can evolve
independently.

## Design

- [Five-stage pipeline](design/rv32-pipeline-core.md): implemented stage
  payloads, hazard handling, forwarding, blocking operations, precise traps,
  and regression scope.
- [Out-of-order core](design/rv32-ooo-core.md): integrated integer/control-flow,
  RV32M, and ordered-memory paths, shared completion arbitration, rename/retirement invariants,
  recovery, precise traps, regression commands, and remaining integration stages.

## Verification

- [Reference-core verification](verification/rv32-reference-core-verification.md):
  testbench responsibilities, trap cases, commit invariants, and regression
  commands.
- [Core differential verification](verification/rv32-core-differential-verification.md):
  commit-event comparison, independent memories, scoreboard behavior, and
  extension strategy.

## Results

Generated reports belong under `results/generated/` and are excluded from Git.
Curated, reproducible summaries may be added directly under `docs/results/`.

---

# 文档索引

公开项目文档按照用途分类，使架构说明、验证资料和可复现实验结果能够独立维护。

## 设计说明

- [五级流水线](design/rv32-pipeline-core.md)：当前实现的 stage payload、hazard、
  forwarding、blocking operation、精确异常和回归范围。
- [乱序执行核心](design/rv32-ooo-core.md)：已接通的整数/控制流、RV32M 与顺序访存路径、
  共享 completion 仲裁、rename/retirement invariant、恢复、精确异常、回归命令和后续集成边界。

## 验证资料

- [Reference core 验证](verification/rv32-reference-core-verification.md)：
  testbench 分工、trap case、commit 不变量和回归命令。
- [Core 差分验证](verification/rv32-core-differential-verification.md)：commit event
  比较、独立 memory、scoreboard 行为和扩展方法。

## 实验结果

自动生成的报告放在 `results/generated/`，不提交到 Git。经过整理并可以复现的
实验摘要可以放在 `docs/results/`。
