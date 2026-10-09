import Darwin
import Foundation
import GrantryShared

public enum RemovalVerdict: Hashable, Sendable {
    case allowed
    case blocked(String)
}

/// Letzte Prüfung jedes Pfads, bevor er in den Papierkorb darf – beim Suchen **und** unmittelbar vor dem Ausführen
/// (Spec v3 §3 „Niemals angefasst“). Vor dem Papierkorb gilt `check(_:allowingAppleIDOf:)` mit dem Kandidaten: Er muss
/// noch dasselbe Objekt sein wie bei der Suche.
///
/// Erlaubt sind nur (a) direkte Einträge der Reste-Orte (`LibraryLayout.leftoverLocations`) und (b) `.app`-Bundles
/// (Ordner) unter den App-Wurzeln, höchstens `AppInventorySource.maximumFolderDepth` Ordner tief, ohne versteckte Ordner
/// und ohne Bundle im Bundle. Immer gesperrt: Sperrliste, Symlinks (auch im Pfad – nie gefolgt), versteckte Einträge,
/// Einhängepunkte, leere Bestandteile (`//`, abschließender `/`), `.`/`..`, fehlende Pfade, Apple-Kennungen
/// (`BundleIDShape.isApple`) ohne ausdrückliche Freigabe.
///
/// Pfade werden nach Bytes zerlegt (`RawPath`). Sperrorte, Reste-Orte und App-Wurzeln werden am Objekt erkannt
/// (`FileIdentity`, `st_dev`/`st_ino` des Eintrags und aller Elternordner) – APFS faltet Schreibweisen weiter als
/// `lowercased()`; zusätzlich sperrt die Sperrliste auch per Schreibweise (ohne Groß-/Kleinschreibung), falls ein Sperrort
/// fehlt. Ab dem erlaubten Wurzelort werden auch Eigentümer, Schreibrechte und ACL jedes Elternordners geprüft.
/// Der Pfad muss bis auf den letzten Bestandteil kanonisch sein (`realpath` des Elternordners stimmt überein).
public struct RemovalGuard: Sendable {
    /// Ergebnis mit dem geprüften Objekt (für `LeftoverCandidate.identity`).
    enum Inspection: Equatable {
        case allowed(FileIdentity)
        case blocked(String)

        var verdict: RemovalVerdict {
            switch self {
            case .allowed: .allowed
            case .blocked(let reason): .blocked(reason)
            }
        }
    }

    let layout: LibraryLayout

    public init(layout: LibraryLayout = .standard) {
        self.layout = layout
    }

    /// Prüfung ohne Freigabe für Apple-Kennungen.
    public func check(_ path: String) -> RemovalVerdict {
        inspect(path, appleOwnerID: nil).verdict
    }

    /// Prüfung mit Freigabe der eigenen Apple-Kennungen (`com.apple.…`, `group.com.apple.…`) der App, die gerade
    /// entfernt wird – nur wirksam, wenn sie nachweislich von Apple stammt und keine System-App ist
    /// (`AppleAppVerification`).
    public func check(_ path: String, allowingAppleIDOf app: InstalledApp) -> RemovalVerdict {
        inspect(path, appleOwnerID: appleOwnerID(of: app)).verdict
    }

    /// Unmittelbar vor dem Papierkorb: wie `check(_:allowingAppleIDOf:)`, und der Eintrag muss noch dasselbe Objekt
    /// (Gerät, Inode, Art) sein wie bei der Suche – sonst „Eintrag wurde ersetzt“ (auch ohne gespeicherte Identität).
    public func check(_ candidate: LeftoverCandidate, allowingAppleIDOf app: InstalledApp?) -> RemovalVerdict {
        switch inspect(candidate.path, appleOwnerID: app.flatMap(appleOwnerID(of:))) {
        case .allowed(let identity): identity == candidate.identity ? .allowed : .blocked("Eintrag wurde ersetzt")
        case .blocked(let reason): .blocked(reason)
        }
    }

    /// Ein Eintrag auf einem anderen Volume als sein Elternordner ist ein Einhängepunkt.
    static func isMountPoint(_ entry: FileIdentity, below parent: FileIdentity) -> Bool {
        !entry.isOnSameVolume(as: parent)
    }

