import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

/// Optionale manuelle Gegenprobe; nur ein vom Feed gelieferter, gültiger Hash wird angeboten. Popover im Lagebild
/// (LB-5.3, #554): Textstile und Abstände aus den Tokens, Hinweis sekundär.
struct UpdateChecksumView: View {
    let item: AppcastItem
    @State private var isPresented = false

    var body: some View {
        if let checksum = item.sha256 {
            Button("DMG-Prüfsumme …") { isPresented = true }
                .popover(isPresented: $isPresented) {
                    VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
                        Text("SHA-256 des DMG")
                            .font(InstrumentFont.body.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        CodeText(text: checksum, alignment: .leading)
                        Button("Prüfsumme kopieren") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(checksum, forType: .string)
                            AccessibilityNotification.Announcement(String(localized: "Prüfsumme kopiert")).post()
                        }
                        CodeText(text: "shasum -a 256 <DMG>", alignment: .leading)
                        Text("Im Terminal „<DMG>“ durch den Pfad zur geladenen Datei ersetzen und das Ergebnis vergleichen.")
                        Text("Integritäts-Gegenprobe: Der Hash stammt aus demselben Feed und ist kein unabhängiger Echtheitsnachweis.")
                            .foregroundStyle(.instrumentSecondary)
                    }
                    .font(InstrumentFont.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(InstrumentSpacing.page)
                    .frame(width: UpdateChecksumLayout.width)
                }
        }
    }
}

/// Breite des Popovers wie bisher.
private enum UpdateChecksumLayout {
    static let width: CGFloat = 420
}
