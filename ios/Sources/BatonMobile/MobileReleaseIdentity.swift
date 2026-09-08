import Foundation

/// The source revision this build of Baton for iPhone was compiled from, and the one
/// place that decides whether a candidate string counts as one.
///
/// **Why this exists.** The live App Store build — version 1.0, build 1786816974,
/// uploaded 2026-08-15 — carries a marketing version and a build number and nothing
/// else. The build number is `date +%s` at upload time, so it is not derived from
/// source; the version string is shared by every commit that ever carried it; and a
/// git tag is a movable pointer somebody typed. So "which revision is the thing
/// buyers are running" has exactly one honest answer for that build, which is
/// unknown, and no change made here can retrofit an answer onto it.
///
/// What this does fix is every build after it. `ios/scripts/testflight.sh` passes
/// `BATON_SOURCE_COMMIT=$(git rev-parse HEAD)` to `xcodebuild`, `ios/project.yml`
/// maps it to the `BatonSourceCommit` Info.plist key, and
/// `ios/scripts/release-guard.sh` refuses to upload an archive whose baked value is
/// missing, empty, unexpanded, abbreviated, uppercase or non-hex. This type reads the
/// same key at runtime. `Shared/CrashReporting.swift` independently requires the
/// canonical value and folds it into the release name, so every admitted event and
/// its matching dSYM use one immutable source/build identity.
enum MobileReleaseIdentity {
    /// The Info.plist key `ios/project.yml` declares and `testflight.sh` fills in.
    static let infoKey = "BatonSourceCommit"

    /// The validated commit baked into this build, or `nil` when there isn't one.
    ///
    /// `nil` in Xcode and dev builds, and in every App Store build up to and
    /// including 1786816974.
    static var sourceCommit: String? {
        validatedCommit(Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
    }

    /// Accepts exactly 40 lowercase **ASCII** hex characters, and nothing else.
    ///
    /// ASCII is load-bearing rather than pedantic. The obvious spelling of this check
    /// is `allSatisfy(\.isHexDigit)` or `isNumber`, and both are Unicode-aware:
    /// `Character.isNumber` is true for the Arabic-Indic digits ٠-٩ and for a dozen
    /// other digit families, so the obvious check admits 40-character strings that
    /// git cannot emit and that compare unequal to every real object id. Comparing
    /// UTF-8 bytes against the two ASCII ranges is the whole rule, and a multi-byte
    /// digit fails the length test before it can reach the range test.
    ///
    /// Everything rejected here is a *false* identity rather than a partial one, and
    /// that is the asymmetry the strictness is for: a missing identity gets
    /// investigated, a wrong one gets believed. An unexpanded `$(BATON_SOURCE_COMMIT)`
    /// looks most like success because the key is present; an abbreviated hash gets
    /// more ambiguous as the repository grows; an uppercase spelling is a second name
    /// for one commit.
    static func validatedCommit(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(trimmed.utf8)
        guard bytes.count == 40 else { return nil }
        let isLowercaseASCIIHex: (UInt8) -> Bool = { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66)   // '0'-'9', 'a'-'f'
        }
        guard bytes.allSatisfy(isLowercaseASCIIHex) else { return nil }
        return trimmed
    }

}
