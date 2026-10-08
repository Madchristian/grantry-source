import ManagerKit
import SwiftUI

/// Einstellungen der Update-Prüfung: Zustimmung, letzte Prüfung, „Jetzt prüfen“.
struct UpdateSettingsSection: View {
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(UpdateTexts.checkDaily, isOn: Binding(
                get: { updates.isEnabled }, set: { updates.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            Text(verbatim: UpdateFeed.privacyNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(lastCheckText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if updates.isChecking {
                    ProgressView().controlSize(.small)
                }
                Button("Jetzt prüfen") { Task { await updates.checkNow() } }
                    .disabled(updates.isChecking)
            }
            if let outcome = updates.lastOutcome {
                Text(verbatim: outcome.text)
                    .font(.callout)
                if case .available(let item) = outcome {
                    Button(UpdateTexts.download) { updates.openDownload(item) }
                }
            }
        }
        .padding()
    }

    private var lastCheckText: String {
        guard let lastCheck = updates.lastCheck else { return String(localized: "Noch nicht geprüft") }
        return ScanStatusText.lastChecked(lastCheck)
    }
}
