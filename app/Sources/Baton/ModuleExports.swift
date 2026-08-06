/// App-wide re-exports of the shared-core packages, so every file in the app target sees
/// the Subsonic domain types and client without a per-file import. This continues the
/// convention that lived in NavidromeModels.swift before it moved into BatonSubsonicKit
/// (see docs/plan-ios-app.md, Phase 1) — the iOS app target will carry the same two lines.
@_exported import BatonAgentKit
@_exported import BatonPlaybackKit
@_exported import BatonSubsonicKit
@_exported import BatonSubsonicModels
