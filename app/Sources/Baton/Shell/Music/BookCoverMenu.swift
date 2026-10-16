import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Mac's half of book covers: the cover items in a book's menus, with the Mac's
/// own file picker, and Find Cover…'s sheet. The covers themselves are `Shared/BookCovers.swift`.
struct BookCoverMenu: View {
    let covers: BookCovers
    let book: BookShelf.Book
    var report: (String) -> Void = { message in
        let alert = NSAlert()
        alert.messageText = "The cover was not changed"
        alert.informativeText = message
        alert.runModal()
    }

    var body: some View {
        BookCoverMenuItems(covers: covers, documentID: book.documentID, title: book.title, author: book.author,
                           choose: choose, report: report)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Cover for “\(book.title)”"
        panel.prompt = "Use as Cover"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, UTType(filenameExtension: "epub") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try covers.choose(fileAt: url, documentID: book.documentID)
        } catch {
            report(String(describing: error))
        }
    }
}

extension View {
    /// Find Cover…'s sheet, for whichever book asked.
    func bookCoverFinder(_ covers: BookCovers?) -> some View {
        modifier(BookCoverFinderSheet(covers: covers))
    }
}

private struct BookCoverFinderSheet: ViewModifier {
    let covers: BookCovers?

    func body(content: Content) -> some View {
        if let covers {
            content.sheet(item: Binding(get: { covers.finding }, set: { covers.finding = $0 })) { request in
                BookCoverFinder(covers: covers, request: request) { covers.finding = nil }
            }
        } else {
            content
        }
    }
}
