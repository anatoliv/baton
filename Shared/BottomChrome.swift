import SwiftUI

/// The shared geometry of the floating things at the bottom of the phone.
///
/// The mini player, the Friend composer and the system tab bar stack in the same 200pt of
/// screen, and they only look right if their columns line up. They did not: the mini bar
/// used a 10pt outer inset and the composer 12pt. Two points apart is worse than either —
/// far enough to read as misaligned, close enough to look like a mistake rather than a
/// choice.
///
/// One constant for the capsules Baton draws, so a third floating element cannot introduce a
/// third inset, which is exactly how the first two drifted. The system's accessory slot has its
/// own, measured, in `systemAccessoryInset`.
public enum BottomChrome {
    /// Outer inset for a floating capsule.
    ///
    /// **What this does and does not align.** On iOS 26 the mini player is handed to
    /// `tabViewBottomAccessory` (`RootTabView.swift`) as `.systemAccessory`, and that
    /// branch never calls `bottomChromeCapsule()` — the system draws the container and
    /// owns its inset. There is no public API that reports the accessory's inset; the slot
    /// was measured at 21pt (`systemAccessoryInset`, TBX-1000000140), and on an iPhone with
    /// iOS 26 the Friend composer and the alarm pill take that through `floatingInset`
    ///, not this constant. Until then this 20pt was an eyeball match there.
    ///
    /// Where it genuinely aligns two things is the `.standalone` path — iPad, and iOS 18
    /// through 25 — where the mini player draws its own capsule through the same modifier.
    ///
    /// The distinction is written down because losing it cost a misdiagnosis: a composer
    /// that looked wrong against the accessory was chased through this constant, which on
    /// that OS could not have been the cause. If the composer and the accessory drift
    /// again on iOS 26, the fix is `floatingInset`, checked against a screenshot.
    /// `BottomChromeAlignmentUITests` measures the rendered composer against the tab bar.
    public static let inset: CGFloat = 20
    /// Where the system draws the mini player on an iPhone with iOS 26: the tab bar's accessory
    /// slot, 21pt in from each edge, like the tab bar itself. Measured, not reported by any API:
    /// the owner's photo (390pt iPhone, TestFlight) and the iPhone 16e and 17 Pro Max simulators on
    /// iOS 26.5 put the accessory's and the tab bar's capsule strokes at 21pt.
    /// The Alarm and Timer pill and the Friend composer take it through `floatingInset`.
    public static let systemAccessoryInset: CGFloat = 21

    /// The outer inset for a capsule Baton draws over the tab bar: the system accessory's
    /// 21pt on an iPhone with iOS 26, where the system draws the mini player, and `inset`
    /// on the iPad and iOS 18 to 25, where the mini player is Baton's own standalone capsule.
    /// One selector, so the composer and the alarm pill cannot drift apart.
    @MainActor
    public static var floatingInset: CGFloat {
        #if os(iOS)
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom != .pad {
            return systemAccessoryInset
        }
        #endif
        return inset
    }
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
            .padding(.horizontal, BottomChrome.floatingInset)
            .padding(.bottom, BottomChrome.gap)
    }
}
