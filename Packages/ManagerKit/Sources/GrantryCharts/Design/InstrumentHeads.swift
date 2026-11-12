import SwiftUI

/// Peilring (§3.3): Bahn, Bogen mit dem Anteil und Mittelpunkt in der Farbe der Messgröße – das Radar-Motiv des
/// App-Symbols. Dekorativ; den Wert liest VoiceOver am Kopf oder an der Karte.
public struct PeilRing: View {
    let fraction: Double?
    let hue: InstrumentHue?
    let fixedColor: Color?

    @Environment(\.self) private var environment

    public init(fraction: Double?, hue: InstrumentHue) {
        self.fraction = fraction.map { min(max($0.isFinite ? $0 : 0, 0), 1) }
        self.hue = hue
        fixedColor = nil
    }

    /// Ring in einer Farbe ohne Messgröße, etwa eines Benutzers oder der Sammelzeile.
    public init(fraction: Double?, color: Color) {
        self.fraction = fraction.map { min(max($0.isFinite ? $0 : 0, 0), 1) }
        hue = nil
        fixedColor = color
    }

    public var body: some View {
        let color = fixedColor ?? hue.map(environment.instrumentColor) ?? .instrumentSecondary
        let width = InstrumentStroke.ring
        ZStack {
            Circle().stroke(color.opacity(InstrumentOpacity.track), lineWidth: width)
            Circle()
                .trim(from: 0, to: fraction ?? 0)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle().fill(color).frame(width: width + 2, height: width + 2)
        }
        .padding(width / 2)
        .accessibilityHidden(true)
    }
}

/// Peilkopf (§3.3): Peilring, Titel mit Detailzeile, rechts der Wert in SF Rounded und Textfarbe; ein offener Befund
/// setzt den Befund-Punkt vor den Wert. Der Titel bleibt ein eigenes Textelement mit Kennung (UI-Tests), als Überschrift.
public struct PeilHead: View {
    let title: String
    let detail: String
    let value: String
    let hue: InstrumentHue?
    let fraction: Double?
    let finding: Bool
    let identifier: String?

    @Environment(\.self) private var environment

    /// - Parameter identifier: Bedienungshilfen-Kennung des Titels (UI-Tests); sonst der Titel.
    public init(_ title: String, detail: String = "", value: String = "", hue: InstrumentHue? = nil,
                fraction: Double? = nil, finding: Bool = false, identifier: String? = nil) {
        self.title = title
        self.detail = detail
        self.value = value
        self.hue = hue
        self.fraction = fraction
        self.finding = finding
        self.identifier = identifier
    }

