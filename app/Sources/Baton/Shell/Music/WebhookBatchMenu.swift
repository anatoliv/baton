import SwiftUI

/// The **Actions** menu for a batch bar — runs a custom action across a whole selection, with a
/// confirmation before a large fan-out.
///
/// A batch multiplies a single action into one request per item, so an accidental select-all →
/// click could fire hundreds of requests, each carrying whatever the action sends (including
/// credential-bearing URLs, if the action opted in). Above a threshold this asks first. Owning the
/// guard here — rather than in each selection bar — means no call site can skip it, the same reason
/// the credentialed-token strip lives in `WebhookActionStore.run`.
///
/// `tokenSets` is a closure so the (sometimes credential-fetching) per-item token sets are only
/// built when an action is actually chosen, not on every render of the bar.
struct WebhookBatchMenu: View {
    /// Per-item token sets for the current selection, built on demand.
    let tokenSets: () -> [[String: String]]
    /// The selection size, shown in the confirmation and used to decide whether to ask.
    let count: Int

    @Environment(MusicModel.self) private var model
    @State private var pending: WebhookAction?

    /// Selections larger than this confirm before firing. Small enough that a deliberate handful
    /// runs immediately; large enough that a select-all is caught.
    static let confirmThreshold = 25

    var body: some View {
        if !model.webhookActions.actions.isEmpty {
            Menu {
                ForEach(model.webhookActions.actions) { action in
                    Button(action.name, systemImage: SFSymbolCatalog.resolved(action.icon)) {
                        attempt(action)
                    }
                }
            } label: {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.body).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Run an action on the selection")
            .confirmationDialog(
                pending.map { "Run “\($0.name)” on \(count) items?" } ?? "",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { action in
                Button("Run on \(count) items") { fire(action) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This sends one request per item.")
            }
        }
    }

    private func attempt(_ action: WebhookAction) {
        if count > Self.confirmThreshold {
            pending = action
        } else {
            fire(action)
        }
    }

    private func fire(_ action: WebhookAction) {
        pending = nil
        WebhookRunner.runBatch(action, tokenSets: tokenSets(), model)
    }
}
