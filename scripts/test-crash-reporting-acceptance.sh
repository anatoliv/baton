#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "${1:-}" in
  mac) AREA=app; APP=Baton; DESTINATION='platform=macOS'; SIGNING=(CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO) ;;
  ios) AREA=ios; APP=BatonMobile; DESTINATION="platform=iOS Simulator,id=${2:?simulator UDID required}"; SIGNING=(CODE_SIGNING_ALLOWED=NO) ;;
  *) echo 'Usage: test-crash-reporting-acceptance.sh mac | ios <simulator-UDID>' >&2; exit 2 ;;
esac
cd "$ROOT/$AREA"
xcodegen generate
# Separate all apps and extensions from production identities. Generated files
# are ignored; regeneration restores the normal project after the run.
trap 'xcodegen generate >/dev/null' EXIT
python3 - "$APP" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]+'.xcodeproj/project.pbxproj')
s = p.read_text().replace('io.tonebox.baton', 'io.tonebox.baton.acceptance')
# Widget bundle IDs change with the app; tests use a dedicated simulator.
p.write_text(s)
PY
xcodebuild -project "$APP.xcodeproj" -scheme "${APP}CrashReportingAcceptance" \
  -destination "$DESTINATION" -derivedDataPath "${DERIVED_DATA_PATH:-/private/tmp/baton-tbx-8557-$1}" \
  -only-testing:"${APP}UITests/CrashReportingAcceptanceTests" \
  "${SIGNING[@]}" test
