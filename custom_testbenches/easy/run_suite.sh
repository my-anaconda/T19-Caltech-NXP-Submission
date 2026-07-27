#!/bin/bash
# Runs every easy-tier custom testbench in this directory against one
# generated-RTL output directory, via a real iverilog compile + vvp
# simulation (not just elaboration). Mirrors custom_testbenches/hard/
# and custom_testbenches/medium/'s own run_suite.sh scripts.
#
# Unlike hard/medium, easy tier's own tb_top_skeleton.v needs -g2012 (not
# -g2005) to parse at all - a pre-existing property of the organizer's
# own skeleton file (confirmed during this session's earlier medium/hard
# work), carried over here since our testbenches follow the same AHB
# task style as that skeleton.
#
# Usage: run_suite.sh <path-to-generated-RTL-dir>
#   e.g. run_suite.sh /path/to/ICLAD26-NXP-Problems/result/<run_id>/easy
set -e
export PATH="/home/defyscience/local_tools/bin:$PATH"

RTL="$1"
if [ -z "$RTL" ] || [ ! -d "$RTL" ]; then
  echo "Usage: $0 <path-to-generated-RTL-dir>"
  exit 1
fi
TB="$(dirname "$0")"
WORK="${TMPDIR:-/tmp}/tb_easy_suite_$$"
mkdir -p "$WORK"

for tb in tb_easy_basic_rw tb_easy_uart_tx tb_easy_gpio_irq tb_easy_timer tb_easy_watchdog tb_easy_privilege tb_easy_irq_aggregator; do
  echo "=== $tb ==="
  iverilog -g2012 -o "$WORK/$tb.sim" -I "$TB" "$RTL"/*.v "$TB/$tb.v" > "$WORK/$tb.compile.log" 2>&1
  CEXIT=$?
  if [ "$CEXIT" -ne 0 ]; then
    echo "COMPILE FAILED (exit $CEXIT):"
    grep -v 'Padding\|Pruning' "$WORK/$tb.compile.log"
    continue
  fi
  vvp "$WORK/$tb.sim" 2>&1 | grep -E '^\[PASS\]|^\[FAIL\]|SCORE|TIMEOUT'
done
