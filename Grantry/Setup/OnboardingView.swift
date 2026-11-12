import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

/// Onboarding (Spec §6) im Lagebild (LB-5.3, #554; Entwurf LB-5.1, Spec 2026-11-10 § 11.5 c, d und Korrektur): oben die
/// Lagezeile mit Schild und Urteil – bis zur gespeicherten Ausgangsbasis in der Schildform „offen“ –, darunter die
/// Einrichtung als Prüfzeilen wie in den Einstellungen samt Updates und erstem Scan, unten die Aktionsleiste mit
/// „Später“ und „Fertig“. Solange das Blatt sichtbar ist, wird der Festplattenvollzugriff alle 2 s geprüft und bei der
/// Rückkehr in die App (etwa aus den Systemeinstellungen) alles erneut.
struct OnboardingView: View {
    let appModel: AppModel
    let prerequisites: PrerequisitesModel
    let onboarding: OnboardingModel
    @Environment(UpdateModel.self) private var updates
    @State private var selection: CheckItem.ID?

    var body: some View {
        let checklist = prerequisites.checklist
        let summary = OnboardingSummary(checklist: checklist, checksUpdatesDaily: updates.onboardingChoice,
                                        baseline: baseline)
        WindowContent(width: OnboardingLayout.width) {
            VerdictBar(verdict: String(localized: "Grantry einrichten"), reason: Self.intro,
                       shield: summary.shield.form, items: [summary.verdict.statusItem],
                       facts: summary.stepsText)
            SettingsPanel(String(localized: "Einrichtung"), detail: summary.progressText) {
                CheckRows(items: checklist.items.map(\.checkItem) + extraItems(summary),
                          selection: $selection) { check in
                    OnboardingStepActions(id: check.id, checklist: checklist, model: prerequisites,
                                          progress: appModel.monitoring.isScanning
                                              ? appModel.monitoring.scanProgress : nil)
                }
                if let error = prerequisites.setupErrorText {
                    InstrumentNote(error, kind: .critical)
                }
            }
        } bar: {
            WindowBar {
                Text("Fehlende Schritte lassen sich später in den Einstellungen nachholen.")
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } actions: {
                Button("Später") { onboarding.postpone() }
                    .keyboardShortcut(.cancelAction)
                Button("Fertig") { onboarding.finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task { await prerequisites.pollFullDiskAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await prerequisites.refresh(showsProgress: false) }
        }
        .onChange(of: checklist.leadingStep, initial: true) { _, step in
            if selection == nil, let step { selection = step.checkID }
        }
        .onChange(of: baseline, initial: true) { _, baseline in
            if baseline == .scanning, selection == nil { selection = OnboardingStep.baseline }
        }
    }

    private static let intro = String(localized: "Grantry überwacht Berechtigungen und Autostart-Einträge und meldet jede Änderung. Dafür braucht die App einige Freigaben.")

    private var baseline: OnboardingSummary.Baseline {
        if appModel.monitoring.isScanning { return .scanning }
        return appModel.monitoring.lastCheckedAt == nil ? .pending : .saved
    }

    /// Die zwei Schritte nur im Onboarding: Updates (Zustimmung) und erster Scan als Ausgangsbasis.
    private func extraItems(_ summary: OnboardingSummary) -> [CheckItem] {
        [
            CheckItem(id: OnboardingStep.updates, symbol: "arrow.down.circle", title: String(localized: "Updates"),
                      reason: OnboardingSummary.updatesReason, status: summary.updatesStatus.statusItem,
                      explanation: OnboardingSummary.updatesExplanation),
            CheckItem(id: OnboardingStep.baseline, symbol: "viewfinder", title: String(localized: "Erster Scan"),
                      reason: String(localized: "Der erste Scan dient als Ausgangsbasis und meldet nichts."),
                      status: summary.baselineStatus.statusItem,
                      explanation: String(localized: "Erst Änderungen danach erscheinen im Verlauf und als Benachrichtigung.")),
        ]
    }
}

/// Maße des Onboarding-Blatts: Breite wie bisher (Entwurf LB-5.1).
enum OnboardingLayout {
    static let width: CGFloat = 620
}

/// Kennungen der zwei Prüfzeilen nur im Onboarding.
private enum OnboardingStep {
    static let updates = "onboarding.updates"
    static let baseline = "onboarding.baseline"
}

/// Aktionen der aufgeklappten Zeile (Spec § 11.5 c): die Schritte der Einrichtung wie in den Einstellungen
/// (`SetupStepActions`), Updates mit dem Schalter der Zustimmung, der erste Scan mit seinem Fortschritt.
private struct OnboardingStepActions: View {
    let id: CheckItem.ID
    let checklist: SetupChecklist
    let model: PrerequisitesModel
    let progress: ScanProgress?
    @Environment(UpdateModel.self) private var updates

    var body: some View {
        @Bindable var updates = updates
        switch id {
        case OnboardingStep.updates:
            DetailActions {
                Toggle(UpdateTexts.checkDaily, isOn: $updates.onboardingChoice)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        case OnboardingStep.baseline:
            if let progress {
                ScanProgressText(progress: progress) { text in
                    ProgressSpur(title: String(localized: "Scan läuft"), detail: text,
                                 fraction: progress.isIndeterminate ? nil : progress.fraction, tone: .info)
                }
            }
        default:
            if let item = checklist.items.first(where: { $0.step.checkID == id }) {
                SetupStepActions(item: item, model: model)
            }
        }
    }
}

extension OnboardingSummary.Status {
    /// Zustandschip der Instrumententafel (Standard § 2.5): laufend als Information, offen als Befund.
    var statusItem: StatusItem {
        let tone: StatusTone = switch self.tone {
        case .neutral: .neutral
        case .running: .info
        case .positive: .positive
        case .finding: .finding
        }
        return StatusItem(text, tone: tone)
    }
}

extension OnboardingSummary.Shield {
    /// Schildform der Lagezeile: „offen“ ohne Häkchen, solange es kein Urteil gibt (Korrektur der Abnahme LB-5.1).
    var form: ShieldForm {
        switch self {
        case .open: .open
        case .judged(let finding): ShieldForm(finding: finding)
        }
    }
}
