#!/bin/bash
# Prepare CSV input for Lab 2 pipeline
# Extracts 4 columns from Н_ВЕДОМОСТИ, pre-filters matching rows, adds sentinel
# Usage: ./prepare_data.sh [num_rows]
#   num_rows: limit output rows (default: all matching ~1171)

set -e
cd "$(dirname "$0")/.."

NUM_ROWS=${1:-99999}
CSV="dump_db/_Н_ВЕДОМОСТИ__202603141056_postgres_2.csv"
OUT="/tmp/test_vedmosti.csv"

echo "Extracting from $CSV..."
(
  echo "ID;CHELVK;DATA;TV"
  awk -F';' 'NR>1 && $2+0 > 153285 && $8+0 >= 2 { print $1";"$2";"$6";"$8 }' "$CSV" | head -$NUM_ROWS
  echo "0"
) > "$OUT"

LINES=$(wc -l < "$OUT")
echo "Written $OUT: $LINES lines ($(($LINES - 2)) data rows)"
