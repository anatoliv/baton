import SafariServices
import SwiftUI

/// An in-app Safari sheet.
///
/// Exists for the privacy policy, which App Review wants reachable *inside* the app
/// (guideline 5.1.1) — bouncing the user out to Safari doesn't count. SFSafariViewController
/// keeps the reader's content, cookies and Reader mode without giving Baton any visibility
/// into the browsing, which is the right shape for a privacy page in particular.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
