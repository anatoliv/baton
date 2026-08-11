import SwiftUI

public extension View {
    /// The one keyboard-dismissal policy for every list you can filter or search.
    ///
    /// There were three policies across nine screens: Albums dismissed `.immediately`,
    /// Search `.interactively`, and Artists, Folders, Genres, Playlists, Liked, Radio and
    /// Help stated nothing at all and took whatever the system defaulted to. Four
    /// automation attempts failed on this interaction before anyone noticed it was three
    /// different interactions.
    ///
    /// `.immediately` is the one, and the reasoning is Albums': interactive dismissal
    /// needs a slow drag *on* the keyboard's own region, while the thing you actually do
    /// after typing a filter is scroll the results. Any scroll puts the keyboard away —
    /// which also means the tab bar it covers is never more than a flick from reachable,
    /// and that is the property that matters, because the keyboard covering the tab bar is
    /// how these screens trapped people in the first place.
    ///
    /// Music Friend is deliberately not one of these. A conversation is not a list you
    /// filter: you scroll back through it *while* composing, and dismissing the keyboard
    /// on every such scroll would fight the user. It keeps `.interactively` plus a tap on
    /// the transcript, which is what every messaging app on the phone teaches.
    func searchKeyboardDismissal() -> some View {
        scrollDismissesKeyboard(.immediately)
    }
}
