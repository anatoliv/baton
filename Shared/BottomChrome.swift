import SwiftUI

/// The shared geometry of the floating things at the bottom of the phone.
///
/// The mini player, the Friend composer and the system tab bar stack in the same 200pt of
/// screen, and they only look right if their columns line up. They did not: the mini bar
/// used a 10pt outer inset and the composer 12pt. Two points apart is worse than either —
/// far enough to read as misaligned, close enough to look like a mistake rather than a
/// choice.
///
/// One constant so a third floating element cannot introduce a third inset, which is
/// exactly how the first two drifted.
public enum BottomChrome {
    /// Outer inset for a floating capsule.
    ///
    /// Measured against the *system* tab bar and the accessory slot the mini player sits
    /// in on iOS 26 — not the app's own `.standalone` fallback, which is where the first
    /// attempt took its 10pt from. The result was a composer capsule visibly wider than the
    /// two capsules under it, which is the same misalignment in a new shape.
    public static let inset: CGFloat = 20
    /// Gap between stacked capsules.
    public static let gap: CGFloat = 4
    public static let shadowRadius: CGFloat = 8
    public static let shadowOpacity: Double = 0.12
}

public extension View {
    /// The floating-capsule treatment shared by the mini player and the Friend composer.
    func bottomChromeCapsule() -> some View {
        background(.bar, in: Capsule())
            .shadow(color: .black.opacity(BottomChrome.shadowOpacity),
                    radius: BottomChrome.shadowRadius, y: 2)
            .padding(.horizontal, BottomChrome.inset)
            .padding(.bottom, BottomChrome.gap)
    }
}
