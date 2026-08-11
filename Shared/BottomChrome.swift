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
    /// **What this does and does not align.** On iOS 26 the mini player is handed to
    /// `tabViewBottomAccessory` (`RootTabView.swift`) as `.systemAccessory`, and that
    /// branch never calls `bottomChromeCapsule()` — the system draws the container and
    /// owns its inset. So on the current OS this constant governs the Friend composer
    /// alone, and the 20pt is an eyeball match to the system slot rather than a measured
    /// agreement with it. There is no public API that reports the accessory's inset, which
    /// is why it stays an eyeball match instead of being derived.
    ///
    /// Where it genuinely aligns two things is the `.standalone` path — iPad, and iOS 18
    /// through 25 — where the mini player draws its own capsule through the same modifier.
    ///
    /// The distinction is written down because losing it cost a misdiagnosis: a composer
    /// that looked wrong against the accessory was chased through this constant, which on
    /// that OS could not have been the cause. If the composer and the accessory drift
    /// again on iOS 26, the fix is this number, checked against a screenshot — the code
    /// cannot enforce it.
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
