import GrantryCharts
import ManagerKit
import SwiftUI

/// Blatt „Installation beobachten“ (#127) im Lagebild (LB-3.4, #546, Spec §11.3 h): Name (Pflicht) und Notiz;
/// „Beobachtung starten“ erfasst sofort den Ausgangsstand. Konnte der Scan Quellen nicht lesen, fragt das Blatt nach („Trotzdem starten“).
struct ObservationStartSheet: View {
    let observations: ObservationModel
    var scanProgress = ScanProgress()
    /// Nach erfolgreichem Start mit der ID der neuen Beobachtung.
    let onStarted: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    /// Laufender Start; „Abbrechen“ bricht ihn samt Ausgangs-Scan ab.
    @State private var startTask: Task<Void, Never>?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ObservationStartForm(
            name: $name, note: $note, notes: notes, isBusy: observations.isBusy,
            canStart: !trimmedName.isEmpty && !observations.isBusy && observations.active == nil && observations.isAvailable,
            cancel: cancel, start: start
        ) {
            if observations.phase == .starting {
                ScanProgressText(progress: scanProgress) { text in
                    ProgressSpur(title: String(localized: "Ausgangsstand wird erfasst …"), detail: text,
                                 fraction: scanProgress.isIndeterminate ? nil : scanProgress.fraction, tone: .info)
                }
            }
        }
        .frame(width: 480)
        .instrumentBackground()
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

    /// Hinweise im Blatt: laufende Beobachtung (Befund) und Fehler (wie bisher als Hinweis).
    private var notes: [DetailNoteContent] {
        var notes: [DetailNoteContent] = []
        if let active = observations.active {
            notes.append(DetailNoteContent(String(localized: "Die Beobachtung „\(active.name)“ läuft bereits – es kann nur eine gleichzeitig laufen."),
                                           kind: .finding))
        }
        if let error = observations.errorMessage { notes.append(DetailNoteContent(error, kind: .critical)) }
        return notes
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
