import SwiftUI

/// Dateipfad: auswählbar, in der Mitte gekürzt.
struct PathText: View {
    let path: String

    var body: some View {
        Text(verbatim: path)
            .textSelection(.enabled)
            .truncationMode(.middle)
            .lineLimit(2)
    }
}
