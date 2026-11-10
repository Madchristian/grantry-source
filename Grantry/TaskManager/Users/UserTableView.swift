import GrantryCharts
import ManagerKit
import SwiftUI

/// Inhalt des Tabs „Benutzer“ (Spec 2026-11-06 §6, §4, Gestaltung „Lagebild“): oben je Benutzer ein Panel mit
/// Peilring, darunter die Tabelle wie im Tab „Prozesse“ – Spaltenköpfe mit Summe und Spur, Hitze je Zelle, Anmeldungen
/// aufklappbar – in ihrer natürlichen Höhe, darunter der CPU-Verlauf je Benutzer, der den Rest füllt (Bewertung
/// 2026.11.7, Mangel 11: die Fläche blieb zu 70 % leer). Zeigt nur fertige Stände; Messung und Lesen liegen beim
/// `UsersTab`.
struct UserUsageView: View {
    let presentation: UserUsagePresentation
    let expanded: Set<String>
    /// CPU-Last je Zeile (Summe ihrer Prozesse) über die letzte Minute; leer ohne Verlauf.
    var history: [UserUsageRow.ID: ChartSeries] = [:]
    let onToggle: (UserUsageRow) -> Void

    var body: some View {
        VStack(spacing: InstrumentSpacing.panel) {
            UserTiles(presentation: presentation)
            TaskManagerTable(scrolls: false) {
                UserTableHeader(presentation: presentation)
            } rows: {
                UserTableRows(presentation: presentation, expanded: expanded, onToggle: onToggle)
            }
            UserHistory(presentation: presentation, history: history)
        }
        .padding(InstrumentSpacing.page)
        .renderProbe("UserUsageView")
    }
}

extension UserUsageView {
    /// CPU-Last je Zeile über die letzte Minute: Summe der Verläufe ihrer Prozesse; Konten ohne Anmeldung zusammen.
    static func history(for presentation: UserUsagePresentation, frame: TaskManagerFrame, measuredAt: Date,
                        userName: (UInt32) -> String) -> [UserUsageRow.ID: ChartSeries] {
        let chart = ChartHistory(history: frame.history, measuredAt: measuredAt)
        let users = Set(presentation.rows.filter { $0.kind == .user }.map(\.name))
        let byName = Dictionary(grouping: frame.snapshot.processes) { process -> String? in
            let name = userName(process.uid)
            return users.contains(name) ? name : nil
        }
        return Dictionary(uniqueKeysWithValues: presentation.rows.map { row in
            let processes = byName[row.kind == .user ? row.name : nil] ?? []
            return (row.id, chart.sumSeries(processes.map { MetricKey.processCPU($0.key) }, in: .oneMinute))
        })
    }
}

/// Verlauf der CPU-Last je Benutzer als Spuren mit gemeinsamer Zeitachse.
private struct UserHistory: View {
    let presentation: UserUsagePresentation
    let history: [UserUsageRow.ID: ChartSeries]

    @Environment(\.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) {
            PeilHead(String(localized: "Verlauf je Benutzer"),
                     detail: String(localized: "CPU-Last aller Prozesse, letzte 60 Sekunden"))
            ForEach(presentation.rows.filter { history[$0.id] != nil }) { row in
                let hue = UserBadge.hue(for: row, in: presentation) ?? .efficiencyCores
                VerlaufLane(title: row.name, value: ProcessColumn.cpu.text(row.figures), hue: hue) {
                    LiveGraph(series: history[row.id] ?? .empty, scale: .automatic(minimum: 0.05),
                              color: environment.instrumentColor(hue), isInteractive: false)
                }
            }
            TimeAxisLabels(window: 60).padding(.leading, InstrumentSize.laneLabel + InstrumentSpacing.panel)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .instrumentPanel()
    }
}

enum UserTableLayout {
    static let avatarSize: CGFloat = 24
    static let disclosureWidth = InstrumentSize.disclosure
    /// Name, „Prozesse“ und die Wertspalten wie im Tab „Prozesse“; bei 900 pt mit Seitenleiste schrumpfen zuerst die
    /// Zahlen, statt den Namen senkrecht zu stauchen (#486).
    static let columns = ProcessTableLayout.columns(values: ProcessTableLayout.valueColumns.count,
                                                    after: [.fixed(96, minimum: 72)])
}

/// Farbe und Kürzel eines Benutzers in Kachel, Ring und Zeile: angemeldete Benutzer reihum in den Farben der
/// Messgrößen, die Sammelzeile ohne Farbe.
enum UserBadge {
    static let hues: [InstrumentHue] = [.received, .cpu, .memory, .gpu, .sent, .diskWrite]

    static func hue(for row: UserUsageRow, in presentation: UserUsagePresentation) -> InstrumentHue? {
        let users = presentation.rows.filter { $0.kind == .user }
        guard row.kind == .user, let index = users.firstIndex(where: { $0.id == row.id }) else { return nil }
        return hues[index % hues.count]
    }

    static func initial(of row: UserUsageRow) -> String {
        row.name.drop { $0 == "_" }.first.map { String($0).uppercased() } ?? "?"
    }
}

struct UserAvatar: View {
    let row: UserUsageRow
    let hue: InstrumentHue?
    let size: CGFloat

