#!/bin/bash
# Runs every medium-tier custom testbench in this directory against one
# generated-RTL output directory, via a real iverilog compile + vvp
# simulation (not just elaboration). Mirrors custom_testbenches/hard/
# run_suite.sh, including the same noc_mesh instance-name auto-detect
# (Step 4's top-level generation doesn't always call it "u_noc_mesh"
# despite prompt guidance - see the hard-tier script for the full
# rationale).
#
# Usage: run_suite.sh <path-to-generated-RTL-dir>
#   e.g. run_suite.sh /path/to/ICLAD26-NXP-Problems/result/<run_id>/medium
set -e
export PATH="/home/defyscience/local_tools/bin:$PATH"

RTL="$1"
if [ -z "$RTL" ] || [ ! -d "$RTL" ]; then
  echo "Usage: $0 <path-to-generated-RTL-dir>"
  exit 1
fi
TB="$(dirname "$0")"
WORK="${TMPDIR:-/tmp}/tb_med_suite_$$"
mkdir -p "$WORK"

MESH_INST=$(grep -oE 'noc_mesh [A-Za-z_][A-Za-z0-9_]* \(' "$RTL/noc_aes_soc.v" | head -1 | awk '{print $2}')
if [ -z "$MESH_INST" ]; then
  echo "[WARN] Could not detect noc_mesh instance name in $RTL/noc_aes_soc.v - defaulting to u_noc_mesh"
  MESH_INST="u_noc_mesh"
fi
echo "[HARNESS] Detected noc_mesh instance name: $MESH_INST"

for tb in tb_medium_reset_sync tb_medium_noc_topology tb_medium_aes0_encrypt tb_medium_aes1_encrypt tb_medium_irq_agg tb_medium_sram_ni_idle tb_medium_noc_ni_basic tb_medium_noc_local_loop tb_medium_noc_ew_routing tb_medium_noc_ns_routing tb_medium_noc_2hop tb_medium_irq_id_order; do
  sed "s/u_noc_mesh/$MESH_INST/g" "$TB/$tb.v" > "$WORK/$tb.v"
  echo "=== $tb ==="
  iverilog -g2005 -o "$WORK/$tb.sim" -I "$TB" "$RTL"/*.v "$WORK/$tb.v" > "$WORK/$tb.compile.log" 2>&1
  CEXIT=$?
  if [ "$CEXIT" -ne 0 ]; then
    echo "COMPILE FAILED (exit $CEXIT):"
    grep -v 'noc_mesh.v.*warning\|Padding\|Pruning\|expects 32 bits' "$WORK/$tb.compile.log"
    continue
  fi
  vvp "$WORK/$tb.sim" 2>&1 | grep -E '^\[PASS\]|^\[FAIL\]|SCORE|TIMEOUT'
done
