import Foundation
import os

/// Liefert die Rohausgabe von `sfltool dumpbtm`. In der App implementiert der `HelperClient` (Plan 2) dieses Protokoll.
public protocol BTMDumpProviding: Sendable {
    func dumpBTM() async throws -> String
}

/// Fehler der BTM-Quelle.
public enum BTMSourceError: LocalizedError, Equatable {
    /// Der privilegierte Helper, der `sfltool dumpbtm` als root ausführt, ist nicht erreichbar.
    case helperUnavailable
    /// Die Ausgabe enthält keinen `Records for UID`-Abschnitt (leer oder unbekanntes Format). Als leerer Scan gewertet,
    /// würde sie jeden bekannten Eintrag scheinbar entfernen.
    case unparseableDump
    /// Der Helper hat `sfltool dumpbtm` abgelehnt oder der Befehl ist gescheitert.
    case dumpFailed(String)

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable: "Hintergrund-Items nicht lesbar: Helper nicht erreichbar"
        case .unparseableDump: "Hintergrund-Items nicht lesbar: unerwartetes Ausgabeformat von sfltool dumpbtm"
        case .dumpFailed(let detail): "Hintergrund-Items nicht lesbar: \(detail)"
        }
    }
}

/// Login-Items und Hintergrund-Items aus der Background-Task-Management-Datenbank.
///
/// Übersprungen werden `app`-Einträge (nur Eltern-Container), `developer`, unbekannte Typen und
/// `legacy agent/daemon` (liegen als Plist in den Launch-Verzeichnissen und kommen bereits aus `LaunchdSource`).
/// Den Ladezustand kennt BTM nicht (`isLoaded == nil`). Scheitert der Provider, scheitert die ganze Quelle, damit
/// die Fortschreibung des letzten gültigen Stands greift.
public struct BTMSource: InventorySource {
    public let id: SourceID = .btm
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "btm")

    private let provider: any BTMDumpProviding
    private let resolver: any AppResolving
    private let preferredUID: uid_t

    /// - Parameter preferredUID: UID, deren Abschnitt bei doppelten Einträgen gewinnt. Der Standardwert `getuid()`
    ///   ist die tatsächliche UID des laufenden Prozesses, nicht zwingend die des Konsolenbenutzers: Als root
    ///   (z. B. im Helper) wäre das `0`. Privilegierte Aufrufer müssen die Konsolen-UID daher explizit übergeben.
    public init(provider: any BTMDumpProviding, resolver: any AppResolving, preferredUID: uid_t = getuid()) {
        self.provider = provider
        self.resolver = resolver
        self.preferredUID = preferredUID
    }

    /// Jeder Eigentümer wird pro Durchlauf nur einmal aufgelöst. Ergeben mehrere Einträge dieselbe ID (etwa dieselbe
    /// Bundle-ID in den Abschnitten mehrerer UIDs), gewinnt der Eintrag aus dem Abschnitt `preferredUID`; kommt
    /// `preferredUID` in keinem der beteiligten Abschnitte vor, gewinnt deterministisch der erste in der Reihenfolge
    /// des Dumps.
    public func collect() async throws -> InventoryContribution {
        let output = try await provider.dumpBTM()
        guard BTMParser.containsSection(output) else { throw BTMSourceError.unparseableDump }
        let records = BTMParser.parse(output)
        let appPaths = Self.appPaths(in: records)
        var owners: [String: AppIdentity] = [:]
        var indexByID: [String: Int] = [:]
        var items: [AutostartItem] = []
        /// Steht an Position `i`, ob `items[i]` bereits aus dem bevorzugten Abschnitt stammt – verhindert, dass ein
        /// späterer Treffer aus demselben Abschnitt den ersten wieder verdrängt.
        var wonByPreferredUID: [Bool] = []
        for record in records {
            guard let (kind, domain) = Self.mapping(for: record.type) else { continue }
            var owner: AppIdentity?
            if let parent = record.parentBundleID {
                if let known = owners[parent] {
                    owner = known
                } else {
                    let resolved = await resolver.resolve(bundleID: parent)
                    owner = resolved
                    owners[parent] = resolved
                }
            }
            let parentPath = record.parentIdentifier.flatMap { appPaths[$0] } ?? owner?.path
            let item = item(from: record, kind: kind, domain: domain, owner: owner, parentPath: parentPath)
            let isPreferred = record.uid == Int(preferredUID)
            if let index = indexByID[item.id] {
                if isPreferred && !wonByPreferredUID[index] {
                    items[index] = item
                    wonByPreferredUID[index] = true
                    Self.logger.debug("Doppelter BTM-Eintrag \(item.id, privacy: .public) ersetzt")
                } else {
                    Self.logger.debug("Doppelter BTM-Eintrag \(item.id, privacy: .public) übersprungen")
                }
                continue
            }
            indexByID[item.id] = items.count
            items.append(item)
            wonByPreferredUID.append(isPreferred)
        }
        return InventoryContribution(autostartItems: items)
    }

    /// - Parameter parentPath: Bundle-Pfad der Eltern-App, gegen den relative Pfade aufgelöst werden.
    private func item(
        from record: BTMRecord, kind: AutostartKind, domain: AutostartDomain, owner: AppIdentity?, parentPath: String?
    ) -> AutostartItem {
        let program = Self.absolutePath(record.executablePath ?? record.url, relativeTo: parentPath)
        return AutostartItem(
            kind: kind,
            domain: domain,
            label: record.bundleID ?? record.unprefixedIdentifier ?? record.name,
            program: program,
            programPresence: program.map(Presence.init(ofItemAt:)) ?? .unknown,
            isEnabled: record.isEnabled,
            isLoaded: nil,
            plistPath: nil,
            owner: owner,
            source: id
        )
    }

    private static func mapping(for type: BTMRecord.ItemType) -> (AutostartKind, AutostartDomain)? {
        switch type {
        case .loginItem: (.loginItem, .user)
        case .agent: (.backgroundTask, .user)
        case .daemon: (.backgroundTask, .system)
        case .app, .developer, .legacyAgent, .legacyDaemon, .other: nil
        }
    }

    /// Bundle-Pfade der `app`-Einträge nach `Identifier` (z. B. `2.com.docker.docker`); bei Einträgen in mehreren
    /// UID-Abschnitten gewinnt der erste.
    private static func appPaths(in records: [BTMRecord]) -> [String: String] {
        var paths: [String: String] = [:]
        for record in records where record.type == .app {
            guard let identifier = record.identifier, paths[identifier] == nil,
                  let path = absolutePath(record.url, relativeTo: nil) else { continue }
            paths[identifier] = path
        }
        return paths
    }

    /// Absoluter Pfad aus einem BTM-Pfadwert, ohne abschließenden Schrägstrich. `sfltool` liefert absolute Pfade
    /// (`/Applications/Docker.app`), zum Bundle der Eltern-App relative Pfade (`Contents/MacOS/Helper`) und in älteren
    /// Formaten `file://`-URLs (`file:///Applications/Foo%20Bar.app/`, werden dekodiert). Ein relativer Pfad ohne
    /// `base` ergibt `nil` – unbekannt statt vermeintlich fehlend.
    private static func absolutePath(_ value: String?, relativeTo base: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let path: String
        if value.hasPrefix("file:") {
            guard let url = URL(string: value), url.isFileURL else { return nil }
            path = url.path(percentEncoded: false)
        } else if value.hasPrefix("/") {
            path = value
        } else if let base {
            path = (base.hasSuffix("/") ? base : base + "/") + value
        } else {
            return nil
        }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
