import UIKit
import UniformTypeIdentifiers

/// "Baton" in the share sheet: a PDF, EPUB, web page, text or Markdown file, or a
/// page's address, is left in the App Group inbox for the app to open on the import screen.
///
/// A share extension cannot open its host app on iOS, so this one does its one job, says where
/// the document went and closes. It stays small on purpose: no app code beyond the inbox, nothing
/// read into memory but shared text, and a file is copied by the file system.
final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let detail = UILabel()
    private let done = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        message.font = .preferredFont(forTextStyle: .headline)
        message.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 0
        message.textAlignment = .center
        message.text = "Saving for Baton…"
        detail.font = .preferredFont(forTextStyle: .body)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        done.isHidden = true
        done.addAction(UIAction { [weak self] _ in self?.finish() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [message, detail, done])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { await save(providers) }
    }

    private var failed = false

    private func save(_ providers: [NSItemProvider]) async {
        do {
            guard let inbox = PendingShareInbox.shared else { throw ShareError.noInbox }
            guard let pick = Self.pick(providers) else { throw ShareError.nothingToImport }
            let marker = try await Self.save(pick, in: inbox)
            message.text = "Saved \(marker.originalName) for Baton"
            detail.text = "Open Baton to make the audiobook."
        } catch {
            failed = true
            message.text = "Baton could not keep this"
            detail.text = (error as? ShareError)?.message ?? error.localizedDescription
        }
        done.isHidden = false
    }

    private func finish() {
        if failed {
            extensionContext?.cancelRequest(withError: ShareError.nothingToImport)
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    // MARK: - What was shared

    private enum Pick {
        case file(NSItemProvider, UTType)
        case link(NSItemProvider)
    }

    /// Document files first, then a page's address, then plain text: an app sharing a link
    /// usually sends the page title alongside it as text, and the page is what was meant.
    private static let documentTypes: [UTType] = [.pdf, .epub, .html] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }

    private static func pick(_ providers: [NSItemProvider]) -> Pick? {
        for type in documentTypes {
            if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) {
                return .file(provider, type)
            }
        }
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) {
            return .link(provider)
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            return .file(provider, .plainText)
        }
        return nil
    }

    private static func save(_ pick: Pick, in inbox: PendingShareInbox) async throws -> PendingShareInbox.Marker {
        switch pick {
        case let .link(provider):
            let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
            guard let url = (item as? URL) ?? (item as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }),
                  PendingShareInbox.isWebLink(url) else { throw ShareError.nothingToImport }
            return try inbox.writeLink(url)
        case let .file(provider, type):
            let suggested = provider.suggestedName
            do {
                return try await withCheckedThrowingContinuation { continuation in
                    // The file handed over exists only for the length of this callback: copy it here.
                    _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                        guard let url else { return continuation.resume(throwing: error ?? ShareError.nothingToImport) }
                        continuation.resume(with: Result {
                            try inbox.writeFile(copying: url, originalName: name(for: url, suggested: suggested, type: type))
                        })
                    }
                }
            } catch where type == .plainText {
                // Selected text arrives as a string rather than a file.
                let item = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
                guard let text = (item as? String) ?? (item as? Data).flatMap({ String(data: $0, encoding: .utf8) }),
                      !text.isEmpty else { throw ShareError.nothingToImport }
                return try inbox.writeText(text)
            }
        }
    }

    /// The name the import screen shows and the importer reads the format from: the file's own
    /// name when it carries an extension, otherwise the sender's suggestion plus the type's.
    private static func name(for url: URL, suggested: String?, type: UTType) -> String {
        if !url.pathExtension.isEmpty { return url.lastPathComponent }
        let base = suggested ?? "Shared document"
        guard let ext = type.preferredFilenameExtension, (base as NSString).pathExtension.isEmpty else { return base }
        return "\(base).\(ext)"
    }

    private enum ShareError: Error {
        case noInbox, nothingToImport
        var message: String {
            switch self {
            case .noInbox: "This copy of Baton cannot receive shared documents."
            case .nothingToImport: "Baton makes books from PDF, EPUB, web pages, text and Markdown."
            }
        }
    }
}
