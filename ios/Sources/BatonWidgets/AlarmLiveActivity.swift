import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Lock Screen and Dynamic Island for a Baton alarm's snooze and a running timer
/// AlarmKit draws its own alert; a countdown or a paused
/// timer is drawn by the app's Live Activity for `AlarmAttributes<BatonAlarmMetadata>`.
@available(iOS 26.0, *)
struct AlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<BatonAlarmMetadata>.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.attributes.metadata?.isTimer == true ? "timer" : "alarm")
                    .font(.title2)
                    .foregroundStyle(context.attributes.tintColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.metadata?.label ?? "Baton")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let playing = context.attributes.metadata?.playing {
                        Label(playing, systemImage: context.attributes.metadata?.symbol ?? "music.note")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                AlarmCountdownText(state: context.state)
                    .font(.title2.monospacedDigit())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.metadata?.isTimer == true ? "timer" : "alarm")
                        .font(.title2)
                        .foregroundStyle(context.attributes.tintColor)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading) {
                        Text(context.attributes.metadata?.label ?? "Baton").font(.headline).lineLimit(1)
                        Text(context.attributes.metadata?.playing ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AlarmCountdownText(state: context.state).font(.title3.monospacedDigit())
                }
            } compactLeading: {
                Image(systemName: context.attributes.metadata?.isTimer == true ? "timer" : "alarm")
                    .foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                AlarmCountdownText(state: context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "alarm").foregroundStyle(context.attributes.tintColor)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct AlarmCountdownText: View {
    let state: AlarmPresentationState

    var body: some View {
        switch state.mode {
        case let .countdown(countdown):
            Text(timerInterval: Date.now ... max(Date.now, countdown.fireDate), countsDown: true)
        case let .paused(paused):
            Text(Duration.seconds(max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration)),
                 format: .time(pattern: .minuteSecond))
                .foregroundStyle(.secondary)
        case .alert:
            Image(systemName: "bell.and.waves.left.and.right")
        @unknown default:
            EmptyView()
        }
    }
}
