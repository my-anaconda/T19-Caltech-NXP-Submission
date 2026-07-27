#!/bin/bash
# Runs every hard-tier custom testbench in this directory against one
# generated-RTL output directory, via a real iverilog compile + vvp
# simulation (not just elaboration).
#
# Usage: run_suite.sh <path-to-generated-RTL-dir>
#   e.g. run_suite.sh /path/to/ICLAD26-NXP-Problems/result/<run_id>/hard
#
# Auto-detects the top-level's own instance name for the "noc_mesh"
# module and substitutes it into a working copy of each testbench in
# place of the hardcoded "u_noc_mesh" placeholder used in the checked-in
# .v files. This exists because Step 4's LLM top-level generation picks
# its own instance name for the mesh wrapper, and despite explicit prompt
# guidance to always call it "u_noc_mesh", it has been observed choosing
# different names ("noc_mesh", "u_noc", ...) across regenerations - a
# cosmetic naming choice, not a functional bug, but one that would
# otherwise silently break every hierarchical-probe testbench that
# assumes a fixed name.
set -e
export PATH="/home/defyscience/local_tools/bin:$PATH"

RTL="$1"
if [ -z "$RTL" ] || [ ! -d "$RTL" ]; then
  echo "Usage: $0 <path-to-generated-RTL-dir>"
  exit 1
fi
TB="$(dirname "$0")"
WORK="${TMPDIR:-/tmp}/tb_suite_$$"
mkdir -p "$WORK"

MESH_INST=$(grep -oE 'noc_mesh [A-Za-z_][A-Za-z0-9_]* \(' "$RTL/crypto_soc.v" | head -1 | awk '{print $2}')
if [ -z "$MESH_INST" ]; then
  echo "[WARN] Could not detect noc_mesh instance name in $RTL/crypto_soc.v - defaulting to u_noc_mesh"
  MESH_INST="u_noc_mesh"
fi
echo "[HARNESS] Detected noc_mesh instance name: $MESH_INST"

for tb in tb_hard_reset_sync tb_hard_noc_local tb_hard_noc_routing tb_hard_aes_basic tb_hard_dma_basic tb_hard_apb_periph tb_hard_irq_crypto tb_hard_perf_counter tb_hard_irq_periph tb_hard_soc_cfg_regs tb_hard_mailbox; do
  sed "s/u_noc_mesh/$MESH_INST/g" "$TB/$tb.v" > "$WORK/$tb.v"
  echo "=== $tb ==="
  iverilog -g2005 -o "$WORK/$tb.sim" -I "$TB" "$RTL"/*.v "$WORK/$tb.v" > "$WORK/$tb.compile.log" 2>&1
  CEXIT=$?
  if [ "$CEXIT" -ne 0 ]; then
    echo "COMPILE FAILED (exit $CEXIT):"
    grep -v 'noc_mesh.v.*warning\|Padding\|Pruning' "$WORK/$tb.compile.log"
    continue
  fi
  vvp "$WORK/$tb.sim" 2>&1 | grep -E '^\[PASS\]|^\[FAIL\]|SCORE|TIMEOUT'
done
