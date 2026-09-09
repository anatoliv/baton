import SwiftUI

/// What the import brought, and whether any of it works — shown in the same flow.
///
/// The screen this replaces was an alert reading "Imported 74 settings and 9 secrets", with
/// an OK button. True, and no help: it says a file was parsed, not that a single service can
/// be reached, and it leaves someone to discover on their own that the Friend tab is still
/// missing because a test has not been run.
///
/// Nothing here can be dismissed into a wrong state: the checks start on appear, each row
/// shows its own answer as it lands, and a failure leaves every imported setting in place.
/// A friend that cannot be reached from this phone is worth knowing about immediately and is
/// not a reason to undo a transfer that worked.
struct ImportedSetupCheckView: View {
    let model: MobileModel
    let summary: String
    let check: ImportedSetupCheck
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                        .labelStyle(.titleAndIcon)
                } footer: {
                    Text(footer)
                }

                if !check.order.isEmpty {
                    Section("Checking what arrived") {
                        ForEach(check.order) { service in
                            row(service)
                        }
                    }
                }
            }
            .navigationTitle("Set Up from a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDone(); dismiss() }
                        .disabled(check.isRunning)
                }
            }
            .task { await check.run(on: model) }
            .interactiveDismissDisabled(check.isRunning)
        }
    }

    /// Says what the state of the screen actually is, rather than congratulating anyone.
    /// The three cases need different things from the reader, so they are three sentences.
    private var footer: String {
        if check.isRunning {
            return "Testing each service the import configured. Nothing is being sent. These are read-only checks."
        }
        if check.order.isEmpty {
            return "Your settings are in. There was nothing here that needed a connection test."
        }
        if check.allPassed {
            return "Everything the import configured is answering. Your music friend is ready and its tab is in the tab bar."
        }
        return "Your settings are in and nothing was undone. The services below that could not be reached usually point at an address that only works on your home network. Open Settings to change one."
    }

    @ViewBuilder
    private func row(_ service: ImportedSetupCheck.Service) -> some View {
        let status = check.status(for: service)
        HStack(spacing: 10) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
                .symbolEffect(.rotate, isActive: status.isChecking)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                Text(status.isChecking ? "Checking…" : status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = status.detail, !status.isChecking {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ImportCheck.\(service.rawValue)")
    }
}
