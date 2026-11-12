import AppKit
import GrantryCharts
import ManagerKit
import SwiftUI

enum NetworkListenerTableLayout {
    static let spacing = InstrumentSpacing.inline
    /// Dienst, Port, Erreichbarkeit, Benutzer, Signatur. Bei 900 pt mit Seitenleiste schrumpfen zuerst die übrigen
    /// Spalten; vorher blieben dem Namen wenige Zeichen („Po…res“, #486).
    static let columns = InstrumentColumns([
        .name(minimum: 170), .fixed(92, minimum: 76), .fixed(140, minimum: 120), .fixed(128, minimum: 96),
        .fixed(132, minimum: 110),
    ], spacing: spacing)
    /// Schmalste Tabelle samt Innenrand von Kopf und Zeilen.
    static let minimumWidth = columns.minimumWidth + 2 * InstrumentSpacing.bar
}

/// Spaltenkopf der Dienste (§3.7): Titel, über „Dienst“ und „Erreichbarkeit“ die Summen der sichtbaren Zeilen.
struct NetworkListenerTableHeader: View {
    let rows: [NetworkListenerRow]

    var body: some View {
        let exposed = rows.count { $0.listener.reachability.isExposed }
        InstrumentColumnsLayout(NetworkListenerTableLayout.columns, alignment: .bottom) {
            header(String(localized: "Dienst"),
                   value: rows.count == 1 ? String(localized: "1 Dienst") : String(localized: "\(rows.count) Dienste"))
                .padding(.leading, InstrumentSize.rowIconTall + InstrumentSpacing.group)
            header(String(localized: "Port"))
            header(String(localized: "Erreichbarkeit"), value: String(localized: "\(exposed) aus dem Netz"))
            header(String(localized: "Benutzer"))
            header(String(localized: "Signatur"))
        }
        .padding(.horizontal, InstrumentSpacing.bar)
        .padding(.vertical, InstrumentSpacing.cell)
    }

    private func header(_ title: String, value: String = "") -> some View {
        HeatColumnHeader(title: title, value: value, heat: nil, sortAscending: nil, alignment: .leading)
            .padding(.horizontal, InstrumentSpacing.inline)
    }
}

/// Die Zeilen ohne Scrollbereich (auch für Bilder: `ImageRenderer` zeichnet keinen `ScrollView`-Inhalt); jede Zeile trägt
/// ihre ID für den Sprung aus einer Benachrichtigung (`ScrollViewReader`).
struct NetworkListenerTableRows<Menu: View>: View {
    let rows: [NetworkListenerRow]
    let badges: (NetworkListenerRow) -> [RecordBadge]
    @Binding var selection: NetworkListener.ID?
    @ViewBuilder let contextMenu: (NetworkListenerRow) -> Menu

    var body: some View {
        LazyVStack(spacing: InstrumentSpacing.stack) {
            ForEach(rows) { row in
                NetworkListenerRowView(row: row, badges: badges(row), isSelected: selection == row.id)
                    .selectableRow { selection = row.id }
                    .contextMenu { contextMenu(row) }
                    .id(row.id)
            }
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.item)
    }
}

/// Ein Lauscher als Tabellenzeile: Symbol, Name mit Befund-Punkt und Badges, darunter die Herkunft; Port, Erreichbarkeit
/// als Zustandschip mit Adressen, Benutzer und Signatur.
struct NetworkListenerRowView: View {
    let row: NetworkListenerRow
    let badges: [RecordBadge]
    var isSelected = false

    private var listener: NetworkListener { row.listener }

