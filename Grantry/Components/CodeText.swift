import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

/// Befehl oder URL in Festbreitenschrift, auswählbar und umbrechend; in `LabeledContent` rechtsbündig.
struct CodeText: View {
    let text: String
    var alignment: TextAlignment = .trailing
    var font: Font = InstrumentFont.code

    var body: some View {
        Text(verbatim: text)
            .font(font)
            .textSelection(.enabled)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Kopiert einen Befehl in die Zwischenablage und kündigt das für VoiceOver an.
enum CommandClipboard {
    static func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        AccessibilityNotification.Announcement(String(localized: "Befehl kopiert")).post()
    }
}

/// Knopf, der einen Befehl kopiert (`CommandClipboard`).
struct CopyCommandButton: View {
    let command: String
    var title: LocalizedStringKey = "Befehl kopieren"

    var body: some View {
        Button(title) { CommandClipboard.copy(command) }
    }
}

/// Befehl vor und nach einer Änderung (#137) zum Aufklappen, im Lagebild auf der Mulde (`CommandChangeWell`, LB-3.3):
/// beide Zeilen auswählbar und einzeln kopierbar. Geheimnisse sind bereits maskiert (`CommandChange`).
struct CommandChangeDisclosure: View {
    let change: CommandChange
    @State private var isExpanded = false

    var body: some View {
        CommandChangeWell(before: change.before, after: change.after, isExpanded: $isExpanded,
                          copy: CommandClipboard.copy)
    }
}
