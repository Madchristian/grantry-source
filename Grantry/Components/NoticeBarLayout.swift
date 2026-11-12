import GrantryCharts
import ManagerKit
import SwiftUI

/// Gestaltung der Hinweisleiste über einer Liste (#142): Symbol im Zustandston (`StatusTone`), Überschrift, bis zu zwei
/// Gründe (weitere als „und n weitere“ mit Tooltip), Schaltflächen und ruhige Notizen. Hervorgehoben (fett, Mulde im
/// Zustandston) nur bei `isEmphasized`. Gemeinsam für die Scan-Abdeckung (`AreaCoverageBar`) und die
/// Netzwerkaktivität (`NetworkActivityNoticeBar`); lange Gründe werden gekürzt, ohne `fixedSize(vertical:)` (d342e9b).
struct NoticeBarLayout<Actions: View>: View {
    let systemImage: String
    let tone: PresentationTone
    let headline: String
    let accessibilityLabel: String
    let isEmphasized: Bool
    var explanation: String? = nil
    var reasons: [String] = []
    var notes: [String] = []
    @ViewBuilder let actions: Actions

    @Environment(\.self) private var environment

    /// So viele Gründe stehen ausgeschrieben da, weitere fasst „und n weitere“ zusammen.
    private var visibleReasonCount: Int { 2 }

    var body: some View {
        let color = environment.statusColor(tone.statusTone)
        HStack(alignment: .firstTextBaseline, spacing: InstrumentSpacing.group) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
                Text(verbatim: headline)
                    .fontWeight(isEmphasized ? .semibold : .regular)
                    .foregroundStyle(isEmphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.instrumentSecondary))
                    .lineLimit(2)
                    .accessibilityLabel(Text(verbatim: accessibilityLabel))
                    .accessibilityAddTraits(.isHeader)
                if let explanation {
                    Text(verbatim: explanation)
                        .foregroundStyle(.instrumentSecondary)
                        .lineLimit(3)
                }
                reasonList
                actions
                ForEach(notes, id: \.self) { note in
                    Text(verbatim: note)
                        .font(InstrumentFont.label)
                        .foregroundStyle(.instrumentSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(InstrumentFont.body)
        .textSelection(.enabled)
        .padding(InstrumentSpacing.group)
        .background(isEmphasized ? color.opacity(InstrumentOpacity.well) : Color.clear)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var reasonList: some View {
        ForEach(reasons.prefix(visibleReasonCount), id: \.self) { reason in
            Text(verbatim: reason)
                .foregroundStyle(.instrumentSecondary)
                .lineLimit(3)
                .help(Text(verbatim: reason))
        }
        let hidden = reasons.dropFirst(visibleReasonCount)
        if !hidden.isEmpty {
            Text("und \(hidden.count) weitere")
                .foregroundStyle(.instrumentSecondary)
                .help(Text(verbatim: hidden.joined(separator: "\n")))
                .accessibilityLabel(Text(verbatim: hidden.joined(separator: ". ")))
        }
    }
}
