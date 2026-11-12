import SwiftUI

// Auswahl zum Ankreuzen (LB-1.2, #536; Spec 2026-11-10 §4.2, §11.1 d): Häkchenzeile für Aufräumen, App entfernen und
// Beobachtungen. Ersetzt `SelectionToggleRow` und `Toggle` in Listen.

/// Häkchen im Grantry-Verlauf statt der Systemakzentfarbe (weiße Marke nur auf `brand.fill`); leer mit Rand in
/// Sekundärfarbe (≥ 3 : 1). Dekorativ, die Zeile liest den Zustand.
public struct InstrumentCheckBox: View {
    let isOn: Bool

    public init(isOn: Bool) {
        self.isOn = isOn
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: InstrumentRadius.graph, style: .continuous)
        ZStack {
            if isOn {
                shape.fill(GrantryBrand.fill)
                Image(systemName: "checkmark").font(InstrumentFont.micro.weight(.bold)).foregroundStyle(.white)
            } else {
                shape.strokeBorder(.instrumentSecondary, lineWidth: InstrumentStroke.focus)
            }
        }
        .frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
        .accessibilityHidden(true)
    }
}

/// Zeile zum Ankreuzen: Häkchen, Name und Ort, Hinweis als kleiner Chip, rechts die Größe. Gesperrt steht ein Schloss
/// statt des Häkchens und der Grund statt des Orts; ein Klick ändert dann nichts. Für VoiceOver ein Schalter mit dem Namen
/// als Beschriftung und Zustand, Hinweis, Größe und Ort als Wert. Der Zustand kommt gebunden herein; die Vorauswahl
/// bleibt Sache des Modells.
public struct SelectionCheckRow: View {
    let title: String
    let detail: String
    let size: String
    @Binding var isOn: Bool
    let hint: StatusItem?
    let lockedReason: String?

    public init(_ title: String, detail: String, size: String, isOn: Binding<Bool>, hint: StatusItem? = nil,
                lockedReason: String? = nil) {
        self.title = title
        self.detail = detail
        self.size = size
        _isOn = isOn
        self.hint = hint
        self.lockedReason = lockedReason
    }

    public var body: some View {
        Button(action: toggle) {
            HStack(spacing: InstrumentSpacing.cell) {
                if lockedReason != nil {
                    Image(systemName: "lock").font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        .frame(width: InstrumentSize.disclosure, height: InstrumentSize.disclosure)
                } else {
                    InstrumentCheckBox(isOn: isOn)
                }
                VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                    Text(verbatim: title).font(InstrumentFont.body).lineLimit(1)
                    Text(verbatim: lockedReason ?? detail).font(InstrumentFont.label)
                        .foregroundStyle(.instrumentSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: InstrumentSpacing.group)
                if let hint { StatusChip(hint, isSmall: true) }
                Text(verbatim: size).font(InstrumentFont.numeric).foregroundStyle(.instrumentSecondary)
            }
            .padding(.horizontal, InstrumentSpacing.group)
            .padding(.vertical, InstrumentSpacing.item)
            .contentShape(Rectangle())
        }
        // Gesperrt nicht `disabled`: das blasste Name und Größe aus; der Grund steht sichtbar daneben.
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        // ax-value: Knopf mit Merkmal Schalter, behält seine Rolle und damit den Wert.
        .accessibilityValue(Text(verbatim: Self.spokenValue(isOn: isOn, detail: detail, size: size, hint: hint,
                                                            lockedReason: lockedReason)))
        .accessibilityAddTraits(lockedReason == nil ? .isToggle : [])
    }

    private func toggle() {
        guard lockedReason == nil else { return }
        isOn.toggle()
    }

    /// Wert für VoiceOver: „ausgewählt, Hinweis, Größe, Ort“; gesperrt „gesperrt: Grund, Größe“.
    nonisolated static func spokenValue(isOn: Bool, detail: String, size: String, hint: StatusItem?,
                                        lockedReason: String?) -> String {
        if let lockedReason {
            return "\(String(localized: "gesperrt")): \(lockedReason), \(size)"
        }
        let state = isOn ? String(localized: "ausgewählt") : String(localized: "nicht ausgewählt")
        return [state, hint?.text, size, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Scan-Fortschritt oder Abdeckung als Spur (§3.5) mit Titel und Detail darüber, rechts auf Wunsch ein Knopf;
/// `fraction == nil` heißt „Dauer noch unbekannt“: leere Bahn, kein Lauflicht. Ersetzt `ScanProgressView`,
/// `SegmentScanProgress` und die Leiste von `AreaCoverageBar`. Zeichnet nur bei neuem Wert. VoiceOver liest den Titel
/// als Beschriftung, Anteil und Detail als Wert.
public struct ProgressSpur<Trailing: View>: View {
    let title: String
    let detail: String
    let fraction: Double?
    let tone: StatusTone
    let trailing: Trailing

    @Environment(\.self) private var environment

    public init(title: String, detail: String, fraction: Double?, tone: StatusTone,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.fraction = fraction
        self.tone = tone
        self.trailing = trailing()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.group) {
                HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.group) {
                    Text(verbatim: title).font(InstrumentFont.body.weight(.semibold))
                    Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        .lineLimit(1)
                }
                .accessibilityReading(Text(verbatim: title),
                                      value: Text(verbatim: Self.spokenValue(fraction: fraction, detail: detail)))
                Spacer(minLength: InstrumentSpacing.group)
                trailing
            }
            Spur(fraction: fraction, color: environment.statusColor(tone))
                .frame(height: InstrumentSize.spurList)
        }
        .accessibilityElement(children: .contain)
    }

    /// „42 %, Detail“; ohne Anteil nur das Detail.
    nonisolated static func spokenValue(fraction: Double?, detail: String) -> String {
        let share = fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }
        return [share, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

extension ProgressSpur where Trailing == EmptyView {
    public init(title: String, detail: String, fraction: Double?, tone: StatusTone) {
        self.init(title: title, detail: detail, fraction: fraction, tone: tone) { EmptyView() }
    }
}
