import SwiftUI

/// Popover eines Menüleisten-Elements (TM17, Spec 2026-11-09 § 3): Peilkopf mit Wert, optional Verlauf, Zustandschips
/// mit Satz, Kennzahlen wie im Leistung-Tab und unten der Sprung in den Task-Manager. Gezeichnet in SwiftUI statt mit
/// `.link`, weil `ImageRenderer` den AppKit-Knopf nicht zeichnet.
public struct MeterPopoverPanel<Graph: View>: View {
    let title: String
    let detail: String
    let value: String
    let hue: InstrumentHue?
    let fraction: Double?
    let statusItems: [StatusItem]
    let note: String?
    let fields: [(title: String, value: String)]
    let linkTitle: String
    let open: () -> Void
    let graph: Graph?

    @Environment(\.self) private var environment

    public init(title: String, detail: String = "", value: String, hue: InstrumentHue? = nil, fraction: Double? = nil,
                statusItems: [StatusItem] = [], note: String? = nil, fields: [(title: String, value: String)],
                linkTitle: String, open: @escaping () -> Void, @ViewBuilder graph: () -> Graph) {
        self.title = title
        self.detail = detail
        self.value = value
        self.hue = hue
        self.fraction = fraction
        self.statusItems = statusItems
        self.note = note
        self.fields = fields
        self.linkTitle = linkTitle
        self.open = open
        self.graph = graph()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.panel) {
            PeilHead(title, detail: detail, value: value, hue: hue, fraction: fraction,
                     finding: statusItems.contains { $0.tone == .finding })
            if let graph {
                graph
                    .frame(height: InstrumentSize.popoverGraph)
                    .instrumentPanel()
                    .accessibilityHidden(true)
            }
            if !statusItems.isEmpty || note != nil {
                VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
                    HStack(spacing: InstrumentSpacing.item) {
                        ForEach(statusItems, id: \.self) { StatusChip($0) }
                    }
                    if let note {
                        Text(verbatim: note)
                            .font(InstrumentFont.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .instrumentPanel()
            }
            if !fields.isEmpty { MeasureFieldRow(fields: fields) }
            HStack {
                Spacer()
                Button(action: open) {
                    Label(linkTitle, systemImage: "arrow.up.forward.app")
                        .font(InstrumentFont.body.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(environment.statusTextColor(.info))
                .accessibilityIdentifier("menuBarMeter.open")
            }
        }
        .padding(InstrumentSpacing.page)
        .frame(width: InstrumentSize.columnWide)
        .instrumentBackground()
    }
}

extension MeterPopoverPanel where Graph == EmptyView {
    /// Ohne Verlauf (Thermik, Akku).
    public init(title: String, detail: String = "", value: String, hue: InstrumentHue? = nil, fraction: Double? = nil,
                statusItems: [StatusItem] = [], note: String? = nil, fields: [(title: String, value: String)],
                linkTitle: String, open: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.value = value
        self.hue = hue
        self.fraction = fraction
        self.statusItems = statusItems
        self.note = note
        self.fields = fields
        self.linkTitle = linkTitle
        self.open = open
        graph = nil
    }
}
