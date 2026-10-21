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
            Toggle("Updates automatisch installieren", isOn: Binding(
                get: { updates.installsAutomatically }, set: { updates.setAutomaticInstallation($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!updates.supportsInstallation || !updates.isEnabled || updates.installationIdentityError != nil)
            Text("Lädt Updates im Hintergrund und installiert sie beim nächsten Beenden. Standardmäßig ausgeschaltet.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = updates.installationError {
                Text(error).foregroundStyle(.red).font(.callout)
            } else if let status = updates.installationStatus {
                Text(status).font(.callout)
            }
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
                    HStack {
                        Button(updates.downloadButtonTitle) { updates.openDownload(item) }
                        UpdateChecksumView(item: item)
                    }
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
