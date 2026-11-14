import SwiftUI

// Vergrößern einer Grafik-Karte auf die ganze Seite (Erreichbarkeit in Netzwerk › Verbindungen, Rechte-Schichten in
// Erweiterungen): Der Knopf steht in der Kopfzeile der Karte (`PeilHead(expansion:)`), `instrumentExpansion` tauscht
// den Inhalt der Seite gegen die vergrößerte Karte. Seitenleiste, Zustandszeile und Tab-Leiste bleiben stehen. Ohne
// Animation und ohne eigenen Takt; solange die Karte vergrößert ist, wird der übrige Inhalt der Seite nicht ausgewertet.

/// Knopf in der Kopfzeile einer Karte: vergrößert sie auf die ganze Seite und stellt sie wieder her. Vergrößert trägt
/// er Escape als Tastenkürzel.
public struct InstrumentExpandButton: View {
    let title: String
    @Binding var isExpanded: Bool

    /// - Parameter title: Name der Karte für VoiceOver, etwa „Erreichbarkeit“.
    public init(_ title: String, isExpanded: Binding<Bool>) {
        self.title = title
        _isExpanded = isExpanded
    }

    /// Symbol je Zustand: Pfeile auseinander zum Vergrößern, zueinander zum Verkleinern.
    static func symbol(isExpanded: Bool) -> String {
        isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }

    /// Tooltip je Zustand.
    static func helpText(isExpanded: Bool) -> String {
        isExpanded ? String(localized: "Verkleinern (esc)") : String(localized: "Auf die ganze Seite vergrößern")
    }

    /// Beschriftung für VoiceOver: „Erreichbarkeit vergrößern“ bzw. „Erreichbarkeit verkleinern“.
    static func spokenLabel(title: String, isExpanded: Bool) -> String {
        isExpanded ? String(localized: "\(title) verkleinern") : String(localized: "\(title) vergrößern")
    }

    public var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: Self.symbol(isExpanded: isExpanded))
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .frame(width: InstrumentSize.rowIcon, height: InstrumentSize.rowIcon)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(isExpanded ? .cancelAction : nil)
        .help(Text(verbatim: Self.helpText(isExpanded: isExpanded)))
        .accessibilityLabel(Text(verbatim: Self.spokenLabel(title: title, isExpanded: isExpanded)))
        .accessibilityIdentifier("instrumentExpandButton")
    }
}

public extension View {
    /// Zeigt statt dieser Ansicht `expanded` auf derselben Fläche, solange `isExpanded` gilt – die vergrößerte Karte
    /// einer Seite. Den Zustand schaltet ein `InstrumentExpandButton` in der Kopfzeile der Karte.
    func instrumentExpansion(isExpanded: Bool, @ViewBuilder expanded: () -> some View) -> some View {
        InstrumentExpansion(isExpanded: isExpanded, content: self, expanded: expanded())
    }
}

private struct InstrumentExpansion<Content: View, Expanded: View>: View {
    let isExpanded: Bool
    let content: Content
    let expanded: Expanded

    var body: some View {
        if isExpanded {
            expanded.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }
}
