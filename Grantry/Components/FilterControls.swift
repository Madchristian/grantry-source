import SwiftUI

/// Filtermenü der Symbolleiste: die Auswahl aus `content`, darunter „Filter zurücksetzen“; das Symbol zeigt, ob ein
/// Filter aktiv ist. Gemeinsam für Listen und Verlauf.
struct FilterMenu<Content: View>: View {
    let isActive: Bool
    let help: LocalizedStringKey
    let reset: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
            Divider()
            Button("Filter zurücksetzen", action: reset)
                .disabled(!isActive)
        } label: {
            Label("Filter", systemImage: isActive
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help(help)
    }
}

/// Leerer Zustand, wenn nichts zu den Filtern passt – mit „Filter zurücksetzen“.
struct NoFilterMatchesView: View {
    let description: LocalizedStringKey
    let reset: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Keine Treffer", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(description)
        } actions: {
            Button("Filter zurücksetzen", action: reset)
        }
    }
}
