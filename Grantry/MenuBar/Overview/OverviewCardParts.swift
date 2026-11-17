import GrantryCharts
import ManagerKit
import SwiftUI

// Gemeinsame Teile der Übersicht in der Menüleiste (#495) für die Kacheln des Baukastens
// (Spec 2026-11-09-uebersicht-baukasten § 9): Rahmen einer Kachel, Wert mit Legendenstrich, Farben von CPU-Anteilen. Die
// Farbe einer Kernart steht an einer Stelle für alle Ansichten (`CoreKind.hue`, #589, #592). Ringe, Spuren und Verläufe
// aus Formen statt `Canvas` (#491); keine Animation je Takt.

/// Rahmen einer Kachel: Titel als Überschrift, Detail, Wert rechts, darunter der Inhalt. Die Legende (`accessory`, eine
/// Ansicht) steht in der Kopfzeile, solange sie dort Platz hat, sonst darunter; passt auch das Detail nicht neben Titel
/// und Wert (schmale Kachel, langer Name), rückt es in eine eigene Zeile, statt abzuschneiden (`CardHeadline`, ohne
/// `ViewThatFits`, #626). Ein Klick springt in den Task-Manager; VoiceOver bietet dafür eine eigene Aktion, die Elemente
/// der Kachel bleiben einzeln erreichbar. Die Kachel selbst heißt „Titel, Wert“ (ohne Wert mit `spokenValue` bzw. dem
/// Detail), wie die Kacheln des Task-Managers.
struct OverviewCard<Accessory: View, Content: View>: View {
    let title: String
    let detail: String
    let value: String
    let spokenValue: String?
    let valueColor: Color?
    let open: () -> Void
    let accessory: Accessory
    let content: Content

    init(title: String, detail: String = "", value: String = "", spokenValue: String? = nil, valueColor: Color? = nil,
         open: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.value = value
        self.spokenValue = spokenValue
        self.valueColor = valueColor
        self.open = open
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            CardHeadline {
                Text(verbatim: title)
                    .font(InstrumentFont.body.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .cardHeadline(.title)
                if !detail.isEmpty {
                    Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                        .lineLimit(1).truncationMode(.middle)
                        .cardHeadline(.detail)
                }
                accessory.cardHeadline(.legend)
                if !value.isEmpty {
                    Text(verbatim: value)
                        .font(InstrumentFont.tileValue)
                        .foregroundStyle(valueColor ?? .primary)
                        .lineLimit(1)
                        .cardHeadline(.value)
                }
            }
            content
        }
        // Füllt die Zellen des Rasters ganz aus (Spec § 7); sonst endeten Kacheln einer Zeile verschieden hoch, und
        // unter der letzten blieb Leerraum (#524).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .instrumentPanel(padding: InstrumentSpacing.cell, radius: InstrumentRadius.card)
        .contentShape(RoundedRectangle(cornerRadius: InstrumentRadius.card, style: .continuous))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: [title, spokenValue ?? (value.isEmpty ? detail : value)]
            .filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: Text("Im Task-Manager öffnen"), open)
        .accessibilityIdentifier("popoverCard")
        .help("Im Task-Manager anzeigen")
    }
}

extension OverviewCard where Accessory == EmptyView {
    /// Kachel ohne Legende in der Kopfzeile.
    init(title: String, detail: String = "", value: String = "", spokenValue: String? = nil, valueColor: Color? = nil,
         open: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, detail: detail, value: value, spokenValue: spokenValue, valueColor: valueColor,
                  open: open, accessory: { EmptyView() }, content: content)
    }
}

/// Wert mit Legendenstrich: „▬ Benutzer 25 %“; mit `isSpread` als Tabellenzeile, Wert am rechten Rand.
struct LegendValue: View {
    let title: String
    let value: String
    let hue: InstrumentHue
    var isSpread = false

    @Environment(\.self) private var environment

    var body: some View {
        // Gestreckt trägt der `Spacer` den Abstand: So ist die Zeile in Wunschbreite genau so breit wie ohne `isSpread`
        // und passt in einen `FittingLine` nebeneinander wie untereinander.
        HStack(spacing: isSpread ? 0 : InstrumentSpacing.inline) {
            LegendItem(title: title, hue: hue).lineLimit(1)
            if isSpread { Spacer(minLength: InstrumentSpacing.inline) }
            Text(verbatim: value).font(InstrumentFont.numeric).foregroundStyle(environment.instrumentTextColor(hue))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Zwei Legendenwerte (Lesen und Schreiben, Empfangen und Gesendet): nebeneinander, solange die Kachel breit genug ist,
/// sonst untereinander als Tabelle.
struct LegendPair: View {
    let first: (title: String, value: String, hue: InstrumentHue)
    let second: (title: String, value: String, hue: InstrumentHue)

    var body: some View {
        FittingLine(spacing: InstrumentSpacing.bar, stackedSpacing: InstrumentSpacing.inline) {
            LegendValue(title: first.title, value: first.value, hue: first.hue, isSpread: true)
            LegendValue(title: second.title, value: second.value, hue: second.hue, isSpread: true)
        }
    }
}

/// Angabe ohne Farbe als Tabellenzeile: Bezeichnung links, Wert am rechten Rand.
struct FactRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: InstrumentSpacing.inline) {
            Text(verbatim: title).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
            Spacer(minLength: 0)
            Text(verbatim: value).font(InstrumentFont.numeric).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Teile der CPU-Last im gestapelten Verlauf: Benutzer in der Farbe der CPU, System abgesetzt in Rosé (§2.3,
/// zusammengesetzte Größe mit Legende); nicht Lila, das in der Karte darunter die Effizienzkerne zeigt.
enum CPUShare {
    case user, system

    var hue: InstrumentHue {
        switch self {
        case .user: .cpu
        case .system: .neuralEngine
        }
    }
}
