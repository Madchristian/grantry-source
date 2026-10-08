import SwiftUI

/// Leerer Detailbereich „Keine Auswahl“. Füllt den Bereich, damit er mittig steht, auch wenn darüber eine
/// Ergebnis-Meldung (`ActionResultContainer`) eingeblendet ist.
struct NoSelectionView: View {
    let hint: LocalizedStringKey

    var body: some View {
        ContentUnavailableView("Keine Auswahl", systemImage: "sidebar.left", description: Text(hint))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
