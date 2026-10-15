#!/bin/bash
# Attach to an existing isolated synthetic Mac probe. Never launches or clicks an app.
# Usage: scripts/probe-share-e2e.sh mode-0600-fixture.json [temporary-evidence-dir] [--validate-only]
set -euo pipefail
PROBE_SHARE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${PROBE_SHARE_PYTHON:-python3}" "$PROBE_SHARE_SCRIPT_DIR/probe-share-e2e.py" "$@"
