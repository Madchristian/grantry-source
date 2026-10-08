import ManagerKit
import SwiftUI

/// Blatt „Installation beobachten“ (#127): Name (Pflicht) und Notiz; „Beobachtung starten“ erfasst sofort den
/// Ausgangsstand. Konnte der Scan Quellen nicht lesen, fragt das Blatt nach („Trotzdem starten“).
struct ObservationStartSheet: View {
    let observations: ObservationModel
    /// Nach erfolgreichem Start mit der ID der neuen Beobachtung.
    let onStarted: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    /// Laufender Start; „Abbrechen“ bricht ihn samt Ausgangs-Scan ab.
    @State private var startTask: Task<Void, Never>?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var observations = observations
        VStack(alignment: .leading, spacing: 16) {
            Text("Installation beobachten")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Grantry hält jetzt fest, was auf dem Mac eingerichtet ist. Installiere danach das Tool und starte es einmal; beim Beenden der Beobachtung zeigt Grantry, was seitdem hinzugekommen ist – und räumt es auf Wunsch wieder auf.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("z. B. Cursor"))
                TextField("Notiz (optional)", text: $note, axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.grouped)
            .disabled(observations.isBusy)
            if let active = observations.active {
                NoticeList(notices: [String(localized: "Die Beobachtung „\(active.name)“ läuft bereits – es kann nur eine gleichzeitig laufen.")])
            }
            if let error = observations.errorMessage {
                NoticeList(notices: [error])
            }
            HStack {
                if observations.phase == .starting {
                    ProgressView().controlSize(.small)
                    Text("Ausgangsstand wird erfasst …").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Beobachtung starten") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || observations.isBusy || observations.active != nil
                              || !observations.isAvailable)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { observations.errorMessage = nil }
        // Schließt das Blatt auf anderem Weg, gilt das wie „Abbrechen“: kein Start, keine hängende Rückfrage.
        .onDisappear {
            startTask?.cancel()
            observations.pendingStart = nil
        }
        .alert(
            "Ausgangsstand unvollständig",
            isPresented: Binding(get: { observations.pendingStart != nil }, set: { if !$0 { observations.pendingStart = nil } }),
            presenting: observations.pendingStart
        ) { pending in
            Button("Trotzdem starten") {
                Task {
                    await observations.confirmStart(pending)
                    finishIfStarted()
                }
            }
            Button("Abbrechen", role: .cancel) { observations.pendingStart = nil }
        } message: { pending in
            Text(verbatim: ObservationTexts.incompleteStartMessage(pending.baseline.failedSources.sorted { $0.rawValue < $1.rawValue }
                .map(\.displayName)))
        }
    }

    private func start() {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        startTask = Task {
            await observations.start(name: trimmedName, note: note.isEmpty ? nil : note)
            guard !Task.isCancelled else { return }
            finishIfStarted()
        }
    }

    /// Bricht einen laufenden Ausgangs-Scan ab und verwirft eine offene Rückfrage.
    private func cancel() {
        startTask?.cancel()
        observations.pendingStart = nil
        dismiss()
    }

    /// Schließt das Blatt, sobald die Beobachtung läuft.
    private func finishIfStarted() {
        guard let active = observations.active, observations.pendingStart == nil else { return }
        dismiss()
        onStarted(active.id)
    }
}
