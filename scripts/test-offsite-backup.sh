#!/bin/bash
# The guard loop in scripts/test.sh looks for scripts/<guard>.sh; the suite itself lives beside
# the scripts it tests, in gateway/deploy/backup/.
exec "$(dirname "$0")/../gateway/deploy/backup/test-offsite-backup.sh" "$@"
