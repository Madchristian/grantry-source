import AppKit
import ManagerKit
import SwiftUI

/// Befehl oder URL in Festbreitenschrift, auswählbar und umbrechend; in `LabeledContent` rechtsbündig.
struct CodeText: View {
    let text: String
    var alignment: TextAlignment = .trailing
    var font: Font = .body.monospaced()

    var body: some View {
        Text(verbatim: text)
            .font(font)
            .textSelection(.enabled)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Kopiert einen Befehl in die Zwischenablage und kündigt das für VoiceOver an.
struct CopyCommandButton: View {
    let command: String
    var title: LocalizedStringKey = "Befehl kopieren"

    var body: some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            AccessibilityNotification.Announcement(String(localized: "Befehl kopiert")).post()
        }
    }
}

/// Befehl vor und nach einer Änderung (#137): aufklappbar, beide Zeilen auswählbar und einzeln kopierbar. Geheimnisse
/// sind bereits maskiert (`CommandChange`).
struct CommandChangeDisclosure: View {
    let change: CommandChange

    var body: some View {
        DisclosureGroup("Befehl vorher/nachher") {
            VStack(alignment: .leading, spacing: 8) {
                line(title: "Vorher", copyLabel: "Befehl vorher kopieren", command: change.before)
                line(title: "Nachher", copyLabel: "Befehl nachher kopieren", command: change.after)
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private func line(title: LocalizedStringKey, copyLabel: LocalizedStringKey, command: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                CopyCommandButton(command: command, title: "Kopieren")
                    .controlSize(.small)
                    .accessibilityLabel(Text(copyLabel))
            }
            CodeText(text: command, alignment: .leading, font: .callout.monospaced())
        }
    }
}
