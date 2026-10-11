# SPDX-License-Identifier: Apache-2.0
# Core-only Nangate45 typical baseline; cache arrays and the testbench are excluded.
set platform $::env(OOO_PLATFORM)
set output $::env(OOO_OUTPUT)
set period $::env(OOO_PERIOD)

read_lef "$platform/Nangate45_tech.lef"
read_lef "$platform/Nangate45_stdcell.lef"
read_liberty "$platform/Nangate45_typ.lib"
read_verilog "$output/rv32_ooo_core.v"
link_design rv32_ooo_core
set_units -time ns -capacitance fF

create_clock -name core_clk -period $period [get_ports clk_i]
set_clock_uncertainty 0.05 [get_clocks core_clk]
set data_inputs [get_ports -filter {direction == input && name != clk_i}]
set data_outputs [get_ports -filter {direction == output}]
set_input_delay 0.5 -clock core_clk $data_inputs
set_output_delay 0.5 -clock core_clk $data_outputs
set_driving_cell -lib_cell INV_X1 $data_inputs
# Nangate45 capacitance is in fF: 10 fF is 0.01 pF.
set_load 10 $data_outputs

initialize_floorplan -site FreePDK45_38x28_10R_NP_162NW_34O -die_area {0 0 600 600} -core_area {10 10 590 590}
source "$platform/Nangate45.tracks"
source "$platform/Nangate45.rc"
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal6
global_placement -density 0.30 -skip_io
place_pins -hor_layers metal3 -ver_layers metal2
global_placement -timing_driven -density 0.30
estimate_parasitics -placement
set_dont_use {CLKBUF_* AOI211_X1 OAI211_X1}
repair_design -slew_margin 10 -cap_margin 10
set_placement_padding -global -left 1 -right 1
detailed_placement
estimate_parasitics -placement
repair_timing -setup -setup_margin 0.0 -repair_tns 100 -max_utilization 60
detailed_placement
estimate_parasitics -placement

report_checks -path_delay max -format full_clock_expanded -fields {slew cap input_pin net fanout} -digits 4 -group_path_count 5 > "$output/paths.rpt"
report_worst_slack -max -digits 4 > "$output/timing.rpt"
report_tns -digits 4 >> "$output/timing.rpt"
report_check_types -max_slew -max_capacitance -max_fanout -violators > "$output/electrical.rpt"
check_setup -verbose > "$output/check_setup.rpt"
report_design_area
write_sdc "$output/constraints.sdc"
write_db "$output/placed.odb"
