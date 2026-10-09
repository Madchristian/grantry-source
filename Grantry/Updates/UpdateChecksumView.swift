import AppKit
import ManagerKit
import SwiftUI

/// Optionale manuelle Gegenprobe; nur ein vom Feed gelieferter, gültiger Hash wird angeboten.
struct UpdateChecksumView: View {
    let item: AppcastItem
    @State private var isPresented = false

    var body: some View {
        if let checksum = item.sha256 {
            Button("DMG-Prüfsumme …") { isPresented = true }
                .popover(isPresented: $isPresented) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SHA-256 des DMG")
                            .font(.headline)
                        CodeText(text: checksum, alignment: .leading, font: .callout.monospaced())
                        Button("Prüfsumme kopieren") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(checksum, forType: .string)
                            AccessibilityNotification.Announcement(String(localized: "Prüfsumme kopiert")).post()
                        }
                        CodeText(text: "shasum -a 256 <DMG>", alignment: .leading, font: .callout.monospaced())
                        Text("Im Terminal „<DMG>“ durch den Pfad zur geladenen Datei ersetzen und das Ergebnis vergleichen.")
                        Text("Integritäts-Gegenprobe: Der Hash stammt aus demselben Feed und ist kein unabhängiger Echtheitsnachweis.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .frame(width: 420)
                }
        }
    }
}
