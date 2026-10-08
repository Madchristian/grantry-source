import AppKit
import ManagerKit
import SwiftUI

/// Ein Lauscher in der Liste: Symbol der zugehörigen App (bzw. Terminal-Symbol), Name, „Port · Erreichbarkeit“ (ggf.
/// „gestartet aus …“) und Badges; von außen erreichbare tragen ein Funksymbol.
struct NetworkListenerRowView: View {
    let row: NetworkListenerRow
    let badges: [RecordBadge]

    var body: some View {
        HStack(spacing: 10) {
            NetworkListenerIcon(row: row, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: row.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.listener.reachability.isExposed {
                        ExposedListenerSymbol()
                    }
                }
                Text(verbatim: row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                RecordBadgesRow(badges: badges)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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
                .font(.system(size: size * 0.7))
                .foregroundStyle(.secondary)
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
        HStack(spacing: 6) {
            AppIconView(
                app: AppIdentity(bundleID: nil, path: path, displayName: name, signing: signing, presence: .present),
                size: 16
            )
            Text(verbatim: name).lineLimit(1).truncationMode(.middle)
        }
        .help(path)
    }
}

/// Kennzeichen „von außen erreichbar“.
struct ExposedListenerSymbol: View {
    var body: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .foregroundStyle(PresentationTone.warning.color)
            .help("Von außen erreichbar")
            .accessibilityLabel("Von außen erreichbar")
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

#Preview("Lauscher-Zeile") {
    List {
        NetworkListenerRowView(row: NetworkListenerRow(.preview), badges: [])
        NetworkListenerRowView(
            row: NetworkListenerRow(NetworkListener(
                executablePath: "/usr/local/bin/redis-server", uid: getuid(), transport: .tcp, port: 6379,
                addresses: ["127.0.0.1", "::1"], signing: SigningInfo(kind: .unsigned),
                firstSeenAt: .now, lastSeenAt: .now
            )),
            badges: []
        )
    }
    .frame(width: 360, height: 160)
}
#endif
