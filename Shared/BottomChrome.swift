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
    /// Outer inset for a floating capsule, tuned against the iOS 26 tab bar's own inset.
    public static let inset: CGFloat = 10
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
