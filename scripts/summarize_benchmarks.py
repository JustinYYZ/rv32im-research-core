#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate a Markdown table from six externally verified runs."""

import argparse
import json
from pathlib import Path


PROGRAMS = ("coremark_im", "aes_sha", "compression", "fft", "image", "mergesort")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    runs = [json.loads((args.build_dir / "runs" / name / "result.json").read_text()) for name in PROGRAMS]
    for run in runs:
        if run["status"] != "PASS" or run["compared_commits"] != run["total_commits"] or run["scope"] != "roi":
            parser.error(f"unverified or incomplete benchmark: {run['program']}")
    if any(run["configuration"] != runs[0]["configuration"] for run in runs):
        parser.error("benchmark configurations differ")
    lines = ["# OoO + L1 benchmark baseline", "",
             "Measured on 2026-10-11 with the single-dispatch/single-issue core and split blocking L1 caches.",
             "All six programs passed offline Spike comparison from startup through the first magic halt.", "",
             "| Program | ROI cycles | ROI instructions | IPC | Full-program commits compared | Spike |", "|---|---:|---:|---:|---:|---|"]
    for run in runs:
        lines.append(f"| {run['program']} | {run['cycles']:,} | {run['instructions']:,} | {run['ipc']:.6f} | {run['compared_commits']:,} | PASS |")
    total = sum(run["compared_commits"] for run in runs)
    lines.extend(["", f"Total: **{total:,} retirement events** compared against Spike. This is workload verification, not exhaustive ISA certification.", "", "## Configuration", ""])
    for name, value in runs[0]["configuration"].items():
        lines.append(f"- {name}: {value}")
    lines.extend(["", "IPC excludes the start marker and includes the stop marker. Correctness comparison includes startup, ROI, post-ROI execution, and halt.",
                  "Measurements use the deterministic mapped memory model described above. Equal ELF inputs do not imply directly comparable IPC across different cache and memory configurations.",
                  "", "## Tool versions", "",
                  f"- Simulator: {runs[0]['simulator_version']}", f"- Reference: {runs[0]['spike_version']}", f"- Compiler: {runs[0]['compiler_version']}",
                  "- Functional RTL and the benchmark harness were unchanged throughout these runs."])
    lines.extend(["", "## Reproduce", "", "External workload ELF files remain local inputs and are not redistributed. BENCHMARK_ROOT contains the six RV32IM ELF files.", "",
                  "~~~bash", "make BUILD_DIR=/tmp/rv32-release test-benchmarks BENCHMARK_ROOT=/path/to/benchmarks SPIKE=/path/to/spike BENCH_ENGINE=verilator",
                  "make BUILD_DIR=/tmp/rv32-release summarize-benchmarks", "~~~", "",
                  "Use BENCH_ENGINE=icarus for the same testbench under Icarus. Both simulators matched on the 70-commit C smoke and 17-commit subword-memory program.",
                  "Each BUILD_DIR/runs/<program>/ contains traces, host logs, and result.json with commands, configuration, versions, and correctness status.",
                  "", "## Limits and future work", "",
                  "One outstanding fetch, ROB-head-only memory issue, and retirement-time branch recovery limit IPC.",
                  "L2, LSQ/forwarding, advanced prediction, online RVFI, and privileged execution are outside this version. Internal directed/differential tests cover synchronous traps.",
                  "External comparison checks architectural stores, not every cache writeback transaction.",
                  "Directed cache tests separately cover refill, masks, dirty eviction, backpressure, and errors.",
                  "See [Spike verification](../verification/rv32-spike-verification.md) and the [core-only timing result](ooo-core-timing.md).", ""])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines))
    print(f"Summary: {args.output}; {total} commits externally verified")


if __name__ == "__main__":
    main()
