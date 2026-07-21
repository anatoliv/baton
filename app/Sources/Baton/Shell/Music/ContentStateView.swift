import SwiftUI

/// A consistent load / empty / error presentation for data-backed screens, so Baton is honest
/// everywhere instead of leaving a blank grid when a fetch is loading, returned nothing, or failed.
/// Screens derive a `ContentDisplayState` from their store's `isLoading` / `lastError` / emptiness
/// and overlay `contentState(...)`; the resolution is a pure function (unit-tested). (W-55)
enum ContentDisplayState: Equatable {
    case loading
    case empty
    case failed(String)
    case content

    /// Priority: a live fetch shows the spinner; once settled, an error wins over an empty result,
    /// which wins over showing (nonexistent) content.
    static func resolve(isLoading: Bool, error: String?, isEmpty: Bool) -> ContentDisplayState {
        if isLoading { return .loading }
        if let error, !error.trimmingCharacters(in: .whitespaces).isEmpty { return .failed(error) }
        return isEmpty ? .empty : .content
    }
}

/// The placeholder shown for a non-content state. Uses the native `ContentUnavailableView` so it
/// matches system styling (search-empty, error, etc.).
struct ContentStatePlaceholder: View {
    let state: ContentDisplayState
    var emptyTitle = "Nothing here yet"
    var emptyMessage = "Try a different filter, or check your connection."
    var emptySymbol = "tray"
    var onRetry: (() -> Void)?

    var body: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.large)
        case .empty:
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptySymbol)
            } description: {
                Text(emptyMessage)
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let onRetry {
                    Button("Try Again", action: onRetry).buttonStyle(.borderedProminent)
                }
            }
        case .content:
            EmptyView()
        }
    }
}

extension View {
    /// Overlay the load/empty/error placeholder when the derived `state` isn't `.content`, and dim
    /// the underlying content while a non-content state shows.
    @ViewBuilder
    func contentState(
        _ state: ContentDisplayState,
        emptyTitle: String = "Nothing here yet",
        emptyMessage: String = "Try a different filter, or check your connection.",
        emptySymbol: String = "tray",
        onRetry: (() -> Void)? = nil
    ) -> some View {
        overlay {
            if state != .content {
                ContentStatePlaceholder(
                    state: state, emptyTitle: emptyTitle, emptyMessage: emptyMessage,
                    emptySymbol: emptySymbol, onRetry: onRetry
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
    }
}
