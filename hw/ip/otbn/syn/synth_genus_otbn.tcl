# Copyright lowRISC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

############################################
#
# TCL script for Synthesis with Genus
#
############################################
# Required if SRAM blocks are synthesized
set_db hdl_max_memory_address_range 65536

############################################
# Read Sources
############################################
source ${READ_SOURCES}.tcl

############################################
# Elaborate Design
############################################

# Effort: none, low, medium, high, express
set_db syn_global_effort low

elaborate otbn

check_design -unresolved otbn 
check_design -combo_loops otbn
check_design -multiple_driver otbn

############################################
# Set Timing and Design Constraints
############################################

read_sdc ${REPO_TOP}/hw/ip/otbn/syn/otbn.sdc

############################################
# Apply Optimization Directives
############################################

puts "Apply Optimization Directive"

############################################
# Synthesize Design
############################################

#SYN GENERIC - Prepare Logic
syn_gen
#SYN MAP - Map Design for Target Technology
syn_map
#SYN OPT - Optimize final results
syn_opt



############################################
# Write Output Files
############################################

# REPORTS
report timing > ../reports/otbn_timing.rpt
report area > ../reports/otbn_area.rpt
report power > ../reports/otbn_power.rpt


quit
