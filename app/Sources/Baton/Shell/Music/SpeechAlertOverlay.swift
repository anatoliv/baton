import SwiftUI

/// The in-app **banner** for `mode = "banner"`: a spoken summary waiting for the user to press
/// Play, pinned to the bottom of the music content. Unlike `MusicToastOverlay` (display-only,
/// auto-dismissing), it's interactive.
///
/// The live **speaking HUD** (Pause/Resume + Stop while a summary plays) used to stack here too,
/// but now floats as an independent, all-Spaces panel — see `SpeakingHUDPresenter` — so its
/// controls are reachable even when this window is closed or on another Space. The banner stays
/// in-app on purpose: pressing Play is a "look at Baton" action, not a live control.
private struct SpeechAlertOverlay: ViewModifier {
    @Environment(MusicModel.self) private var model

    private var speech: SpeechPlaybackEngine { model.speech }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let alert = speech.pendingAlert { banner(alert) }
                }
                .padding(.bottom, 18)
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: speech.pendingAlert)
            }
    }

    // MARK: - Banner (mode = "banner")

    private func banner(_ alert: SpeechPlaybackEngine.Alert) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
            Text(alert.text)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: 320, alignment: .leading)
            Button {
                speech.confirmBanner()
            } label: {
                Label("Play", systemImage: "play.fill").font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            Button {
                speech.dismissBanner()
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
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Shows the in-app spoken-summary "press Play" banner (see `SpeechAlertOverlay`). The live
    /// speaking HUD is now a floating panel (`SpeakingHUDPresenter`), not part of this overlay.
    func speechAlertBanner() -> some View { modifier(SpeechAlertOverlay()) }
}
