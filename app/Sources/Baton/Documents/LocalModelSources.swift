import BatonDocuments
import BatonSubsonicKit
import Foundation
import OSLog

/// The model sources saved from Settings → Speech → Models on this Mac (M7.2, M7.3), in the order
/// they were saved. The router reads them through `configuredSources()`; the import sheet's
/// voice suggestion is the first reader.
///
/// Only a source that answered a real test request is saved here (`LocalModelTest`), and only
/// local ones are ever handed out: this list is "what runs on this Mac", and a cloud source
/// needs consent this screen never asks for.
///
/// One `VersionedStore` key, like the other settings lists (`SpeechConfig`'s voice lists): a
/// damaged blob is kept aside rather than read as "nothing saved" and overwritten.
enum LocalModelSources {
    static let key = "baton.documents.localModelSources"

    private static func store(_ defaults: UserDefaults) -> VersionedStore<[ModelSource]> {
        VersionedStore<[ModelSource]>(backing: .defaults(defaults, key: key), currentVersion: 1,
                                      log: Logger(subsystem: "io.tonebox.baton", category: "documents"))
    }

    /// Every saved source that stays on the person's machines, in saved order.
    static func configuredSources(in defaults: UserDefaults = BatonStorage.defaults) -> [ModelSource] {
        (store(defaults).load() ?? []).filter(\.isLocal)
    }

    /// Save `source`, replacing one with the same identity in place, or adding it at the end.
    static func save(_ source: ModelSource, in defaults: UserDefaults = BatonStorage.defaults) {
        var sources = store(defaults).load() ?? []
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        store(defaults).save(sources)
    }

    static func remove(id: String, in defaults: UserDefaults = BatonStorage.defaults) {
        let sources = store(defaults).load() ?? []
        store(defaults).save(sources.filter { $0.id != id })
    }
}
