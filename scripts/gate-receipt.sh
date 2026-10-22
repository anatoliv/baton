#!/bin/bash
#
# Gate receipts: run the full test gate once per commit and let both releases use the
# result.
#
#   gate-receipt.sh write REPO --clean 0|1 --mac TEXT --ios TEXT --gateway TEXT [--skips LIST]
#   gate-receipt.sh check REPO [--require-clean] [--needs STAGE,STAGE]
#
# The mechanism is the release kit's lib/gate-receipt.sh (rule: one gate per commit in
# ~/Projects/_method/docs/standards/release.md). This file gives it Baton's settings:
#   * the gate is scripts/test.sh, the toolchain is Xcode;
#   * the release checkouts are the paths prepare-release-checkouts.sh uses:
#     ${BATON_MAC_RELEASE_CHECKOUT:-/private/tmp/baton-rel} (mac-release) and
#     ${BATON_IOS_RELEASE_CHECKOUT:-/private/tmp/baton-release-tf} (ios-release);
#     BATON_GATE_RECEIPT_ANY_CHECKOUT=1 accepts a receipt from any other checkout;
#   * the ignored release configuration is the two Crashbox.local.xcconfig files, recorded
#     by presence and SHA-256 only;
#   * BATON_GATE_RECEIPT_ALLOW_SKIPS names skipped stages a release accepts anyway;
#   * receipts live in ${BATON_GATE_RECEIPT_DIR:-~/Library/Caches/Baton/gate-receipts}.
# scripts/test.sh writes one after a passing full run; scripts/publish.sh and
# ios/scripts/testflight.sh check before their gate and run it as before on any refusal.
set -euo pipefail

RK_GATE_ENV=BATON_GATE_RECEIPT
RK_GATE_DEFAULT_DIR="$HOME/Library/Caches/Baton/gate-receipts"
RK_GATE_SCRIPT=scripts/test.sh
RK_GATE_CONFIGS="app/Config/Crashbox.local.xcconfig ios/Config/Crashbox.local.xcconfig"
RK_GATE_RELEASE_CHECKOUTS="mac-release=${BATON_MAC_RELEASE_CHECKOUT:-/private/tmp/baton-rel} ios-release=${BATON_IOS_RELEASE_CHECKOUT:-/private/tmp/baton-release-tf}"
RK_GATE_COUNT_LABELS="mac=Mac iphone=iPhone gateway=gateway"

# shellcheck source=scripts/release-kit/lib/gate-receipt.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-kit/lib/gate-receipt.sh"

# Baton's original write options name the three count lines.
if [ "${1:-}" = write ]; then
  args=("$1" "${2:-}")
  shift 2 || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mac) args+=(--count "mac=$2"); shift 2 ;;
      --ios) args+=(--count "iphone=$2"); shift 2 ;;
      --gateway) args+=(--count "gateway=$2"); shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- "${args[@]}"
fi
rk_gate_receipt "$@"
