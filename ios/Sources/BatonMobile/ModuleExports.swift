/// App-wide re-exports of the shared-core packages — the same two lines the Mac app's
/// ModuleExports.swift carries, so no file in this target needs a per-file import.
@_exported import BatonAgentKit
@_exported import BatonPlaybackKit
@_exported import BatonSubsonicKit
@_exported import BatonSubsonicModels

/// The queue's provenance ("Album · Blue Train", "Radio · …") is nested inside the
/// engine. It appears in nearly every play call on the phone, so it gets a short name
/// here rather than a qualified one at forty call sites.
typealias QueueSource = StreamingPlaybackController.QueueSource
