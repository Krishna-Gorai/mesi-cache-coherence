# -----------------------------------------------------------------------------
# synth_ooc.tcl -- out-of-context synthesis of the 4-core coherent system for
# PPA (area / timing / power) on the ZCU104 (Zynq UltraScale+ xczu7ev).
#
# The verification-only bus_monitor is NOT read here; it lives behind a
# synthesis translate_off guard in coherent_system and never synthesizes.
#
# Run from the project root:
#   vivado -mode batch -source sim\synth_ooc.tcl
# Reports land in reports_synth\.
# -----------------------------------------------------------------------------
set part   xczu7ev-ffvc1156-2-e
set top    coherence_unit
set period 5.0

set root [file normalize [file dirname [info script]]/..]
set rpt  $root/reports_synth
file mkdir $rpt

# The coherence unit only (caches + snoop bus); the behavioral main_memory model
# stands in for off-unit RAM and is left at the boundary as a top-level port.
read_verilog -sv [list \
  $root/rtl/mesi_pkg.sv \
  $root/rtl/l1_cache.sv \
  $root/rtl/snoop_bus.sv \
  $root/rtl/coherence_unit.sv ]

# 4-core configuration.
synth_design -top $top -part $part -mode out_of_context -generic N=4

# Single system clock; constrain it so the timing report is meaningful.
create_clock -name clk -period $period [get_ports clk]

report_utilization        -hierarchical -file $rpt/utilization.rpt
report_timing_summary     -delay_type max -max_paths 10 -file $rpt/timing_summary.rpt
report_timing -sort_by group -max_paths 5 -path_type full -file $rpt/timing_paths.rpt
report_power              -file $rpt/power.rpt
write_checkpoint -force   $rpt/${top}_synth.dcp

puts "==== synth done: reports in $rpt ===="
