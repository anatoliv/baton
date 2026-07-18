import SwiftUI

/// A brief, floating confirmation toast for music actions (Add to Queue, Play Next,
/// Download…). Watches `model.music.toast` and shows the latest message at the bottom of
/// the music content, auto-dismissing after a short delay. Gives silent actions (which
/// otherwise just mutate an off-screen queue or download in the background) a visible
/// response so they don't read as "nothing happened."
private struct MusicToastOverlay: ViewModifier {
    @Environment(MusicModel.self) private var model
    @State private var shown: StreamingPlaybackController.Toast?
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let shown {
                    Label(shown.text, systemImage: shown.symbol)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: model.music.toast) { _, toast in
                guard let toast else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { shown = toast }
                dismissTask?.cancel()
                dismissTask = Task {
                    try? await Task.sleep(nanoseconds: 1_900_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) { shown = nil }
                }
            }
    }
}

extension View {
    /// Shows music action confirmations (see `MusicToastOverlay`).
    func musicActionToast() -> some View { modifier(MusicToastOverlay()) }
}
