import SwiftUI

/// Pfadstufen der Ordnerleiter (Spec 2026-11-08 § 5.4): jede Stufe ein Knopf zurück, die letzte ist der Ort, an dem man
/// steht (fett, kein Knopf). Lange Pfade zeigen die erste und die letzten Stufen, dazwischen „…“.
public struct PathSteps: View {
    public struct Step: Identifiable, Hashable, Sendable {
        /// Tiefe ab der Wurzel (0); zugleich Ziel des Knopfs.
        public let id: Int
        public let title: String

        public init(id: Int, title: String) {
            self.id = id
            self.title = title
        }
    }

    static let maximumVisible = 4

    let steps: [Step]
    let onSelect: (Int) -> Void

    @Environment(\.self) private var environment

    public init(steps: [Step], onSelect: @escaping (Int) -> Void) {
        self.steps = steps
        self.onSelect = onSelect
    }

    /// Sichtbare Stufen; `nil` steht für die ausgelassenen.
    nonisolated static func visible(_ steps: [Step]) -> [Step?] {
        guard steps.count > maximumVisible else { return steps }
        return [steps[0], nil] + steps.suffix(maximumVisible - 1)
    }

    public var body: some View {
        let link = environment.statusTextColor(.info)
        HStack(spacing: InstrumentSpacing.inline) {
            // Höchstens eine Auslassung (`nil`), daher eindeutig.
            ForEach(Self.visible(steps), id: \.self) { step in
                if step?.id != steps.first?.id {
                    Image(systemName: "chevron.right")
                        .font(InstrumentFont.micro.weight(.semibold))
                        .foregroundStyle(.instrumentSecondary)
                        .accessibilityHidden(true)
                }
                if let step {
                    if step.id == steps.last?.id {
                        Text(verbatim: step.title).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                    } else {
                        Button { onSelect(step.id) } label: {
                            Text(verbatim: step.title).font(InstrumentFont.body).foregroundStyle(link).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Zurück zu diesem Ordner"))
                        .accessibilityIdentifier("path.step.\(step.id)")
                    }
                } else {
                    Text(verbatim: "…").font(InstrumentFont.body).foregroundStyle(.instrumentSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Pfad"))
    }
}

/// Zeile der Ordnerleiter (Tabellenzeile §3.7, einzeilig): Symbol, Name mit Kategorie-Chip, Spur mit dem Anteil am
/// Elternordner, Größe; Pfeil, wenn sie hinabführt. Nicht Erfasstes in Sekundärfarbe mit Zustandschip.
public struct LadderRow: View {
    public struct Content: Identifiable, Hashable, Sendable {
        public let id: Int
        public let symbol: String
        public let name: String
        public let value: String
        /// Anteil am Elternordner; `nil`: nicht gemessen.
        public let fraction: Double?
        /// Kategorie („Caches“) oder Zustand („nicht erfasst“).
        public let chip: StatusItem?
        public let isDescendable: Bool
        /// Nicht (vollständig) erfasst, Netzlaufwerk oder nur in iCloud: Name und Wert sekundär.
        public let isMuted: Bool
        /// Satz für VoiceOver („Caches, 18,4 GB, 12 % von Library, Kategorie Caches“).
        public let accessibilityLabel: String

        public init(id: Int, symbol: String, name: String, value: String, fraction: Double?, chip: StatusItem?,
                    isDescendable: Bool, isMuted: Bool, accessibilityLabel: String) {
            self.id = id
            self.symbol = symbol
            self.name = name
            self.value = value
            self.fraction = fraction
            self.chip = chip
            self.isDescendable = isDescendable
            self.isMuted = isMuted
            self.accessibilityLabel = accessibilityLabel
        }
    }

    let content: Content
    let hue: InstrumentHue
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.self) private var environment

    public init(_ content: Content, hue: InstrumentHue, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.content = content
        self.hue = hue
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: InstrumentSpacing.cell) {
                Image(systemName: content.symbol)
                    .font(InstrumentFont.rowIcon)
                    .foregroundStyle(.instrumentSecondary)
                    .frame(width: InstrumentSize.rowIcon, height: InstrumentSize.rowIcon)
                    .background(Circle().fill(.primary.opacity(InstrumentOpacity.well)))
                // Der Name hat Vorrang: Reicht die Breite nicht für beide, entfällt der Chip (das Detail nennt ihn).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: InstrumentSpacing.item) {
                        name.fixedSize()
                        if let chip = content.chip { StatusChip(chip, isSmall: true).fixedSize() }
                    }
                    name
                }
                .layoutPriority(1)
                Spacer(minLength: InstrumentSpacing.group)
                Spur(fraction: content.fraction, color: environment.instrumentColor(hue))
                    .frame(width: InstrumentSize.ladderSpur, height: InstrumentSize.spurList)
                Text(verbatim: content.value).font(InstrumentFont.numeric).lineLimit(1)
                    .foregroundStyle(content.isMuted ? .instrumentSecondary : .primary)
                    .frame(width: InstrumentSize.ladderValue, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(InstrumentFont.label.weight(.semibold))
                    .foregroundStyle(.instrumentSecondary)
                    .frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
                    .opacity(content.isDescendable ? 1 : 0)
            }
            .frame(minHeight: InstrumentSize.row)
            .padding(.horizontal, InstrumentSpacing.group)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .instrumentRowBackground(isSelected: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: content.accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(content.isDescendable ? Text("Öffnet den Ordner.") : Text("Zeigt den Eintrag im Detail."))
        .accessibilityIdentifier("ladder.row.\(content.name)")
    }

    private var name: some View {
        Text(verbatim: content.name).font(InstrumentFont.body).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(content.isMuted ? .instrumentSecondary : .primary)
    }
}
