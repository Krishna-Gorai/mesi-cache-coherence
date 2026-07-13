# -----------------------------------------------------------------------------
# create_vivado_project.tcl -- build a Vivado project for the MESI coherence
# unit so the design can be explored in the GUI (RTL schematic) and simulated
# with the waveform viewer.
#
#   vivado -mode batch -source sim\create_vivado_project.tcl
#
# then open  vivado_prj\mesi_coherence.xpr  in the Vivado GUI. The generated
# project directory is disposable (git-ignored); re-run this script to rebuild.
# -----------------------------------------------------------------------------
set origin   [file normalize [file dirname [info script]]/..]
set prj_dir  $origin/vivado_prj
set prj_name mesi_coherence
set part     xczu7ev-ffvc1156-2-e

file delete -force $prj_dir
create_project $prj_name $prj_dir -part $part -force

# ---- Design sources ----
add_files -norecurse -fileset sources_1 [list \
  $origin/rtl/mesi_pkg.sv \
  $origin/rtl/main_memory.sv \
  $origin/rtl/l1_cache.sv \
  $origin/rtl/snoop_bus.sv \
  $origin/rtl/coherent_system.sv \
  $origin/rtl/coherence_unit.sv \
  $origin/rtl/bus_monitor.sv ]
set_property file_type {SystemVerilog} [get_files *.sv]

# The bus monitor is a verification-only observer (it sits behind a synthesis
# translate_off guard in coherent_system): compile it for simulation only.
set_property used_in_synthesis false [get_files bus_monitor.sv]

# Full multicore system as the design top, so the RTL schematic shows all four
# caches, the snoop bus and memory. (coherence_unit is the leaner synth top.)
set_property top coherent_system [get_filesets sources_1]

# ---- Simulation sources ----
add_files -norecurse -fileset sim_1 [list \
  $origin/tb/tb_coherent_system.sv \
  $origin/tb/tb_race.sv \
  $origin/tb/tb_stress.sv \
  $origin/tb/tb_trace.sv ]

# Default to the short, illustrative lifecycle trace; switch the simulation top
# in the GUI (Sources > Simulation Sources, right-click > Set as Top) to run
# tb_race, tb_stress (4-core randomized stress + monitor) or tb_coherent_system.
set_property top tb_trace [get_filesets sim_1]

# mesi_pkg has no `timescale of its own; give xsim an explicit one so
# elaboration does not fail with "module has a timescale but ... doesn't".
set_property -name {xsim.elaborate.xelab.more_options} \
  -value {-timescale 1ns/1ps} -objects [get_filesets sim_1]
# Run each simulation to completion ($finish) instead of a fixed 1 us window.
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "==== project created: $prj_dir/$prj_name.xpr ===="
