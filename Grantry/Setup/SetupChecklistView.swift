import AppKit
import ManagerKit
import SwiftUI

/// Checkliste der Einrichtung mit Zustand und Aktion je Schritt – gemeinsam für Onboarding und Einstellungen.
/// Solange sie sichtbar ist, wird der Festplattenvollzugriff alle 2 s geprüft und bei der Rückkehr in die App
/// (etwa aus den Systemeinstellungen) alles erneut.
struct SetupChecklistView<Trailing: View>: View {
    let model: PrerequisitesModel
    /// Schritte nummerieren (Onboarding).
    var numbered = false
    /// Weitere Zeilen am Ende der Liste (z. B. der erste Scan im Onboarding).
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let items = model.checklist.items
        Form {
            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    SetupStepRow(item: item, number: numbered ? index + 1 : nil, model: model)
                }
                trailing()
            } footer: {
                if let error = model.setupErrorText {
                    StatusLabel(.failed(error))
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.pollFullDiskAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh(showsProgress: false) }
        }
    }
}

extension SetupChecklistView where Trailing == EmptyView {
    init(model: PrerequisitesModel, numbered: Bool = false) {
        self.init(model: model, numbered: numbered) { EmptyView() }
    }
}

/// Ein Schritt: Titel, Zweck, Zustand und die passende Aktion („Beim Anmelden starten“ als Schalter).
struct SetupStepRow: View {
    let item: SetupChecklist.Item
    let number: Int?
    let model: PrerequisitesModel

    var body: some View {
        SetupRowLayout(number: number, title: item.step.title, explanation: item.step.explanation, status: status) {
            if item.step == .launchAtLogin {
                Toggle(item.step.title, isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.isChangingLaunchAtLogin)
            }
            if let action = item.action {
                Button(action.title) { Task { await model.perform(action) } }
                    .disabled(!model.canPerform(action))
            }
        }
    }

    private var status: StatusLabel.Status {
        item.tone.map { .toned($0, item.text) } ?? .loading(item.text)
    }

    /// Eingeschaltet, sobald die App registriert ist – auch wenn sie noch erlaubt werden muss.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin?.isRegistered ?? false },
            set: { enabled in Task { await model.setLaunchAtLogin(enabled) } }
        )
    }
}

/// Aufbau einer Zeile der Checkliste: optionale Nummer, Titel mit Zweck und Zustand, rechts die Bedienelemente.
struct SetupRowLayout<Controls: View>: View {
    let number: Int?
    let title: String
    let explanation: String
    let status: StatusLabel.Status
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let number {
                Text(number, format: .number)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: .circle)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                StatusLabel(status)
                    .font(.callout)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            controls()
        }
        .padding(.vertical, 4)
    }
}
