import SwiftUI

/// The header every root tab wears in place of a navigation bar.
///
/// Home used to be the only screen doing this, which made it the inconsistent one: it
/// opened at 74pt while Albums, Library, Search and Settings all opened at 128pt. The
/// difference wasn't a bug in the other four — a system large title is a perfectly
/// ordinary layout — it was that two different header treatments were in the app at once.
///
/// So this is the single treatment, and every root tab uses it:
///
///   - **No navigation bar.** A root tab has nothing to navigate back to, so the bar's
///     only job was drawing the title, and it reserved a band above itself to do it.
///     Pushed screens still get their bar, and their back button with it.
///   - **Pinned, not scrolled.** It replaces a navigation bar, so it should behave like
///     one: stay put, and let content pass beneath it.
///   - **A title and a line of context.** The reclaimed space says something —
///     "142 albums · 38 artists" rather than air.
///   - **A material background.** Content scrolls *under* a safe-area inset, and the
///     artwork wash stays visible through it, which is the point of the wash.
///
/// `trailing` is for a screen's one primary action (Albums' sort menu), and `accessory`
/// for a control that needs its own row (Search's field, which can't live in a navigation
/// bar that isn't there).
///
/// The other half of the convention lives on the pushed screens, which do keep a bar
/// because they need its back button: **every one of them is `.inline`**. They used to be
/// split — Artists, Liked, Playlists, Downloads, History and Radio drew large titles while
/// Help, Scrobbling and the scanner drew inline ones, with no rule separating them. Inline
/// is the right default for a pushed screen anyway: you arrived by tapping a row that
/// already said where you were going, so restating it in 34pt costs 76pt to tell you
/// something you just read.
struct RootScreenHeader<Trailing: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    // Plain stored views rather than `@ViewBuilder` properties: the builder attribute
    // makes the memberwise init take closures, and the `View` extension below is already
    // the builder-shaped entry point.
    let trailing: Trailing
    let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.largeTitle.weight(.bold))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
                    // Matches what a .topBarTrailing toolbar item looked like, so moving
                    // the control out of the navigation bar doesn't shrink it.
                    .font(.title3)
            }
            accessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }
}

extension View {
    /// Replaces this root screen's navigation bar with the shared pinned header.
    ///
    /// Applied inside a `NavigationStack`, to the stack's *root* content — hiding the bar
    /// this way affects only the view it is attached to, so anything pushed on top still
    /// gets a bar and a back button. `ScreenAuditUITests` pushes into a screen and taps
    /// back, because a dead end is not something a unit test can see.
    func rootScreenHeader<Trailing: View, Accessory: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                RootScreenHeader(title: title, subtitle: subtitle,
                                 trailing: trailing(), accessory: accessory())
            }
            // Content starts *under* a safe-area inset, so without this the first row or
            // tile is welded to the header's bottom edge — Albums' artwork sat against it
            // with no gap at all. Set here rather than per screen so every root tab gets
            // the same gap, which is the point of a shared header.
            .contentMargins(.top, 14, for: .scrollContent)
    }
}

/// "1 album", "2 albums".
///
/// Every header line here is a list of counted nouns, and the first pass shipped
/// "1 albums · 1 artists" onto the Search tab — small, but it is the sort of thing that
/// makes an app look like nobody used it.
enum Counted {
    static func phrase(_ count: Int, _ singular: String, plural: String? = nil) -> String {
        "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// Joins the parts that are actually worth showing. Returns nil rather than an empty
    /// string when nothing is — a header line saying "0 playlists · 0 downloaded" is worse
    /// than no header line.
    static func line(_ parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }
}

/// Play time, in the two shapes lists need.
///
/// A track and a collection want different answers to "how long": `4:21` reads as a
/// position on a clock, `6h 57m` reads as an evening. Using one format for both makes
/// track lists look like spreadsheets and album totals look like timestamps — so these
/// stay separate, and every list picks the one that matches what its row *is*.
enum PlayTime {
    /// A single track: `4:21`, or `1:04:30` once it passes an hour (live sets, mixes).
    static func track(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// A collection: `6h 57m`, or `45m` under an hour. Never seconds — nobody plans an
    /// evening to the second, and the extra digits only add noise.
    static func total(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// The search field, in the header, because there is no navigation bar to put it in.
///
/// `.searchable` renders into the navigation bar; on a screen that hides its bar it
/// simply doesn't appear, which would have left the Search tab with no way to search.
/// This is the system's own look — rounded rect, magnifying glass, clear button — built
/// where it can actually be seen.
struct HeaderSearchField: View {
    let prompt: String
    @Binding var text: String
    /// Owned by the screen, not this view: the keyboard covers the tab bar, so whoever
    /// hosts the field needs to be able to give focus back — otherwise the screen has no
    /// exit while the keyboard is up.
    var externalFocus: FocusState<Bool>.Binding?
    /// Fired when the keyboard's Search key is pressed. Recording history on every
    /// keystroke would fill it with "d", "di", "did" on the way to "dido"; a submit is the
    /// only signal that the query was finished rather than in progress.
    var onSubmit: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(externalFocus ?? $focused)
                .onSubmit { onSubmit?() }
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        // A capsule, to match `.searchable` — which is what the other six search and
        // filter fields in the app are. This one is custom only because `.searchable`
        // renders into the navigation bar and this screen hides its bar; that is an
        // implementation constraint, and it shouldn't be visible as a different shape.
        .background(.quaternary.opacity(0.6), in: Capsule())
        // The audit walks by identifier; a search field the test can't find is a
        // search field nobody can prove works.
        .accessibilityIdentifier("SearchField")
    }
}
