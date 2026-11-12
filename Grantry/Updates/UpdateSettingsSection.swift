import GrantryCharts
import ManagerKit
import SwiftUI

/// Gruppe „Updates“ der Einstellungen (LB-5.2, #553): Zustimmung und automatische Installation als Schalter,
/// Datenschutz als Hinweis, Ergebnis der letzten Prüfung als Hinweiszeile (ein verfügbares Update mit seinen Knöpfen),
/// darunter der Stand mit „Jetzt prüfen“.
struct UpdateSettingsSection: View {
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        SettingsPanel(String(localized: "Updates"), detail: detail, finding: availableUpdate != nil) {
            SettingToggle(UpdateTexts.checkDaily,
                          isOn: Binding(get: { updates.isEnabled }, set: { updates.setEnabled($0) }))
            SettingToggle(String(localized: "Updates automatisch installieren"),
                          note: String(localized: "Lädt Updates im Hintergrund und installiert sie beim nächsten Beenden. Standardmäßig ausgeschaltet."),
                          isOn: Binding(get: { updates.installsAutomatically },
                                        set: { updates.setAutomaticInstallation($0) }))
                .disabled(!updates.supportsInstallation || !updates.isEnabled
                    || updates.installationIdentityError != nil)
            if let error = updates.installationError {
                InstrumentNote(error, kind: .critical)
            } else if let status = updates.installationStatus {
                InstrumentNote(status)
            }
            InstrumentNote(UpdateFeed.privacyNote)
            if let outcome = updates.lastOutcome {
                UpdateOutcomeNote(outcome: outcome)
            }
            SettingActionLine(lastCheckText,
                              runningText: updates.isChecking ? String(localized: "Wird geprüft …") : nil) {
                Button("Jetzt prüfen") { Task { await updates.checkNow() } }
                    .disabled(updates.isChecking)
            }
        }
    }

    private var availableUpdate: AppcastItem? {
        if case .available(let item) = updates.lastOutcome { item } else { nil }
    }

    private var detail: String {
        UpdateTexts.settingsDetail(isEnabled: updates.isEnabled, isChecking: updates.isChecking,
                                   availableVersion: availableUpdate?.version,
                                   installedVersion: updates.installedVersion)
    }

    private var lastCheckText: String {
        guard let lastCheck = updates.lastCheck else { return String(localized: "Noch nicht geprüft") }
        return ScanStatusText.lastChecked(lastCheck)
    }
}

/// Ergebnis der letzten Prüfung: verfügbar als Befund mit „Installieren“ bzw. „Laden …“ und der DMG-Prüfsumme,
/// aktuell als ruhiger Hinweis, gescheitert als Fehler.
private struct UpdateOutcomeNote: View {
    let outcome: UpdateModel.Outcome
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        switch outcome {
        case .available(let item):
            VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
                InstrumentNote(outcome.text, kind: .finding)
                DetailActions {
                    Button(updates.downloadButtonTitle) { updates.openDownload(item) }
                    UpdateChecksumView(item: item)
                }
                .controlSize(.small)
            }
        case .upToDate:
            InstrumentNote(outcome.text)
        case .failed:
            InstrumentNote(outcome.text, kind: .critical)
        }
    }
}
