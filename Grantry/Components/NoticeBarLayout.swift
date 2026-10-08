import ManagerKit
import SwiftUI

/// Gestaltung der Hinweisleiste über einer Liste (#142): Symbol in Zustandsfarbe, Überschrift, bis zu zwei Gründe
/// (weitere als „und n weitere“ mit Tooltip), Schaltflächen und ruhige Notizen. Hervorgehoben (fett, getönter
/// Hintergrund) nur bei `isEmphasized`. Gemeinsam für die Scan-Abdeckung (`AreaCoverageBar`) und die
/// Netzwerkaktivität (`NetworkActivityNoticeBar`); lange Gründe werden gekürzt, ohne `fixedSize(vertical:)` (d342e9b).
struct NoticeBarLayout<Actions: View>: View {
    let systemImage: String
    let tone: PresentationTone
    let headline: String
    let accessibilityLabel: String
    let isEmphasized: Bool
    var reasons: [String] = []
    var notes: [String] = []
    @ViewBuilder let actions: Actions

    /// So viele Gründe stehen ausgeschrieben da, weitere fasst „und n weitere“ zusammen.
    private var visibleReasonCount: Int { 2 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: headline)
                    .fontWeight(isEmphasized ? .semibold : .regular)
                    .foregroundStyle(isEmphasized ? .primary : .secondary)
                    .lineLimit(2)
                    .accessibilityLabel(Text(verbatim: accessibilityLabel))
                    .accessibilityAddTraits(.isHeader)
                reasonList
                actions
                ForEach(notes, id: \.self) { note in
                    Text(verbatim: note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(8)
        .background(isEmphasized ? tone.color.opacity(0.08) : Color.clear)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var reasonList: some View {
        ForEach(reasons.prefix(visibleReasonCount), id: \.self) { reason in
            Text(verbatim: reason)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .help(Text(verbatim: reason))
        }
        let hidden = reasons.dropFirst(visibleReasonCount)
        if !hidden.isEmpty {
            Text("und \(hidden.count) weitere")
                .foregroundStyle(.secondary)
                .help(Text(verbatim: hidden.joined(separator: "\n")))
                .accessibilityLabel(Text(verbatim: hidden.joined(separator: ". ")))
        }
    }
}
