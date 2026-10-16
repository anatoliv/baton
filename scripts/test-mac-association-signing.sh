#!/usr/bin/env bash
# Synthetic only: no Apple, signing identity, native build, UI or audio.
# Prints the "N passed, 0 failed" line the gate's guard loop reads (scripts/test.sh).
set -uo pipefail
cd "$(dirname "$0")/.."
if out="$(python3 scripts/test_mac_association_signing.py 2>&1)"; then
  printf '%s\n' "$out"
  ran="$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9][0-9]*\) tests\{0,1\} in .*/\1/p' | tail -1)"
  echo "${ran:-0} passed, 0 failed"
else
  printf '%s\n' "$out"
  exit 1
fi
