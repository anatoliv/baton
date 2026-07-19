import SwiftUI

/// The in-app "banner" delivery for `speak_summary` (mode = "banner"): when an agent sends a
/// spoken summary that waits for confirmation, this shows the text with a Play button at the
/// bottom of the music content. Unlike `MusicToastOverlay` (display-only, auto-dismissing),
/// this is interactive and stays until the user plays or dismisses it.
private struct SpeechAlertOverlay: ViewModifier {
    @Environment(MusicModel.self) private var model

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let alert = model.speech.pendingAlert {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(.secondary)
                        Text(alert.text)
                            .font(.callout)
                            .lineLimit(2)
                            .frame(maxWidth: 320, alignment: .leading)
                        Button {
                            model.speech.confirmBanner()
                        } label: {
                            Label("Play", systemImage: "play.fill").font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            model.speech.dismissBanner()
                        } label: {
                            Image(systemName: "xmark").font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: model.speech.pendingAlert)
    }
}

extension View {
    /// Shows the in-app spoken-summary banner with a Play button (see `SpeechAlertOverlay`).
    func speechAlertBanner() -> some View { modifier(SpeechAlertOverlay()) }
}
