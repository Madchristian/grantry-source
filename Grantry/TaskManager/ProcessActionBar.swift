import GrantryCharts
import ManagerKit
import SwiftUI

/// Leiste unter der Prozesstabelle (Spec §2): Hinweis bzw. Grund der Sperre, „Priorität“ (TM-9.3), „Task beenden“ (⌫)
/// und „Sofort beenden“ (⌥⌫). Die Tasten wirken über `onKeyPress` nur in der Tabelle, nicht als Tastenkürzel – sonst
/// löschte ⌫ im Suchfeld keinen Text mehr. Bei Prozessen anderer Benutzer zeigt ein Schild, dass macOS nach dem
/// Administratorkennwort fragt.
struct ProcessActionBar: View {
    let candidate: TaskTerminationCandidate?
    /// Gesperrt, etwa für Zeilen mit mehreren Prozessen anderer Benutzer.
    let disabledReason: String?
    let notice: String?
    let canStart: Bool
    let forceOffer: TaskTerminationRequest?
    /// Ob die Auswahl Prozesse anderer Benutzer enthält (Aktionen mit Admin-Bestätigung).
    var needsAdmin = false
    /// Aktuelle Stufe des gewählten Prozesses; `nil`, wenn nicht lesbar oder mehrere Prozesse.
    var priority: ProcessPriority?
    let prepare: (_ force: Bool) -> Void
    let offerForce: () -> Void
    var setPriority: (ProcessPriority) -> Void = { _ in }

    private var isEnabled: Bool { candidate != nil && canStart }

    /// Die Priorität gilt je Prozess; eine App mit mehreren Prozessen muss erst aufgeklappt werden.
    private var canSetPriority: Bool { isEnabled && candidate?.keys.count == 1 }

    private var priorityTitle: LocalizedStringKey {
        priority.map { "Priorität: \($0.title)" } ?? "Priorität"
    }

    var body: some View {
        HStack(spacing: InstrumentSpacing.cell) {
            if let message = notice ?? disabledReason {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.instrumentSecondary)
                    .lineLimit(2)
            } else if needsAdmin, candidate != nil {
                Label("Prozess eines anderen Benutzers – macOS fragt je Aktion nach dem Administratorkennwort.",
                      systemImage: "lock.shield")
                    .foregroundStyle(.instrumentSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: InstrumentSpacing.group)
            if let forceOffer {
                Button("„\(forceOffer.name)“ sofort beenden …", action: offerForce)
                    .disabled(!canStart)
            }
            Menu {
                ForEach(ProcessPriority.allCases, id: \.self) { level in
                    Button {
                        setPriority(level)
                    } label: {
                        if level == priority { Label(level.title, systemImage: "checkmark") } else { Text(level.title) }
                    }
                }
            } label: {
                Label(priorityTitle, systemImage: needsAdmin ? "lock.shield" : "dial.medium")
            }
            .fixedSize()
            .help("Priorität (nice) des Prozesses ändern")
            .disabled(!canSetPriority)
            Button("Sofort beenden") { prepare(true) }
                .help("Sofort beenden (SIGKILL) – ⌥⌫")
                .disabled(!isEnabled)
            terminateButton
        }
        .controlSize(.regular)
        .instrumentBar()
    }

    /// Hervorgehoben nur, solange er wirkt: Ein gesperrter, aber blau gefüllter Knopf sah im aktiven Fenster bedienbar
    /// aus (Bewertung 2026.11.7, Mangel 13).
    @ViewBuilder
    private var terminateButton: some View {
        let button = Button("Task beenden") { prepare(false) }.help("Task beenden – ⌫")
        if isEnabled {
            button.buttonStyle(.borderedProminent)
        } else {
            button.disabled(true)
        }
    }
}

#if DEBUG
#Preview("Aktionsleiste") {
    ProcessActionBar(candidate: TaskTerminationCandidate(name: "Xcode", keys: []), disabledReason: nil, notice: nil,
                     canStart: true, forceOffer: nil, prepare: { _ in }, offerForce: {})
        .frame(width: 900)
}

#Preview("Fremder Prozess") {
    ProcessActionBar(candidate: TaskTerminationCandidate(name: "agent", keys: [ProcessKey(pid: 4242, startTime: 1)]),
                     disabledReason: nil, notice: nil, canStart: true, forceOffer: nil, needsAdmin: true,
                     priority: .normal, prepare: { _ in }, offerForce: {})
        .frame(width: 900)
}
#endif
