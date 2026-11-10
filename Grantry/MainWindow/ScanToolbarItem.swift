import SwiftUI

/// „Jetzt scannen“ als schlichter Aktualisieren-Button, während eines Vollscans gesperrt. Den Fortschritt zeigt die
/// Leiste über dem Inhalt (`ScanProgressStrip`, #262), nicht der Button.
struct ScanToolbarItem: ToolbarContent {
    let isEnabled: Bool
    var pendingSignatureChecks = 0
    var signatureChecksTimedOut = false
    let action: () -> Void

    private var signatureStatus: String? {
        if pendingSignatureChecks > 0 {
            return String(localized: "Signaturen: \(pendingSignatureChecks) offen")
        }
        if signatureChecksTimedOut { return String(localized: "Prüfung unvollständig") }
        return nil
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: action) {
                Label {
                    if let signatureStatus {
                        Text(verbatim: signatureStatus)
                    } else {
                        Text("Jetzt scannen")
                    }
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
                    .frame(width: 180)
            }
            .disabled(!isEnabled)
            .accessibilityLabel("Jetzt scannen")
            // ax-value: Knopf, behält seine Rolle und damit den Wert
            .accessibilityValue(!isEnabled ? "Scan läuft" : signatureStatus ?? "Bereit")
            .accessibilityIdentifier("scanToolbarControl")
            .help(!isEnabled ? "Scan läuft" : signatureStatus != nil
                ? "Inventarscan beendet; Signaturprüfung läuft oder ist unvollständig. Erneut scannen ist möglich." : "Jetzt scannen")
        }
    }
}

extension View {
    /// Titel, Untertitel und Symbolleiste des Hauptfensters – gemeinsam für `RootView` und die Fensterprüfung
    /// (`window_layout_check.swift`), damit sie das Fenster samt Symbolleiste wie in der App nachbildet.
    func mainWindowChrome(title: String, subtitle: String, scan: ScanToolbarItem) -> some View {
        navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar { scan }
    }
}

#Preview("Toolbar – bereit") {
    NavigationStack {
        Text("Inhalt").frame(width: 600, height: 200)
            .toolbar { ScanToolbarItem(isEnabled: true) {} }
    }
}

#Preview("Toolbar – Scan läuft") {
    NavigationStack {
        Text("Inhalt").frame(width: 600, height: 200)
            .toolbar { ScanToolbarItem(isEnabled: false) {} }
    }
}
