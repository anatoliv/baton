import SwiftUI

/// The two-way question deleting a clipping has to ask, in one place.
///
/// Two outcomes, because they are genuinely different and only the owner knows which is
/// meant: removing it here leaves the Mac's copy alone, while deleting everywhere takes the
/// shared one too and no device collects it again. A single "Delete" would have to pick one
/// silently, and either choice is wrong half the time.
///
/// It is a modifier rather than a block of code inside the Clippings list because the player's
/// long-press menu offers the same delete now. Two copies of a destructive dialog is how the
/// wording drifts, and here the wording *is* the safeguard — it is the only thing telling
/// someone that one of these buttons destroys the last copy of something.
struct ClippingDeleteConfirmation: ViewModifier {
    @Binding var pending: [String]
    let model: MobileModel
    /// Reported when the ledger accepted the deletion but the gateway kept its copy. Silent
    /// on success: a confirmation that something was deleted, when it visibly disappeared, is
    /// noise. Silence on *partial* failure is not, which is why this exists at all.
    var onStatus: (String) -> Void = { _ in }

    /// Clipping ids are not play ids — the queue holds `asSong.id`, the file URL. Resolved
    /// *before* the delete, because once the sidecars are gone there is nothing left to ask.
    private func playableIDs(of clippingIDs: [String]) -> Set<String> {
        Set(clippingIDs.compactMap { model.clippings.item(id: $0)?.asSong.id })
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pending.count == 1 ? "Delete this clipping?" : "Delete \(pending.count) clippings?",
            isPresented: .init(get: { !pending.isEmpty },
                               set: { if !$0 { pending = [] } }),
            titleVisibility: .visible
        ) {
            Button("Remove from this iPhone", role: .destructive) {
                // Off the speakers and out of the queue before the files go. Deleting told the
                // player nothing, and on Darwin an open file outlives its directory entry, so a
                // deleted clipping played happily to the end of something gone.
                model.music.dropFromQueue(ids: playableIDs(of: pending))
                // Tombstoned locally, so it stays gone here. The Mac keeps its copy.
                for id in pending { model.clippings.remove(id: id) }
                pending = []
            }
            Button("Delete Everywhere", role: .destructive) {
                let ids = pending
                model.music.dropFromQueue(ids: playableIDs(of: ids))
                pending = []
                Task {
                    let failed = await model.deleteClippingsEverywhere(ids)
                    guard failed > 0 else { return }
                    // Said plainly: without this it looks like a clean delete and then
                    // reappears on another device, which is the confusing outcome this whole
                    // dialog exists to avoid.
                    onStatus("Removed here, but \(Counted.phrase(failed, "clipping")) stayed on the gateway")
                }
            }
            Button("Cancel", role: .cancel) { pending = [] }
        } message: {
            Text("Removing it here leaves the copy on your Mac. Deleting everywhere also removes "
                 + "it from your home gateway, so no device collects it again.")
        }
    }
}

extension View {
    /// Ask before deleting the clippings whose ids are in `pending`; an empty array shows nothing.
    func clippingDeleteConfirmation(
        _ pending: Binding<[String]>,
        model: MobileModel,
        onStatus: @escaping (String) -> Void = { _ in }
    ) -> some View {
        modifier(ClippingDeleteConfirmation(pending: pending, model: model, onStatus: onStatus))
    }
}