    public var body: some View {
        HStack(alignment: .center, spacing: InstrumentSpacing.cell) {
            if let hue {
                PeilRing(fraction: fraction, hue: hue).frame(width: InstrumentSize.peilRing, height: InstrumentSize.peilRing)
            }
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title)
                    .font(InstrumentFont.title)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(identifier ?? title)
                if !detail.isEmpty {
                    Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: InstrumentSpacing.group)
            if finding { FindingDot() }
            if !value.isEmpty {
                Text(verbatim: value)
                    .font(InstrumentFont.valueLarge)
                    .foregroundStyle(hue.map(environment.instrumentTextColor) ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

/// Befund-Punkt in Bernstein mit Ring in Panelfarbe, wie im App-Symbol (§2.4).
public struct FindingDot: View {
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat = InstrumentSize.findingDot) {
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(GrantryBrand.amber(colorScheme))
            .frame(width: size, height: size)
            .padding(InstrumentSpacing.stack)
            .background(Circle().fill(InstrumentSurface.panel(colorScheme)))
            .accessibilityElement()
            .accessibilityLabel(Text("auffällig"))
    }
}

/// Form des Zustandsschilds (§3.10, Spec 2026-11-10 § 11.3 c): Häkchen nur beim Urteil „ruhig“, Ausrufezeichen mit
/// Bernstein-Punkt beim Befund, ohne Zeichen („offen“) für Zustände ohne Urteil – noch nicht geprüft, unvollständig
/// geprüft, nicht lesbar, noch nicht gesucht –, damit nichts wie eine Entwarnung wirkt.
public enum ShieldForm: Hashable, Sendable {
    case calm, finding, open

    public init(finding: Bool) {
        self = finding ? .finding : .calm
    }

    var symbolName: String {
        switch self {
        case .calm: "checkmark.shield.fill"
        case .finding: "exclamationmark.shield.fill"
        case .open: "shield.fill"
        }
    }

    var showsFindingDot: Bool { self == .finding }
}

/// Zustandsschild (§3.10): Kreis im Grantry-Verlauf mit weißem Schild in einer der drei Formen; beim Befund der
/// Bernstein-Punkt oben rechts. Dekorativ, das Urteil daneben sagt den Zustand.
public struct ShieldBadge: View {
    let form: ShieldForm
    let size: CGFloat

    public init(form: ShieldForm, size: CGFloat = InstrumentSize.shield) {
        self.form = form
        self.size = size
    }

    public init(finding: Bool, size: CGFloat = InstrumentSize.shield) {
        self.init(form: ShieldForm(finding: finding), size: size)
    }

    public var body: some View {
        Image(systemName: form.symbolName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(GrantryBrand.fill))
            .overlay(alignment: .topTrailing) {
                if form.showsFindingDot {
                    FindingDot(size: max(size * 0.22, 5)).offset(x: size * 0.08, y: -size * 0.08)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Zustand in Text und Ton für Chips der Lage- und Zustandszeile, Zeilen und Details.
public struct StatusItem: Hashable, Sendable {
    public let text: String
    public let tone: StatusTone

    public init(_ text: String, tone: StatusTone) {
        self.text = text
        self.tone = tone
    }
}

/// Zustandschip (§3.8): Punkt im Ton (bei `finding` der Befund-Punkt) und Text auf getönter Kapsel; klein ohne Punkt.
public struct StatusChip: View {
    let item: StatusItem
    let isSmall: Bool

    @Environment(\.self) private var environment

    public init(_ item: StatusItem, isSmall: Bool = false) {
        self.item = item
        self.isSmall = isSmall
    }

    public init(_ text: String, tone: StatusTone, isSmall: Bool = false) {
        self.init(StatusItem(text, tone: tone), isSmall: isSmall)
    }

    public var body: some View {
        let color = environment.statusColor(item.tone)
        HStack(spacing: InstrumentSpacing.inline) {
            if !isSmall {
                if item.tone == .finding {
                    FindingDot(size: InstrumentSize.findingDotSmall)
                } else {
                    Circle().fill(color).frame(width: InstrumentSize.statusDot, height: InstrumentSize.statusDot)
                }
            }
            Text(verbatim: item.text)
                .font(isSmall ? InstrumentFont.micro.weight(.semibold) : InstrumentFont.label.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, isSmall ? InstrumentSpacing.item : InstrumentSpacing.group)
        .padding(.vertical, isSmall ? 1 : 3)
        .background(Capsule().fill(color.opacity(InstrumentOpacity.chip)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.text))
    }
}

/// Lagezeile der Übersicht (§3.10): Schild, Urteil, Grund in einem Satz; rechts Zustandschips und Kenndaten.
public struct VerdictBar: View {
    let verdict: String
    let reason: String
    let shield: ShieldForm
    let items: [StatusItem]
    let facts: String

    public init(verdict: String, reason: String, shield: ShieldForm, items: [StatusItem], facts: String) {
        self.verdict = verdict
        self.reason = reason
        self.shield = shield
        self.items = items
        self.facts = facts
    }

    public init(verdict: String, reason: String, finding: Bool, items: [StatusItem], facts: String) {
        self.init(verdict: verdict, reason: reason, shield: ShieldForm(finding: finding), items: items, facts: facts)
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.page) {
            ShieldBadge(form: shield)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: verdict).font(InstrumentFont.verdict).accessibilityAddTraits(.isHeader)
                // Bis zu vier Zeilen: Im 380 breiten Menüleisten-Menü (#555) braucht derselbe Grund wie in der Übersicht
                // drei Zeilen; breit bleibt es bei einer oder zwei.
                Text(verbatim: reason).font(InstrumentFont.body).foregroundStyle(.instrumentSecondary).lineLimit(4)
            }
            Spacer(minLength: InstrumentSpacing.panel)
            VStack(alignment: .trailing, spacing: InstrumentSpacing.item) {
                HStack(spacing: InstrumentSpacing.item) {
                    ForEach(items, id: \.self) { StatusChip($0) }
                }
                Text(verbatim: facts).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
        }
        .instrumentPanel(padding: InstrumentSpacing.page)
        .accessibilityElement(children: .combine)
    }
}

/// Zustandszeile aller Tabs außer der Übersicht (§3.1): kleines Schild, Urteil, Chips, Kenndaten – eine Zeile oben.
public struct StatusLine: View {
    let verdict: String
    let shield: ShieldForm
    let items: [StatusItem]
    let facts: String

    public init(verdict: String, shield: ShieldForm, items: [StatusItem], facts: String) {
        self.verdict = verdict
        self.shield = shield
        self.items = items
        self.facts = facts
    }

    public init(verdict: String, finding: Bool, items: [StatusItem], facts: String) {
        self.init(verdict: verdict, shield: ShieldForm(finding: finding), items: items, facts: facts)
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.cell) {
            ShieldBadge(form: shield, size: InstrumentSize.shieldSmall)
            Text(verbatim: verdict).font(InstrumentFont.body.weight(.semibold)).lineLimit(1)
            ForEach(items, id: \.self) { StatusChip($0) }
            Spacer(minLength: InstrumentSpacing.group)
            Text(verbatim: facts).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
        }
        .padding(.horizontal, InstrumentSpacing.panel)
        .padding(.vertical, InstrumentSpacing.group)
        .instrumentPanel(padding: 0)
        .accessibilityElement(children: .combine)
    }
}

/// Legende (§3.4): kurzer Strich in der Farbe der Reihe und ihr Name in der Textfarbe.
public struct LegendItem: View {
    let title: String
    let hue: InstrumentHue

    @Environment(\.self) private var environment

    public init(title: String, hue: InstrumentHue) {
        self.title = title
        self.hue = hue
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.inline) {
            Capsule().fill(environment.instrumentColor(hue))
                .frame(width: InstrumentSize.legendStroke.width, height: InstrumentSize.legendStroke.height)
            Text(verbatim: title).font(InstrumentFont.label.weight(.medium))
                .foregroundStyle(environment.instrumentTextColor(hue))
        }
        .accessibilityElement(children: .combine)
    }
}