    /// Bundle-ID (klein) der nachweislich von Apple stammenden `app`; liest die System-Apps nur, wenn nötig.
    func appleOwnerID(of app: InstalledApp) -> String? {
        guard AppleAppVerification.hasAppleProvenance(app), app.bundleID.map(AppleEntryName.isApple) == true else { return nil }
        return AppleAppVerification(catalog: SystemAppCatalog(layout: layout)).appleOwnerID(of: app)
    }

    /// `appleOwnerID`: Bundle-ID (klein), deren Apple-Kennungen freigegeben sind (`AppleAppVerification`).
    func inspect(_ path: String, appleOwnerID: String?) -> Inspection {
        guard let components = RawPath.components(of: path) else { return .blocked("Ungültiger Pfad") }
        if isBlockedBySpelling(components) { return .blocked("Geschützter Ort") }
        guard let entry = FileIdentity.of(path) else { return .blocked("Nicht vorhanden") }
        if entry.type == .symbolicLink { return .blocked("Symbolischer Link") }
        // Gerät und Inode von `/` und jedem Elternordner bis zum Eintrag (`chain.last == entry`).
        guard let chain = Self.identities(along: components) else { return .blocked("Nicht vorhanden") }
        let blocked = layout.blockedPaths.compactMap(FileIdentity.of)
        if chain.contains(where: { link in blocked.contains { $0.isSameObject(as: link) } }) {
            return .blocked("Geschützter Ort")
        }
        let parentPath = RawPath.path(of: components.dropLast())
        guard let resolvedParent = Self.resolvedPath(parentPath), resolvedParent.lowercased() == parentPath.lowercased() else {
            return .blocked("Symbolischer Link im Pfad")
        }
        let name = components[components.count - 1], parent = chain[chain.count - 2]
        if RawPath.isHidden(name) { return .blocked("Versteckter Eintrag") }
        if Self.isMountPoint(entry, below: parent) { return .blocked("Einhängepunkt") }
        // Ein Ort selbst (auch `Preferences/ByHost` als Eintrag von `Preferences`), eine App-Wurzel oder ein Ordner darüber
        // ist nie ein Rest.
        if anchors.contains(where: { $0.isSameObject(as: entry) }) { return .blocked("Außerhalb der erlaubten Orte") }
        let locations = layout.leftoverLocations.compactMap { FileIdentity.of($0.directory) }
        if locations.contains(where: { $0.isSameObject(as: parent) }) {
            // Apple-Kennungen im Eintragsnamen (so weit wie `BundleIDShape.isApple`, Review N9) nur mit Freigabe für
            // die eigene `com.apple.`-Kennung der entfernten App (der Name eines App-Bundles ist keine Kennung).
            if BundleIDShape.isApple(name) {
                guard let appleID = AppleEntryName.identifier(in: name), appleOwnerID.map({ BundleIDOwnership.isOwned(appleID, by: $0) }) == true else {
                    return .blocked("Apple-Eintrag")
                }
            }
            return Self.inspectDirectoryChain(components, chain: chain, trustedFrom: chain.count - 2)
        }
        if entry.type == .directory, let rootDepth = appRootDepth(components, chain: chain) {
            return Self.inspectDirectoryChain(components, chain: chain, trustedFrom: rootDepth)
        }
        return .blocked("Außerhalb der erlaubten Orte")
    }

    /// Reste-Orte, App-Wurzeln und alle Ordner darüber (soweit vorhanden).
    private var anchors: [FileIdentity] {
        (layout.leftoverLocations.map(\.directory) + layout.appRoots).flatMap { directory in
            RawPath.prefixes(of: RawPath.components(of: directory) ?? []).compactMap(FileIdentity.of)
        }
    }