    var body: some View {
        // design-token: Das weiße Kürzel braucht in beiden Erscheinungsbildern den dunklen Grund (feste Variante).
        let color = hue.map { $0.textColor(in: .light) } ?? Color.secondary // design-token: siehe oben
        ZStack {
            Circle().fill(color)
            if row.kind == .user {
                Text(verbatim: UserBadge.initial(of: row))
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            } else {
                Image(systemName: "lock.shield.fill").font(.system(size: size * 0.42, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct UserTableHeader: View {
    let presentation: UserUsagePresentation

    var body: some View {
        InstrumentColumnsLayout(UserTableLayout.columns, alignment: .bottom) {
            HeatColumnHeader(title: String(localized: "Benutzer"), value: presentation.headerValue(.name), heat: nil,
                             sortAscending: nil, alignment: .leading)
                .padding(.horizontal, InstrumentSpacing.group)
                .padding(.leading, UserTableLayout.disclosureWidth + UserTableLayout.avatarSize + InstrumentSpacing.bar
                    + InstrumentSpacing.inline)
            HeatColumnHeader(title: String(localized: "Prozesse"), value: "\(presentation.processCount)", heat: nil,
                             sortAscending: nil)
                .padding(.horizontal, InstrumentSpacing.group)
            ForEach(ProcessTableLayout.valueColumns) { column in
                HeatColumnHeader(title: column.title, value: presentation.headerValue(column),
                                 heat: presentation.heat(column, presentation.totals), sortAscending: nil,
                                 hue: column.hue)
                    .accessibilityIdentifier("userSum.\(column.rawValue)")
                    .padding(.horizontal, InstrumentSpacing.group)
            }
        }
        .padding(.horizontal, InstrumentSpacing.bar)
        .padding(.vertical, InstrumentSpacing.cell)
    }
}

/// Die Zeilen ohne Scrollbereich (auch für Snapshots: `ImageRenderer` zeichnet keinen `ScrollView`-Inhalt).
struct UserTableRows: View {
    let presentation: UserUsagePresentation
    let expanded: Set<String>
    let onToggle: (UserUsageRow) -> Void
    @Environment(\.chartStyle) private var style

    var body: some View {
        LazyVStack(spacing: InstrumentSpacing.stack) {
            ForEach(presentation.rows) { row in
                UserRowView(row: row, presentation: presentation, isExpanded: expanded.contains(row.id)) {
                    onToggle(row)
                }
                .contentShape(Rectangle())
                .onTapGesture { if row.isExpandable { onToggle(row) } }
                if row.isExpandable, expanded.contains(row.id) {
                    ForEach(row.sessions) { session in
                        UserSessionRow(session: session)
                    }
                }
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
        .animation(style.animates ? ValueTransition.animation : nil, value: expanded)
    }
}

struct UserRowView: View {
    let row: UserUsageRow
    let presentation: UserUsagePresentation
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        InstrumentColumnsLayout(UserTableLayout.columns) {
            name
            Text(verbatim: "\(row.processCount)")
                .font(InstrumentFont.numeric)
                .foregroundStyle(.instrumentSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, InstrumentSpacing.group)
            ForEach(ProcessTableLayout.valueColumns) { column in
                HeatCell(column.text(row.figures), heat: presentation.heat(column, row.figures), hue: column.hue)
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.inline)
        .instrumentRowBackground(isSelected: false, isSubtle: row.isCurrentUser)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("userRow")
    }

    private var name: some View {
        HStack(spacing: InstrumentSpacing.cell) {
            disclosure
            UserAvatar(row: row, hue: UserBadge.hue(for: row, in: presentation), size: UserTableLayout.avatarSize)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: InstrumentSpacing.item) {
                    Text(verbatim: row.name).font(InstrumentFont.title)
                    if row.isCurrentUser {
                        StatusChip(String(localized: "Du"), tone: .info, isSmall: true)
                    }
                }
                Text(verbatim: row.summary).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.isExpandable {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(InstrumentFont.label.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: UserTableLayout.disclosureWidth, height: UserTableLayout.disclosureWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.instrumentSecondary)
            .accessibilityLabel(isExpanded ? "Zuklappen" : "Aufklappen")
        } else {
            Color.clear.frame(width: UserTableLayout.disclosureWidth, height: UserTableLayout.disclosureWidth)
        }
    }
}

/// Eine Anmeldung unter ihrem Benutzer: Art, Anschluss (bei SSH mit Gegenstelle) und Beginn.
struct UserSessionRow: View {
    let session: LoginSession

    var body: some View {
        // Über die ganze Zeile: in der Namensspalte allein stand die Anmeldung bei 900 pt senkrecht (#486).
        HStack(spacing: InstrumentSpacing.group) {
            Image(systemName: session.kind.systemImage)
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .frame(width: InstrumentSize.rowIcon)
            Text(verbatim: session.kind.title).font(InstrumentFont.body).lineLimit(1)
            Text(verbatim: session.detail).font(InstrumentFont.code).foregroundStyle(.instrumentSecondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: InstrumentSpacing.group)
            Text(verbatim: session.sinceText()).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                .lineLimit(1)
        }
        .padding(.leading, UserTableLayout.disclosureWidth + UserTableLayout.avatarSize + InstrumentSpacing.empty)
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.stack)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Benutzer") {
    UserUsageView(presentation: UserUsagePreviewData.presentation, expanded: ["user:mara", "user:jonas"],
                  onToggle: { _ in })
        .frame(width: 1180, height: 640)
        .instrumentBackground()
}
#endif
