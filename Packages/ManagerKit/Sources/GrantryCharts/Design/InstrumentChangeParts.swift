import SwiftUI

// Teile für Listen mit Änderungen (LB-3.3, #545; Entwurf LB-3.1, #543, Spec 2026-11-10 § 11.3 f): aktiver Filter als
// Zeile im Inhalt und ein geänderter Befehl vorher und nachher auf der Mulde. Knöpfe bleiben native Steuerelemente.

/// Aktiver Filter aus der Symbolleiste als Zeile im Inhalt (§ 11.3 f): Symbol, „Gefiltert: …“ und rechts „Filter
/// zurücksetzen“. VoiceOver liest „Filter“ als Beschriftung, die Auswahl als Wert, den Knopf eigen.
public struct ActiveFilterLine: View {
    let text: String
    let reset: () -> Void

    public init(_ text: String, reset: @escaping () -> Void) {
        self.text = text
        self.reset = reset
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.group) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.instrumentSecondary)
                .accessibilityHidden(true)
            Text(verbatim: String(localized: "Gefiltert: \(text)")).font(InstrumentFont.label)
                .accessibilityReading(Text(verbatim: String(localized: "Filter")), value: Text(verbatim: text))
            Spacer(minLength: InstrumentSpacing.group)
            Button(String(localized: "Filter zurücksetzen"), action: reset).buttonStyle(.link).font(InstrumentFont.label)
        }
        .padding(.horizontal, InstrumentSpacing.panel)
    }
}

/// Befehl vor und nach einer Änderung (#137) zum Aufklappen: beide Zeilen auf der Mulde als Schlüssel und Wert in
/// Festbreitenschrift, auswählbar und einzeln kopierbar. Geheimnisse sind bereits maskiert.
public struct CommandChangeWell: View {
    let before: String
    let after: String
    @Binding var isExpanded: Bool
    let copy: (String) -> Void

    public init(before: String, after: String, isExpanded: Binding<Bool>, copy: @escaping (String) -> Void) {
        self.before = before
        self.after = after
        _isExpanded = isExpanded
        self.copy = copy
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                line(String(localized: "Vorher"), copyLabel: String(localized: "Befehl vorher kopieren"), command: before)
                line(String(localized: "Nachher"), copyLabel: String(localized: "Befehl nachher kopieren"), command: after)
            }
            .padding(InstrumentSpacing.group)
            .background(RoundedRectangle(cornerRadius: InstrumentRadius.block, style: .continuous)
                .fill(.primary.opacity(InstrumentOpacity.well)))
        } label: {
            Text(verbatim: String(localized: "Befehl vorher und nachher")).font(InstrumentFont.label)
        }
    }

    private func line(_ title: String, copyLabel: String, command: String) -> some View {
        HStack(spacing: InstrumentSpacing.group) {
            DetailEntry(title, value: command) {
                Text(verbatim: command).font(InstrumentFont.code).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(String(localized: "Kopieren")) { copy(command) }
                .controlSize(.small)
                .accessibilityLabel(Text(verbatim: copyLabel))
        }
    }
}
