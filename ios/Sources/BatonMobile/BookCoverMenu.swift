import SwiftUI
import UniformTypeIdentifiers

/// The iPhone's half of book covers: the same cover items as the Mac's, with the
/// iPhone's own file picker, Find Cover…'s sheet, and a word when a change could not be made.
/// The covers themselves are `Shared/BookCovers.swift`.
struct BookCoverMenu: View {
    let covers: BookCovers
    let book: MobileBookShelf.Book

    var body: some View {
        BookCoverMenuItems(covers: covers, documentID: book.documentID, title: book.title, author: book.author,
                           choose: {
                               covers.choosing = BookCovers.Request(documentID: book.documentID, title: book.title,
                                                                    author: book.author)
                           },
                           report: { covers.notice = $0 })
    }
}

extension View {
    /// Find Cover…'s sheet, Choose Image…'s file picker and the "not changed" alert, for
    /// whichever book asked.
    func bookCoverSheets(_ covers: BookCovers?) -> some View {
        modifier(BookCoverSheets(covers: covers))
    }
}

private struct BookCoverSheets: ViewModifier {
    let covers: BookCovers?
    /// The book the file picker is for, kept past the picker clearing `choosing` as it closes.
    @State private var target: BookCovers.Request?
    /// Whether this screen is the one showing. The list and the open book are both `BooksView`
    /// and both stay alive while the book is pushed over the list; only the one on screen may
    /// present, or the two fight over one request and neither sheet appears.
    @State private var onScreen = false

    func body(content: Content) -> some View {
        if let covers {
            content
                .sheet(item: Binding(get: { onScreen ? covers.finding : nil }, set: { covers.finding = $0 })) { request in
                    NavigationStack {
                        BookCoverFinder(covers: covers, request: request) { covers.finding = nil }
                    }
                    .presentationDetents([.large])
                }
                .fileImporter(isPresented: Binding(get: { onScreen && covers.choosing != nil }, set: { if !$0 { covers.choosing = nil } }),
                              allowedContentTypes: [.image, UTType(filenameExtension: "epub") ?? .data]) { result in
                    guard let request = target else { return }
                    switch result {
                    case let .success(url):
                        do { try covers.choose(fileAt: url, documentID: request.documentID) } catch {
                            covers.notice = String(describing: error)
                        }
                    case .failure:
                        break
                    }
                }
                .onChange(of: covers.choosing) { _, request in if let request { target = request } }
                .onAppear { onScreen = true }
                .onDisappear { onScreen = false }
                .alert("The cover was not changed", isPresented: Binding(get: { onScreen && covers.notice != nil },
                                                                          set: { if !$0 { covers.notice = nil } })) {
                    Button("OK", role: .cancel) { covers.notice = nil }
                } message: {
                    Text(covers.notice ?? "")
                }
        } else {
            content
        }
    }
}
