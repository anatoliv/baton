import AVKit
import SwiftUI

/// A SwiftUI wrapper around `AVRoutePickerView` — the standard AirPlay / output
/// route button. Lets the user send the music player's local audio to an AirPlay
/// device (or back to the Mac). Styled borderless to sit in the full-screen player's
/// header alongside the other glyph buttons.
struct AirPlayRoutePicker: NSViewRepresentable {
    var tint: NSColor = .white

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(tint, for: .normal)
        view.setRoutePickerButtonColor(tint.withAlphaComponent(0.6), for: .normalHighlighted)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.setRoutePickerButtonColor(tint, for: .normal)
    }
}
