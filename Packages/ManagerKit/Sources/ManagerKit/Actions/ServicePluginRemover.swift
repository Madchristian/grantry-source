import Foundation

/// Letzte Prüfung, bevor ein Plug-in eines Systemdienstes in den Papierkorb darf (TM-13.5, Spec 2026-11-08 § 4.5) – eng
/// wie `StoragePathGuard`: nur ein direkter Eintrag eines Plug-in-Ordners (`ServicePluginDirectory.standard`, am Objekt
/// erkannt) mit Plug-in-Endung; kein Symlink (auch nicht im Pfad), nicht versteckt, keine Apple-Kennung im Namen, kein
/// Einhängepunkt; derselbe Eintrag (Gerät, Inode, Art) wie bei der Bestätigung und ab dem Plug-in-Ordner vertrauenswürdige
/// Ordnerrechte (`DirectoryChainGuard`). Kein Löschweg für beliebige Ordner.
struct ServicePluginPathGuard: Sendable {
    let directories: [String]

    init(directories: [String] = ServicePluginDirectory.standard(home: NSHomeDirectory()).map(\.path)) {
        self.directories = directories
    }

    func check(_ path: String, identity: FileIdentity?) -> RemovalVerdict {
        guard let identity else { return .blocked("Kein Beleg") }
        guard let components = RawPath.components(of: path) else { return .blocked("Ungültiger Pfad") }
        guard let entry = FileIdentity.of(path) else { return .blocked("Nicht vorhanden") }
        if entry.type == .symbolicLink { return .blocked("Symbolischer Link") }
        let name = components[components.count - 1]
        if RawPath.isHidden(name) { return .blocked("Versteckter Eintrag") }
        guard entry.type == .directory,
              ServicePluginScanner.bundleSuffixes.contains(where: { RawPath.hasExtension(name, String($0.dropFirst())) }) else {
            return .blocked("Kein Plug-in-Bundle")
        }
        if BundleIDShape.isApple(name) { return .blocked("Apple-Eintrag") }
        let parentPath = RawPath.path(of: components.dropLast())
        guard let resolvedParent = RemovalGuard.resolvedPath(parentPath), resolvedParent.lowercased() == parentPath.lowercased() else {
            return .blocked("Symbolischer Link im Pfad")
        }
        // `/` und jeder Elternordner bis einschließlich des Plug-in-Ordners.
        let ancestors = RawPath.prefixes(of: Array(components.dropLast())).compactMap(FileIdentity.of)
        guard ancestors.count == components.count, let parent = ancestors.last else { return .blocked("Nicht vorhanden") }
        guard directories.compactMap(FileIdentity.of).contains(where: { $0.isSameObject(as: parent) }) else {
            return .blocked("Außerhalb der Plug-in-Ordner")
        }
        guard entry == identity else { return .blocked("Geändert seit der Bestätigung") }
        if RemovalGuard.isMountPoint(entry, below: parent) { return .blocked("Einhängepunkt") }
        return DirectoryChainGuard.inspect(components, chain: ancestors + [entry], trustedFrom: ancestors.count - 1).verdict
    }
}

/// Ein bestätigtes Plug-in mit dem Beleg des Eintrags zum Zeitpunkt der Bestätigung.
public struct ServicePluginTrashRequest: Identifiable, Hashable, Sendable {
    public let record: ExtensionRecord
    public let path: String
    let identity: FileIdentity

    public var id: String { record.id }
    public var name: String { ExtensionTexts.label(of: record) }
}

/// Bereit zum Bestätigen oder mit Grund gesperrt.
public enum ServicePluginTrashPreparation: Hashable, Sendable {
    case ready(ServicePluginTrashRequest)
    case blocked(String)
}

public enum ServicePluginTrashOutcome: Hashable, Sendable {
    case trashed
    case notTrashed(String)
}

/// Legt ein Plug-in eines anderen Herstellers über den Finder in den Papierkorb (Spec 2026-11-08 § 5.2): „Zurücklegen“
/// bleibt möglich, für `/Library` fragt der Finder selbst nach dem Passwort. Kernel- und Systemerweiterungen und alles von
/// Apple entfernt Grantry nicht. Beim Öffnen der Bestätigung belegt `prepare` den Eintrag; `moveToTrash` prüft ihn
/// unmittelbar vor dem Apple Event erneut (`ServicePluginPathGuard`).
public struct ServicePluginRemover: Sendable {
    let pathGuard: ServicePluginPathGuard
    let trash: any TrashPerforming

    init(pathGuard: ServicePluginPathGuard, trash: any TrashPerforming) {
        self.pathGuard = pathGuard
        self.trash = trash
    }

    public init(trash: any TrashPerforming) {
        self.init(pathGuard: ServicePluginPathGuard(), trash: trash)
    }

    public func prepare(_ record: ExtensionRecord) -> ServicePluginTrashPreparation {
        guard record.kind.group == .servicePlugins else { return .blocked("Nur Plug-ins in Systemdiensten") }
        if record.signing?.isAppleSigned == true || BundleIDShape.isApple(record.bundleID) {
            return .blocked("Plug-in von Apple")
        }
        guard let path = record.path else { return .blocked("Kein Pfad") }
        let identity = FileIdentity.of(path)
        if case .blocked(let reason) = pathGuard.check(path, identity: identity) { return .blocked(reason) }
        guard let identity else { return .blocked("Nicht vorhanden") }
        return .ready(ServicePluginTrashRequest(record: record, path: path, identity: identity))
    }

    public func moveToTrash(_ request: ServicePluginTrashRequest) async -> ServicePluginTrashOutcome {
        let verify: @Sendable (LeftoverCandidate) -> RemovalVerdict = { [pathGuard] _ in
            pathGuard.check(request.path, identity: request.identity)
        }
        let candidate = LeftoverCandidate(path: request.path, kind: .servicePlugin, confidence: .safe,
                                          identity: request.identity)
        if case .blocked(let reason) = verify(candidate) { return .notTrashed(reason) }
        switch await trash.requestPermission() {
        case .granted: break
        case .denied: return .notTrashed(RemovalExecutor.automationDeniedReason)
        case .unavailable(let reason): return .notTrashed(reason)
        }
        let report = await trash.moveToTrash([candidate], verifying: verify)
        return switch report.outcomes[request.path] {
        case .trashed?, .recreated?: .trashed
        case .blocked(let reason)?, .remaining(let reason)?: .notTrashed(reason)
        case nil: .notTrashed(report.failure ?? "Kein Ergebnis vom Finder")
        }
    }
}