    /// Sperrliste per Schreibweise (bestandteilweise, ohne Groß-/Kleinschreibung) – greift auch für fehlende Sperrorte.
    private func isBlockedBySpelling(_ components: [String]) -> Bool {
        let lowered = components.map { $0.lowercased() }
        return layout.blockedPaths.contains { blocked in
            guard let blockedComponents = RawPath.components(of: blocked) else { return false }
            return lowered.count >= blockedComponents.count
                && zip(blockedComponents, lowered).allSatisfy { $0.lowercased() == $1 }
        }
    }

    /// `.app` unter einer App-Wurzel (am Objekt erkannt), höchstens `AppInventorySource.maximumFolderDepth` Ordner tief, Ordner weder
    /// versteckt noch Bundle.
    private func appRootDepth(_ components: [String], chain: [FileIdentity]) -> Int? {
        guard RawPath.hasExtension(components[components.count - 1], "app") else { return nil }
        let roots = layout.appRoots.compactMap(FileIdentity.of)
        // `chain[depth]` ist der Ordner aus den ersten `depth` Bestandteilen.
        guard let rootDepth = chain.indices.dropLast().first(where: { depth in
            roots.contains { $0.isSameObject(as: chain[depth]) }
        }) else { return nil }
        let folders = components[rootDepth ..< components.count - 1]
        guard folders.count <= AppInventorySource.maximumFolderDepth,
              !folders.contains(where: { RawPath.isHidden($0) || RawPath.hasExtension($0, "app") }) else { return nil }
        return rootDepth
    }

    /// Öffnet dieselbe Kette ab `/` relativ zu gebundenen Deskriptoren, ohne Symlinks zu folgen. Ab dem erlaubten
    /// Wurzelort bis einschließlich Elternordner müssen Eigentümer, Modus und ACL vertrauenswürdig sein. Vorfahren
    /// außerhalb dieses Bereichs werden nur auf Identität geprüft (auch Scratch-Wurzeln dürfen unter `/tmp` liegen).
    private static func inspectDirectoryChain(_ components: [String], chain: [FileIdentity], trustedFrom rootDepth: Int) -> Inspection {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .blocked("Nicht vorhanden") }
        defer { close(descriptor) }
        for depth in 0..<components.count {
            var info = stat()
            guard fstat(descriptor, &info) == 0, FileIdentity(info) == chain[depth] else {
                return .blocked("Eintrag wurde ersetzt")
            }
            if depth >= rootDepth {
                guard hasTrustedDirectoryPermissions(info),
                      !AccessControlList.grantsModification(toOthersThan: geteuid(), descriptor: descriptor) else {
                    return .blocked("Ordner fremd beschreibbar")
                }
            }
            if depth < components.count - 1 {
                let next = openat(descriptor, components[depth], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { return .blocked("Eintrag wurde ersetzt") }
                close(descriptor)
                descriptor = next
            }
        }
        var entry = stat()
        guard fstatat(descriptor, components[components.count - 1], &entry, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(entry) == chain.last else { return .blocked("Eintrag wurde ersetzt") }
        return .allowed(FileIdentity(entry))
    }

    /// Nur root oder der ausführende Benutzer dürfen Eigentümer sein; Other-Write ist immer gesperrt. Gruppenschreibrecht
    /// ist ausschließlich bei root-eigenen Ordnern mit macOS-Systemgruppe `wheel` (0) oder `admin` (80) erlaubt:
    /// `/Applications` ist regulär `root:admin 0775`, und diese Gruppen liegen bereits innerhalb der Admin-Vertrauensgrenze.
    static func hasTrustedDirectoryPermissions(_ info: stat) -> Bool {
        guard info.st_uid == 0 || info.st_uid == geteuid(), info.st_mode & 0o002 == 0 else { return false }
        return info.st_mode & 0o020 == 0 || (info.st_uid == 0 && (info.st_gid == 0 || info.st_gid == 80))
    }

    /// `lstat` von `/` und jedem Präfix aus `components`; `nil`, wenn eines fehlt.
    private static func identities(along components: [String]) -> [FileIdentity]? {
        let identities = RawPath.prefixes(of: components).compactMap(FileIdentity.of)
        return identities.count == components.count + 1 ? identities : nil
    }

    /// `realpath` ohne Ersatzwert: `nil`, wenn sich der Pfad nicht auflösen lässt.
    private static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