    var body: some View {
        InstrumentColumnsLayout(NetworkListenerTableLayout.columns) {
            HStack(spacing: InstrumentSpacing.group) {
                NetworkListenerIcon(row: row, size: InstrumentSize.rowIconTall)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: InstrumentSpacing.item) {
                        if row.severity != nil { FindingDot(size: InstrumentSize.findingDotSmall) }
                        Text(verbatim: row.title).font(InstrumentFont.body).lineLimit(1).truncationMode(.middle)
                        BadgeChips(badges.map(\.instrumentBadge))
                    }
                    Text(verbatim: origin)
                        .font(InstrumentFont.label)
                        .foregroundStyle(.instrumentSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: listener.portText)
                .font(InstrumentFont.code)
                .lineLimit(1)
                .padding(.horizontal, InstrumentSpacing.inline)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                StatusChip(listener.reachItem)
                Text(verbatim: listener.reachabilityText)
                    .font(InstrumentFont.label)
                    .foregroundStyle(.instrumentSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, InstrumentSpacing.inline)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: ListenerUser(uid: listener.uid, currentUID: getuid()).displayName)
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .lineLimit(1)
                .padding(.horizontal, InstrumentSpacing.inline)
                .frame(maxWidth: .infinity, alignment: .leading)
            SigningLabel(signing: listener.signing, style: .compact)
                .font(InstrumentFont.body)
                .lineLimit(1)
                .padding(.horizontal, InstrumentSpacing.inline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, InstrumentSpacing.group)
        .padding(.vertical, InstrumentSpacing.inline)
        .instrumentRowBackground(isSelected: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// „gestartet aus iTerm“, sonst der Prozessname.
    private var origin: String {
        row.launchingAppName.map { String(localized: "gestartet aus \($0)") } ?? listener.processName
    }
}

/// Symbol des eigenen App-Bundles eines Lauschers (`ProgramIcon`); ohne eigenes Bundle ein Terminal-Symbol – auch wenn
/// eine Eltern-App bekannt ist, sonst trüge `python3` das Symbol von iTerm.
struct NetworkListenerIcon: View {
    let row: NetworkListenerRow
    var size: CGFloat = 24

    var body: some View {
        ProgramIcon(bundlePath: row.bundlePath, title: row.title, signing: row.listener.signing, size: size)
    }
}

/// Symbol eines Programms: das seines App-Bundles (über `AppIconView`, ohne Launch Services), ohne Bundle ein
/// Terminal-Symbol. Gemeinsam für Lauscher und Netzwerkaktivität.
struct ProgramIcon: View {
    let bundlePath: String?
    let title: String
    let signing: SigningInfo
    var size: CGFloat = 24

    var body: some View {
        if let bundlePath {
            AppIconView(
                app: AppIdentity(bundleID: nil, path: bundlePath, displayName: title, signing: signing, presence: .present),
                size: size
            )
        } else {
            Image(systemName: "terminal")
                .font(.system(size: size * 0.7)) // design-token: Symbol wächst mit der Symbolgröße
                .foregroundStyle(.instrumentSecondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

extension ProgramIcon {
    /// Symbol zu `program`; ohne bekanntes Programm (etwa `kernel_task`) das Terminal-Symbol.
    init(program: NetworkProgram?, title: String, size: CGFloat = 24) {
        self.init(bundlePath: program?.bundlePath, title: title, signing: program?.signing ?? .unknown, size: size)
    }
}

/// Eine App als Symbol und Name; der volle Pfad steht im Tooltip.
struct BundleAppLabel: View {
    let path: String
    let name: String
    let signing: SigningInfo

    var body: some View {
        HStack(spacing: InstrumentSpacing.item) {
            AppIconView(
                app: AppIdentity(bundleID: nil, path: path, displayName: name, signing: signing, presence: .present),
                size: 16
            )
            Text(verbatim: name).lineLimit(1).truncationMode(.middle)
        }
        .help(path)
    }
}

extension NetworkProgram {
    /// Zeigt das Programm im Finder (Nutzeraktion, verändert nichts).
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: executablePath)])
    }
}

extension NetworkListener {
    /// Zeigt das Programm im Finder (Nutzeraktion, verändert nichts).
    func revealInFinder() { program.revealInFinder() }
}

#if DEBUG
extension NetworkListener {
    /// Fester Beispiel-Lauscher für Previews: node auf allen Schnittstellen, Port 3000, ad hoc signiert.
    static var preview: NetworkListener {
        NetworkListener(
            executablePath: "/opt/homebrew/Cellar/node/24.1.0/bin/node", uid: getuid(), transport: .tcp, port: 3000,
            addresses: ["0.0.0.0"], signing: SigningInfo(kind: .adHoc),
            ancestorPaths: ["/Applications/Visual Studio Code.app/Contents/MacOS/Electron"],
            firstSeenAt: Date(timeIntervalSince1970: 1_790_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// Fester Beispiel-Lauscher eines anderen Benutzers (root): beenden kann ihn nur der Helper.
    static var previewRoot: NetworkListener {
        NetworkListener(
            executablePath: "/usr/local/sbin/dnsmasq", uid: 0, transport: .udp, port: 53,
            addresses: ["0.0.0.0"], signing: SigningInfo(kind: .adHoc),
            firstSeenAt: Date(timeIntervalSince1970: 1_790_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }
}

#Preview("Lauscher-Zeilen") {
    let rows = NetworkServicesPreviewData.listeners.map {
        NetworkListenerRow($0, severity: NetworkServicesPreviewData.severity(for: $0.id))
    }
    TaskManagerTable {
        NetworkListenerTableHeader(rows: rows)
    } rows: {
        NetworkListenerTableRows(rows: rows, badges: { $0.severity.map { [.review($0)] } ?? [] },
                                 selection: .constant(rows.first?.id), contextMenu: { _ in EmptyView() })
    }
    .padding(14)
    .frame(width: 860, height: 420)
    .instrumentBackground()
}
#endif
