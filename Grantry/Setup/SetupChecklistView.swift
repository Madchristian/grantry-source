import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

/// Gruppe „Einrichtung“ der Einstellungen als Prüfzeilen (LB-5.2, #553; Spec 2026-11-10 § 11.5 c und e, Standard
/// § 3.10a): je Schritt Zustand als Chip, Aktionen nur in der aufgeklappten Zeile, „Erneut prüfen“ im Kopf. Beim Öffnen
/// ist die wichtigste offene Zeile aufgeklappt. Solange sie sichtbar ist, wird der Festplattenvollzugriff alle 2 s
/// geprüft und bei der Rückkehr in die App (etwa aus den Systemeinstellungen) alles erneut.
struct SetupChecklistView: View {
    let model: PrerequisitesModel
    @State private var selection: CheckItem.ID?

    var body: some View {
        let checklist = model.checklist
        SettingsPanel(String(localized: "Einrichtung"), detail: checklist.panelDetail, value: checklist.panelValue,
                      finding: checklist.hasOpenSteps) {
            Button("Erneut prüfen") { Task { await model.refresh() } }
                .disabled(model.isUpdatingPrerequisites)
        } content: {
            CheckRows(items: checklist.items.map(\.checkItem), selection: $selection) { check in
                if let item = checklist.items.first(where: { $0.step.checkID == check.id }) {
                    SetupStepActions(item: item, model: model)
                }
            }
            if let error = model.setupErrorText {
                InstrumentNote(error, kind: .critical)
            }
        }
        .task { await model.pollFullDiskAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh(showsProgress: false) }
        }
        .onChange(of: checklist.leadingStep, initial: true) { _, step in
            if selection == nil, let step { selection = step.checkID }
        }
    }
}

/// Aktionen der aufgeklappten Zeile: „Beim Anmelden starten“ als Schalter, sonst die angebotene Aktion des Schritts;
/// auch im Onboarding (#554).
struct SetupStepActions: View {
    let item: SetupChecklist.Item
    let model: PrerequisitesModel

    var body: some View {
        DetailActions {
            if item.step == .launchAtLogin {
                Toggle(item.step.title, isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.isChangingLaunchAtLogin)
            }
            if let action = item.action {
                Button(action.title) { Task { await model.perform(action) } }
                    .disabled(!model.canPerform(action))
            }
        }
    }

    /// Eingeschaltet, sobald die App registriert ist – auch wenn sie noch erlaubt werden muss.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin?.isRegistered ?? false },
            set: { enabled in Task { await model.setLaunchAtLogin(enabled) } }
        )
    }
}

extension SetupStep {
    /// Kennung der Prüfzeile (Auswahl und UI-Tests).
    var checkID: String { "setup.\(rawValue)" }

    /// Symbol der Prüfzeile.
    var symbol: String {
        switch self {
        case .fullDiskAccess: "lock.shield"
        case .helper: "wrench.and.screwdriver"
        case .notifications: "bell"
        case .launchAtLogin: "power"
        }
    }
}

extension SetupChecklist.Item {
    /// Prüfzeile: Grund in einem Satz, Zustand kurz als Chip; aufgeklappt der Rest der Erklärung und ein verkürzter
    /// Zustand im vollen Wortlaut. Ungeprüfte Schritte stehen neutral.
    var checkItem: CheckItem {
        CheckItem(id: step.checkID, symbol: step.symbol, title: step.title, reason: step.reason,
                  status: StatusItem(chipText, tone: tone?.statusTone ?? .neutral),
                  explanation: step.furtherExplanation, details: detailText.map { [$0] } ?? [])
    }
}
