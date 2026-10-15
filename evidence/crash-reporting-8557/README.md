# TBX-8557 Settings acceptance, 2026-10-02

The original implementation is merged in private PR147 (`29ade70a`); its tree is
identical to the completion branch's `adef17bf` baseline. These fixtures close the
remaining actual Settings acceptance gap without changing release configuration.

Final targeted results, read from finalized xcresult summaries:

- macOS: three actual Settings checks passed, zero failed/skipped.
- iOS: the same three checks passed, zero failed/skipped.
- Real SDK parser rejection and a real SDK cache-directory startup failure both
  show the unavailable message. Explicit off/on retry clears that message.
- The unconfigured build cannot enable reporting.

The PNGs are unmodified Settings captures. Each uses a separate DEBUG app identity,
registered throwaway preference suite, disposable file/cache storage and loopback
DSN. The SDK and production result-based startup decision are real. Only fixture
configuration and the disposable cache obstruction are provided by the harness.
The rejected fixture deliberately reaches the SDK parser; ordinary artifact
validation rejects that malformed shape earlier.

Run `scripts/test-crash-reporting-acceptance.sh mac` or
`scripts/test-crash-reporting-acceptance.sh ios <dedicated-simulator-UDID>` from
this isolated checkout. Result bundle locations are saved alongside their summaries.

The shared gate ran once: iPhone244/244, parked Watch build, native gateway109
passed. Mac2386 tests yielded2371 passed,14 skipped, and one harness guard failure:
`ThrowawayDefaultsTests/testNoTestMintsItsOwnUUIDSuite`. The fixture initially
minted its own suite. Both UI tests now use `ThrowawayDefaults.name("8557")`, and
that exact guard was rerun and passed1/1. Both final actual UI checks compiled and
ran after this correction. The corrected source lint harness passed59/59; shell
syntax and `git diff --check` passed. The unrelated full suite was not rerun.

All14 Mac skips are existing live provider/transcription/audio/discovery checks.
The Linux gateway stage had no configured reachable Docker host, and App Store
metadata had no ASC credentials. Neither verifies this app-only reporter fixture.
No delivery or production-release claim is made.

The final iOS tests finished in83 seconds, then Xcode waited in the known
`simctl diagnose --timeout600` collector. Only that post-test diagnostic
child was stopped. Xcode exited0 and finalized a Passed result with3 passed and0
failed/skipped; no test or runner was interrupted. Mac initially needed hardened
runtime disabled for its disposable ad-hoc runner, and the switch test now resolves
its real child/control hierarchy after scrolling instead of clicking a stale AX
wrapper. Production signing and user storage remain unchanged.
