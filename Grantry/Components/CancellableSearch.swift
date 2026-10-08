import Observation
import SwiftUI

/// Eine lesende Suche auf Abruf (Reste einer App, Reste gelöschter Apps), die der Nutzer abbrechen kann. Nach einem
/// Abbruch wird das Teilergebnis verworfen – angeboten wird nur, was eine vollständige Suche gefunden hat.
@MainActor
@Observable
final class CancellableSearch {
    enum Phase: Equatable {
        case idle, searching, cancelled, finished
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isSearching: Bool { phase == .searching }

    /// Startet die Suche (eine laufende wird abgebrochen); `onFinish` erhält das Ergebnis nur ohne Abbruch.
    func start<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value, onFinish: @escaping @MainActor (Value) -> Void
    ) {
        task?.cancel()
        phase = .searching
        task = Task { [weak self] in
            let value = await operation()
            guard !Task.isCancelled, let self else { return }
            onFinish(value)
            self.phase = .finished
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .searching { phase = .cancelled }
    }
}

/// Fortschritt mit „Suche abbrechen“ bzw. nach einem Abbruch „Erneut suchen“; leer in den übrigen Phasen.
struct SearchStatusView: View {
    let search: CancellableSearch
    let searchingTitle: LocalizedStringKey
    let retry: () -> Void

    var body: some View {
        switch search.phase {
        case .searching:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(searchingTitle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Suche abbrechen", action: search.cancel)
            }
            .accessibilityElement(children: .contain)
        case .cancelled:
            HStack(spacing: 8) {
                Text("Suche abgebrochen – es wird nichts angeboten.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Erneut suchen", action: retry)
            }
        case .idle, .finished:
            EmptyView()
        }
    }
}
