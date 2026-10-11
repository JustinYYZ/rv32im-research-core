# OoO Core Synthesis and Timing Baseline

Measured on 2026-10-11 for rv32_ooo_core using unchanged functional RTL. This top includes the frontend, rename/scheduling, PRF, ROB, ALU, multiplier, divider, ordered LSU, and retirement interface. Both L1 caches and the simulation memory are excluded.

| Clock period | Target frequency | Worst setup slack | TNS | Setup result | Post-placement cell area |
|---|---:|---:|---:|---|---:|
| 10 ns | 100 MHz | +5.2091 ns | 0 ns | MET | 101,114 µm² |
| 5 ns | 200 MHz | +0.5010 ns | 0 ns | MET | 101,104 µm² |

Both mappings contain 50,304 standard cells and 98,060.368 µm² of mapped cell area before placement repair. The mapped netlists are identical; timing-driven placement/repair differs with target period. Placed cell area includes inserted buffers and resizing, not die area. 200 MHz is a tested passing target, not an identified maximum frequency.

## Constraints and implementation stage

- Library: Nangate45 typical, nominal 1.1 V / 25 °C.
- Clock uncertainty: 0.05 ns; ideal clock network.
- Data input/output delays: 0.5 ns; input driver INV_X1; output load 0.01 pF.
- Nangate45/OpenSTA capacitance unit is fF; the script verifies units and applies a load of 10 fF (0.01 pF).
- Die: 600 × 600 µm; core: (10,10) to (590,590); placement density: 0.30.
- Signal RC: metal3; clock RC: metal6.
- Flow: Yosys/slang elaboration, flattened synthesis, FF/ABC mapping, global/I/O placement, electrical repair, detailed placement, setup repair, and estimated placement parasitics.
- Stage: post-placement, pre-CTS/pre-route. No extracted routing parasitics, SRAM macro, OCV, IR-drop, or signoff multi-corner analysis.

Yosys hierarchy/check reported zero structural problems; synthesis explicitly rejects latch cells. OpenROAD check_setup and electrical-violation reports were empty after repair. These checks are not signoff.

## Critical path at 5 ns

Mapped startpoint _099301_ drives Q net _000003_[2]. Endpoint _099756_ corresponds to backend.divider.divider.quotient_q[9].

Data arrival is 4.4169 ns, including clock-to-Q and estimated wire delays. Required arrival is 4.9179 ns after uncertainty and setup time. Their difference is +0.5010 ns.

A divider endpoint does not mean iterative subtraction alone determines the whole path: upstream control/data selection and buffering are included. Complete paths are in paths.rpt for follow-up analysis. No functional timing optimization was added during closeout.

## Tool versions

- Yosys: 0.67+40, git 45ea2b8d6-dirty. OpenROAD: 08f67ee.

## Reproduce

~~~bash
make BUILD_DIR=/tmp/rv32-release CAD_ENV=/path/to/env.sh NANGATE45_DIR=/path/to/Nangate45 OOO_PERIOD=10 sta-ooo
make BUILD_DIR=/tmp/rv32-release CAD_ENV=/path/to/env.sh NANGATE45_DIR=/path/to/Nangate45 OOO_PERIOD=5 sta-ooo
~~~

Set NANGATE45_DIR to the directory containing Nangate45_typ.lib and the Nangate45 LEF files. Supply CAD_ENV only when an environment setup script is needed; otherwise put Yosys and OpenROAD on PATH.

Each BUILD_DIR/sta/<period>ns/ contains synth.ys, synth.log, the netlist, stat.json, OpenROAD log, constraints.sdc, paths.rpt, timing.rpt, electrical.rpt, check_setup.rpt, placed.odb, and result.json. Execution success and timing_pass are separate: negative slack is a measured failing target, not a tool failure.

The [benchmark IPC](ooo-l1-baseline.md) comes from cache-connected simulation. Combining it with this core-only target does not establish final hardware system throughput; cache SRAM and interface timing still require implementation.
