import AppIntents
import Foundation
#if canImport(AlarmKit)
import AlarmKit
#endif

/// The buttons on an AlarmKit alert, in a file both the app and the widget extension compile
/// (TBX-11171, specs/alarm-and-timer.md). The widget's Live Activity has to name the metadata
/// type; only the app can do anything when a button is pressed, so the work goes through
/// `AlarmIntentHandler`, which the app fills in at launch, the same way as `TransportIntentHandler`.
@MainActor
public enum AlarmIntentHandler {
    public static var play: ((UUID) -> Void)?
    public static var stop: ((UUID) -> Void)?
    /// A Play that arrived before the app had wired the handler (a cold launch from the alert).
    public static var pendingPlay: UUID?

    static func play(_ raw: String) {
        guard let id = UUID(uuidString: raw) else { return }
        if let play { play(id) } else { pendingPlay = id }
    }

    static func stop(_ raw: String) {
        guard let id = UUID(uuidString: raw) else { return }
        stop?(id)
    }
}

/// The alert's Play button: opens Baton and plays what the alarm or timer was set to play.
@available(iOS 26.0, *)
public struct PlayBatonAlarmIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Play Alarm"
    public static let description = IntentDescription("Open Baton and play what this alarm was set to play.")
    public static let supportedModes: IntentModes = .foreground(.immediate)
    public static let isDiscoverable = false

    @Parameter(title: "Alarm")
    public var alarmID: String

    public init() {}
    public init(alarmID: UUID) { self.alarmID = alarmID.uuidString }

    @MainActor
    public func perform() async throws -> some IntentResult {
        AlarmIntentHandler.play(alarmID)
        return .result()
    }
}

/// The alert's Stop: tells Baton the alarm was answered, so opening Baton later starts nothing.
@available(iOS 26.0, *)
public struct StopBatonAlarmIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Stop Alarm"
    public static let description = IntentDescription("Stop a Baton alarm without playing it.")
    public static let supportedModes: IntentModes = .background
    public static let isDiscoverable = false

    @Parameter(title: "Alarm")
    public var alarmID: String

    public init() {}
    public init(alarmID: UUID) { self.alarmID = alarmID.uuidString }

    @MainActor
    public func perform() async throws -> some IntentResult {
        AlarmIntentHandler.stop(alarmID)
        return .result()
    }
}

#if canImport(AlarmKit)
/// What the Lock Screen and Dynamic Island show for a Baton alarm or timer.
@available(iOS 26.0, *)
public struct BatonAlarmMetadata: AlarmMetadata {
    /// The alarm's own id in Baton's store (a snooze has a different AlarmKit id).
    public var storeID: String
    public var label: String
    /// What plays, as the alarm's "Play" row says it.
    public var playing: String
    public var symbol: String
    public var isTimer: Bool

    public init(storeID: UUID, label: String, playing: String, symbol: String, isTimer: Bool) {
        self.storeID = storeID.uuidString
        self.label = label
        self.playing = playing
        self.symbol = symbol
        self.isTimer = isTimer
    }
}
#endif
