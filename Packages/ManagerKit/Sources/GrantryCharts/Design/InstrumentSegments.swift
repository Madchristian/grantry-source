import SwiftUI

/// Umschalter im Inhalt (§3.9, Entscheidung E1): Rinne als Kapsel, gewähltes Segment weiß auf dem Grantry-Verlauf.
/// Gezeichnet statt `Picker(.segmented)`, damit er zur Tafel passt und im Bild (`ImageRenderer`) wie in der App
/// aussieht. Jedes Segment ist ein Knopf mit Beschriftung und `isSelected`, mit der Tastatur erreichbar.
public struct InstrumentSegments<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    public init(_ label: String, selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self.label = label
        _selection = selection
        self.options = options
    }

    public var body: some View {
        SegmentGroup(label: label, selection: $selection, options: options, density: .regular, wraps: false)
    }
}

/// Innenabstand der Segmente: `regular` nach §3.9 (12 / 4), `compact` für schmale Fenster (8 / 4).
enum SegmentDensity {
    case regular, compact

    var horizontalPadding: CGFloat { self == .regular ? InstrumentSpacing.panel : InstrumentSpacing.group }
}

/// Segmente in ihrer Rinne – in einer Zeile oder, mit `wraps`, umbrochen in ausgeglichene Zeilen (`SegmentRows`).
/// Gemeinsamer Baustein von `InstrumentSegments` und `InstrumentTabs`.
struct SegmentGroup<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    let density: SegmentDensity
    let wraps: Bool

    var body: some View {
        let layout = wraps ? AnyLayout(SegmentFlowLayout(spacing: InstrumentSpacing.stack))
            : AnyLayout(HStackLayout(spacing: InstrumentSpacing.stack))
        let well = wraps ? AnyShape(RoundedRectangle(cornerRadius: InstrumentRadius.panel)) : AnyShape(Capsule())
        layout {
            ForEach(options, id: \.value) { option in
                segment(option)
            }
        }
        .padding(InstrumentSpacing.stack)
        .background(well.fill(.primary.opacity(InstrumentOpacity.well)))
        .fixedSize(horizontal: !wraps, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
        // Kennung für den Barrierefreiheitstest (#378): Er prüft je Umschalter genau ein gewähltes Segment.
        .accessibilityIdentifier("instrumentSegments")
    }

    private func segment(_ option: (value: Value, label: String)) -> some View {
        let isSelected = option.value == selection
        return Button { selection = option.value } label: {
            Text(verbatim: option.label)
                .font(InstrumentFont.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.instrumentSecondary))
                .lineLimit(1)
                .padding(.horizontal, density.horizontalPadding)
                .padding(.vertical, InstrumentSpacing.inline)
                .background {
                    if isSelected { Capsule().fill(GrantryBrand.fill) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: option.label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
