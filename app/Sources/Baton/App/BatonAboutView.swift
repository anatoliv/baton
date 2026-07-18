import SwiftUI

/// Custom About panel for Baton, shown from the app menu's "About Baton" item.
/// Reads the version straight from the bundle so it always matches the shipped
/// build, and carries the product tagline + attribution.
struct BatonAboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .padding(.top, 4)

            Text("Baton")
                .font(.system(size: 22, weight: .semibold))

            Text("by Tonebox")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Conduct your music.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .italic()

            Text(version)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(width: 300)
    }
}
