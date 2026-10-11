#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Map the unchanged OoO core and optionally run post-placement OpenROAD STA."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from run_spike_diff import version


ROOT = Path(__file__).resolve().parents[1]


def quote(path):
    return '"' + str(path).replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--platform", type=Path, required=True)
    parser.add_argument("--yosys", default="yosys")
    parser.add_argument("--openroad", default="openroad")
    parser.add_argument("--period", type=float, default=10.0, help="ns")
    parser.add_argument("--sta", action="store_true")
    parser.add_argument("--sources", nargs="+", required=True)
    args = parser.parse_args()
    if args.period <= 0:
        parser.error("period must be positive")
    platform = args.platform.resolve()
    liberty = platform / "Nangate45_typ.lib"
    if not liberty.is_file():
        parser.error(f"missing library: {liberty}")
    output = args.build_dir.resolve() / "sta" / f"{args.period:g}ns"
    output.mkdir(parents=True, exist_ok=True)
    netlist = output / "rv32_ooo_core.v"
    stats = output / "stat.json"
    script = output / "synth.ys"
    commands = [
        "read_slang --top rv32_ooo_core " + " ".join(args.sources),
        "hierarchy -check -top rv32_ooo_core",
        "synth -top rv32_ooo_core -flatten",
        "select -assert-none t:$dlatch t:$adlatch t:$_DLATCH_*",
        "check -assert",
        f"dfflibmap -liberty {quote(liberty)}",
        f"abc -D {args.period * 1000:g} -liberty {quote(liberty)}",
        "clean",
        f"read_liberty -lib {quote(liberty)}",
        "check -assert",
        f"tee -o {quote(stats)} stat -json -liberty {quote(liberty)}",
        f"write_verilog -noattr -noexpr {quote(netlist)}",
    ]
    script.write_text("\n".join(commands) + "\n")
    result = {"top": "rv32_ooo_core", "clock_period_ns": args.period, "clock_uncertainty_ns": 0.05,
              "io_delay_ns": 0.5, "input_driver": "INV_X1", "output_load_pf": 0.01, "library": str(liberty),
              "cache_included": False,
              "stage": "mapped synthesis", "yosys_version": version([args.yosys, "-V"]), "status": "FAIL"}
    try:
        with (output / "synth.log").open("w") as log:
            subprocess.run([args.yosys, "-m", "slang", "-s", str(script)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        report = json.loads(stats.read_text())
        design = report.get("design", report["modules"]["\\rv32_ooo_core"])
        result.update(cell_area_um2=design.get("area"), cells=design.get("num_cells"))
        if re.search(r"\$_D?LATCH", netlist.read_text()):
            raise ValueError("mapped netlist contains an unexpected latch")
        if args.sta:
            environment = dict(os.environ, OOO_PLATFORM=str(platform), OOO_OUTPUT=str(output), OOO_PERIOD=str(args.period))
            result["openroad_version"] = version([args.openroad, "-version"])
            with (output / "openroad.log").open("w") as log:
                subprocess.run([args.openroad, "-exit", "-no_init", str(ROOT / "scripts/sta_ooo.tcl")], cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
            timing = (output / "timing.rpt").read_text()
            slack = re.search(r"worst slack(?: max)?\s+(-?[\d.]+)", timing)
            if slack is None:
                raise ValueError("OpenROAD did not report worst setup slack")
            result.update(stage="post-placement, estimated parasitics, ideal clock, pre-CTS/pre-route", wns_ns=float(slack[1]))
            result["timing_pass"] = result["wns_ns"] >= 0
            result["frequency_mhz"] = 1000 / args.period
        result["status"] = "PASS"
        print(f"PASS: {result['stage']}; reports: {output}")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        result["error"] = str(error)
        print(f"FAIL: {error}; inspect {output}", file=sys.stderr)
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
