import ManagerKit
import SwiftUI

/// Onboarding (Spec §6): Checkliste der Einrichtung, danach der erste Scan als Ausgangsbasis.
struct OnboardingView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    let onboarding: OnboardingModel
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        @Bindable var updates = updates
        VStack(spacing: 0) {
            header
            SetupChecklistView(model: prerequisites, numbered: true) {
                SetupRowLayout(
                    number: SetupStep.allCases.count + 1,
                    title: String(localized: "Updates"),
                    explanation: UpdateFeed.privacyNote,
                    status: .toned(
                        .neutral,
                        updates.onboardingChoice ? String(localized: "Täglich prüfen") : String(localized: "Nicht prüfen")
                    )
                ) {
                    Toggle(UpdateTexts.checkDaily, isOn: $updates.onboardingChoice)
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                SetupRowLayout(
                    number: SetupStep.allCases.count + 2,
                    title: String(localized: "Erster Scan"),
                    explanation: String(localized: "Der erste Scan dient als Ausgangsbasis und meldet nichts; erst Änderungen danach erscheinen im Verlauf und als Benachrichtigung."),
                    status: baselineStatus
                ) { EmptyView() }
            }
            Divider()
            HStack {
                Text("Fehlende Schritte lassen sich später in den Einstellungen nachholen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Später") { onboarding.postpone() }
                    .keyboardShortcut(.cancelAction)
                Button("Fertig") { onboarding.finish() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Grantry einrichten")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Grantry überwacht Berechtigungen und Autostart-Einträge und meldet jede Änderung. Dafür braucht die App einige Freigaben.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 4)
    }

    private var baselineStatus: StatusLabel.Status {
        if appModel.monitoring.isScanning { return .loading(String(localized: "Scan läuft …")) }
        return appModel.monitoring.lastCheckedAt == nil
            ? .toned(.neutral, String(localized: "Folgt nach „Fertig“"))
            : .ok(String(localized: "Ausgangsbasis gespeichert"))
    }
}
