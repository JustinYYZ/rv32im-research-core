#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build, run, and externally verify a bare-metal RV32IM program."""

import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from compare_commit_trace import compare_traces


ROOT = Path(__file__).resolve().parents[1]


def run(command, log, timeout):
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Stop the make/simulator process tree, not only its parent.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
        if status != 0:
            raise subprocess.CalledProcessError(status, command)


def version(command):
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
    except OSError as error:
        return f"unavailable: {error}"
    return result.stdout.splitlines()[0] if result.stdout.splitlines() else "unknown"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("program", type=Path)
    parser.add_argument("--build-dir", type=Path, default=Path("/tmp/rv32-closeout"))
    parser.add_argument("--spike", default=os.environ.get("SPIKE", "spike"))
    parser.add_argument("--iverilog", default=os.environ.get("IVERILOG", "iverilog"))
    parser.add_argument("--vvp", default=os.environ.get("VVP", "vvp"))
    parser.add_argument("--engine", choices=("icarus", "verilator"), default="icarus")
    parser.add_argument("--verilator", default=os.environ.get("VERILATOR", "verilator"))
    parser.add_argument("--max-cycles", type=int, default=20000000)
    parser.add_argument("--timeout", type=int, default=3600)
    args = parser.parse_args()
    args.build_dir = args.build_dir.resolve()
    args.program = args.program.resolve()
    if not args.program.is_file():
        parser.error(f"program does not exist: {args.program}")
    work = args.build_dir / "runs" / args.program.stem
    work.mkdir(parents=True, exist_ok=True)
    trace = work / "rtl.csv"
    spike_log = work / "spike.log"
    elf = args.build_dir / "sw" / args.program.stem / "program.elf"
    result_path = work / "result.json"
    result = {"program": args.program.name, "status": "FAIL"}
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True, check=False)
    result.update(dirty_worktree=bool(dirty.stdout.strip()), spike_version=version([args.spike, "--help"]),
                  compiler_version=version(["riscv64-unknown-elf-gcc", "--version"]),
                  simulator_version=version([args.iverilog, "-V"] if args.engine == "icarus" else [args.verilator, "--version"]))
    result["configuration"] = {"reset_pc": "0xaaaaa000", "isa": "rv32im", "icache_bytes": 32768, "dcache_bytes": 32768, "line_bytes": 32,
                               "cache": "direct-mapped, blocking; D-cache write-back/write-allocate", "refill_bits": 32,
                               "memory": "separate I/D ports; one pending request per port; response one rising edge after acceptance",
                               "roi": "exclude start marker, include stop marker", "max_cycles": args.max_cycles}
    start = time.monotonic()
    try:
        command = ["make", f"BUILD_DIR={args.build_dir}", f"PROGRAM={args.program}", f"IVERILOG={args.iverilog}", f"VVP={args.vvp}",
                   f"VERILATOR={args.verilator}", f"BENCHMARK_ARGS=+CHECK_SIGNATURE=0 +MAX_CYCLES={args.max_cycles} +COMMIT_TRACE={trace}",
                   "test-ooo-benchmark" if args.engine == "icarus" else "test-ooo-benchmark-verilator"]
        print(f"RUN: {args.program.name}", flush=True)
        result["rtl_command"] = command
        run(command, work / "rtl.log", args.timeout)
        rtl_text = (work / "rtl.log").read_text()
        commits = re.search(r"total_commits:\s*(\d+)", rtl_text)
        metrics = re.search(r"BENCH_RESULT scope=(\w+) cycles=(\d+) instructions=(\d+) ipc=([0-9.]+)", rtl_text)
        if commits is None or metrics is None or "rv32_ooo_benchmark_tb: PASS" not in rtl_text:
            raise ValueError("RTL log is missing a normal halt or benchmark metrics")
        result.update(total_commits=int(commits[1]), scope=metrics[1], cycles=int(metrics[2]), instructions=int(metrics[3]), ipc=float(metrics[4]))
        # A small instruction margin lets the comparator independently identify Spike's first halt.
        command = [args.spike, "--isa=rv32im", "--pc=0xaaaaa000", "--log-commits", f"--log={spike_log}", f"--instructions={result['total_commits'] + 16}", str(elf)]
        result["spike_command"] = command
        run(command, work / "spike-host.log", args.timeout)
        compared = compare_traces(trace, spike_log)
        if compared is None or compared != result["total_commits"]:
            raise ValueError("architectural retirement mismatch")
        result.update(status="PASS", compared_commits=compared)
        print(f"PASS: {args.program.name}, {compared} commits, IPC={result['ipc']:.6f}", flush=True)
    except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        result["error"] = str(error)
        print(f"FAIL: {args.program.name}: {error}; logs: {work}", file=sys.stderr, flush=True)
    finally:
        result["wall_seconds"] = round(time.monotonic() - start, 3)
        result_path.write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
