import Darwin
import Foundation

/// Beleg einer Änderung, die Grantry an einer Agenten-Konfiguration vorgenommen hat (Stufe 2); liegt neben der
/// gesicherten Fassung der Datei und genügt zum Wiederherstellen. Enthält nie Inhalte der Datei.
public struct AgentConfigChange: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: Codable, Hashable, Sendable {
        /// Server entfernt.
        case removedServer
        /// Schalter auf `enabled` gesetzt (vorher das Gegenteil).
        case setEnabled(Bool)
    }

    public let id: UUID
    public let kind: Kind
    public let server: AgentServerReference
    public let changedAt: Date
    /// SHA-256 der gesicherten Fassung (vor der Änderung) und der geschriebenen (danach), hexadezimal.
    public let originalDigest: String
    public let resultDigest: String

    public init(id: UUID, kind: Kind, server: AgentServerReference, changedAt: Date, originalDigest: String, resultDigest: String) {
        self.id = id
        self.kind = kind
        self.server = server
        self.changedAt = changedAt
        self.originalDigest = originalDigest
        self.resultDigest = resultDigest
    }

    /// „„filesystem“ (Claude Code)“.
    public var label: String { "„\(server.name)“ (\(server.locationDescription))" }
}

/// Sicherungen von Agenten-Konfigurationen samt Beleg (Stufe 2), Muster `PlistBackupStore`:
/// `<root>/<UUID>/change.json` (Beleg) und `<root>/<UUID>/original` (die ganze Datei vor der Änderung).
///
/// Die Sicherung enthält die Datei **mit** allen Werten – auch Geheimnissen in `env`/`headers`. Deshalb: Ordner
/// `0700`, Dateien `0600`, ohne ACL (eine von einem Vorfahren geerbte Allow-ACL gewährte Zugriff trotz der Modusbits –
/// sie wird von jedem neu angelegten Ordner und jeder Datei entfernt, von der Datei vor dem ersten Byte, von einer
/// eigenen Ablage auch nachträglich; `AccessControlList`), exklusiv geschrieben, die Ablage vom Time-Machine-Backup
/// ausgenommen (`isExcludedFromBackup`); gelesen wird nur, was vollständig vertrauenswürdig ist (jede Stufe ab `root`
/// gehört dem Benutzer, ist kein Symlink und für niemanden sonst les- oder schreibbar – weder über Modusbits noch über
/// eine gewährende ACL; die Dateien geprüft am geöffneten Deskriptor, `O_NOFOLLOW`, mit Größengrenze) und dessen
/// Prüfsumme zum Beleg passt. Der Scan liest die Sicherungen nie, Texte und Logs nennen nie ihren Inhalt.
///
/// Crash-sicher: Eine Sicherung entsteht in `.<UUID>.partial` und wird erst vollständig unter `<UUID>` umbenannt; ein
/// Absturz dazwischen hinterlässt keinen halben Beleg. Aufbewahrung (`sweep`): je Konfigurationsdatei
/// `retainedChangesPerFile`, insgesamt höchstens `retainedChangesInTotal`, nichts älter als `retentionPeriod` (die eben
/// geschriebene Sicherung bleibt immer). Über die Grenzen hinaus gehen zuerst Schalter-Sicherungen (`.setEnabled`,
/// älteste zuerst), Sicherungen entfernter Server erst danach – nur sie bewahren gelöschte Werte wie Geheimnisse
/// (`retentionOrder`). Unvollständige und beleglose Ordner verschwinden nach `incompleteGracePeriod`.
/// Eine wiederhergestellte Sicherung wird gelöscht. Verdorbene Ordner (Beleg vorhanden, aber nicht vertrauenswürdig
/// oder nicht lesbar) bleiben – sie sind ein Befund, kein Rest. `save`/`commit` laufen nicht nebenläufig (der Runner serialisiert Aktionen).
public struct AgentConfigBackupStore: Sendable {
    public static let retainedChangesPerFile = 5
    /// Obergrenze über alle Konfigurationsdateien; die neuesten bleiben.
    public static let retainedChangesInTotal = 50
    /// Sicherungen verfallen nach 90 Tagen.
    public static let retentionPeriod: TimeInterval = 90 * 24 * 60 * 60
    /// Unvollständige (`.partial`) und beleglose Ordner gelten nach dieser Frist als Reste eines Absturzes.
    static let incompleteGracePeriod: TimeInterval = 10 * 60
    static let changeFileName = "change.json"
    static let originalFileName = "original"
    /// Belege sind wenige hundert Bytes groß.
    static let maximumChangeFileSize = 64 * 1024
    static let untrustedRootReason = "Ablage nicht vertrauenswürdig"

    public let root: URL
    private let now: @Sendable () -> Date

    public init(root: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.root = root
        self.now = now
    }

    /// Legt Sicherung und Beleg an – erst in `.<UUID>.partial`, dann umbenannt. Aufgeräumt wird erst mit `commit(_:)`,
    /// wenn die Änderung geschrieben ist – scheitert sie, bleiben alle älteren Sicherungen erhalten.
    func save(_ change: AgentConfigChange, original: Data) throws(AgentConfigEditError) {
        let staging = root.appending(path: ".\(change.id.uuidString).partial", directoryHint: .isDirectory)
        do {
            try prepareRoot()
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard AccessControlList.remove(atPath: staging.path) else { throw BoundDirectory.posixError() }
            try Self.writeExclusively(original, to: staging.appending(path: Self.originalFileName))
            try Self.writeExclusively(JSONEncoder().encode(change), to: staging.appending(path: Self.changeFileName))
            guard renamex_np(staging.path, folder(for: change.id).path, UInt32(RENAME_EXCL)) == 0 else { throw BoundDirectory.posixError() }
        } catch let error as AgentConfigEditError {
            try? FileManager.default.removeItem(at: staging)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw .writeFailed("Sicherung nicht angelegt: \(error.readableDescription)")
        }
    }

    /// Nach erfolgreichem Ersetzen: räumt Sicherungen derselben Datei über `retainedChangesPerFile` hinaus auf (in
    /// `retentionOrder`, Schalter-Sicherungen zuerst), dann alles Übrige (`sweep`) – die Ablage wird dafür nur einmal
    /// gelesen. `change` selbst bleibt in jedem Fall.
    func commit(_ change: AgentConfigChange) {
        let current = now()
        let others = Self.retentionOrder(changes(), now: current).filter { $0.id != change.id }
        let surplus = Set(others.filter { $0.server.configPath == change.server.configPath }
            .dropFirst(Self.retainedChangesPerFile - 1).map(\.id))
        for id in surplus { delete(id: id) }
        sweep(changes: others.filter { !surplus.contains($0.id) }, retaining: 1, now: current)
    }

    /// Räumt auf – bei `commit` und beim Laden des Verlaufs: unvollständige (`.<UUID>.partial`) und beleglose Ordner
    /// älter als `incompleteGracePeriod`, verfallene Belege (`retentionPeriod`) und alles über `retainedChangesInTotal`
    /// hinaus (in `retentionOrder`: Schalter-Sicherungen gehen vor denen entfernter Server). Belege aus der Zukunft
    /// (vorgehende Uhr) zählen als die ältesten und verfallen, wenn sie weiter als `retentionPeriod` voraus liegen.
    /// Verdorbene Ordner bleiben. Ist die Ablage nicht vertrauenswürdig, passiert nichts.
    /// - Returns: Die verbliebenen Belege wie `changes()`, neueste zuerst – ohne die Ablage erneut zu lesen.
    @discardableResult
    public func sweep() -> [AgentConfigChange] {
        let current = now()
        return sweep(changes: Self.retentionOrder(changes(), now: current), retaining: 0, now: current)
            .sorted { $0.changedAt > $1.changedAt }
    }

    /// `changes` in Aufräum-Reihenfolge (`retentionOrder`); `retaining` Plätze der Obergrenze sind schon vergeben
    /// (beim `commit` an die neue Sicherung). Gibt die behaltenen in derselben Reihenfolge zurück.
    @discardableResult
    private func sweep(changes: [AgentConfigChange], retaining reserved: Int, now current: Date) -> [AgentConfigChange] {
        guard Self.isTrusted(root.path, type: S_IFDIR),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        for name in names where isIncomplete(name) {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            guard let info = FileType.linkStatus(of: folder.path), FileType.isDirectory(info) else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if current.timeIntervalSince(modified) > Self.incompleteGracePeriod { try? FileManager.default.removeItem(at: folder) }
        }
        let (expired, retained) = changes.partitioned { abs(current.timeIntervalSince($0.changedAt)) > Self.retentionPeriod }
        let limit = max(0, Self.retainedChangesInTotal - reserved)
        for change in expired + retained.dropFirst(limit) { delete(id: change.id) }
        return Array(retained.prefix(limit))
    }

    /// Was zuletzt verdrängt wird, steht vorn: erst die Sicherungen entfernter Server, dann die Schalter-Sicherungen –
    /// innerhalb beider die neuesten zuerst, Belege aus der Zukunft ans Ende (eine vorgehende Uhr soll sie nicht
    /// dauerhaft vor alle anderen stellen). Eine Schalter-Sicherung ist jederzeit durch erneutes Schalten ersetzbar,
    /// die eines entfernten Servers ist die einzige Fassung seiner Werte.
    private static func retentionOrder(_ changes: [AgentConfigChange], now: Date) -> [AgentConfigChange] {
        let (removals, toggles) = changes.partitioned { $0.kind == .removedServer }
        return newestFirst(removals, now: now) + newestFirst(toggles, now: now)
    }

    private static func newestFirst(_ changes: [AgentConfigChange], now: Date) -> [AgentConfigChange] {
        let (future, past) = changes.partitioned { $0.changedAt > now }
        return past.sorted { $0.changedAt > $1.changedAt } + future.sorted { $0.changedAt < $1.changedAt }
    }

    /// Alle vertrauenswürdigen Belege, neueste zuerst; fehlt die Ablage, keine.
    public func changes() -> [AgentConfigChange] {
        guard Self.isTrusted(root.path, type: S_IFDIR),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { UUID(uuidString: $0) }.compactMap(change(id:)).sorted { $0.changedAt > $1.changedAt }
    }

    /// Der Beleg mit `id`, wenn er vertrauenswürdig ist und sich selbst so nennt.
    public func change(id: UUID) -> AgentConfigChange? {
        guard let data = trustedContents(of: Self.changeFileName, in: id, maximumSize: Self.maximumChangeFileSize),
              let change = try? JSONDecoder().decode(AgentConfigChange.self, from: data), change.id == id else { return nil }
        return change
    }

    /// Die gesicherte Fassung zu `change`; ihre Prüfsumme muss zum Beleg passen. Ist der Ordner inzwischen weg (etwa
    /// gerade wiederhergestellt oder aufgeräumt), ist das `changeNotFound` – keine verdorbene Sicherung.
    func original(of change: AgentConfigChange) throws(AgentConfigEditError) -> Data {
        guard let data = trustedContents(of: Self.originalFileName, in: change.id, maximumSize: AgentConfigReader.maximumFileSize) else {
            guard FileType.linkStatus(of: folder(for: change.id).path) != nil else { throw .changeNotFound }
            throw .backupUnusable("fehlt oder ist nicht vertrauenswürdig")
        }
        guard AgentConfigFileAccess.digest(of: data) == change.originalDigest else { throw .backupUnusable("Prüfsumme passt nicht") }
        return data
    }

    /// Löscht Sicherung und Beleg; ein unbekannter ist kein Fehler.
    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    // MARK: Intern

    private func folder(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Legt die Ablage an (`0700`). Zu offene Rechte und eine gewährende ACL eines eigenen Ordners werden repariert –
    /// nie die eines fremden oder eines Symlinks –, danach muss die Ablage vertrauenswürdig sein. Der Ausschluss vom
    /// Backup ist Zugabe: Kann das Dateisystem ihn nicht speichern, scheitert daran keine Sicherung.
    private func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let info = FileType.linkStatus(of: root.path), FileType.isDirectory(info), info.st_uid == geteuid() {
            if (info.st_mode & 0o077) != 0 { _ = chmod(root.path, 0o700) }
            if AccessControlList.grantsAccess(atPath: root.path) { AccessControlList.remove(atPath: root.path) }
        }
        guard Self.isTrusted(root.path, type: S_IFDIR) else { throw AgentConfigEditError.backupUnusable(Self.untrustedRootReason) }
        var excluded = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }

    /// Ein Ordnername, der keine fertige Sicherung ist: `.<UUID>.partial` oder `<UUID>` ohne Beleg.
    private func isIncomplete(_ name: String) -> Bool {
        if name.hasPrefix("."), name.hasSuffix(".partial") { return true }
        guard UUID(uuidString: name)?.uuidString == name else { return false }
        return !FileType.exists(atPath: root.appending(path: name).appending(path: Self.changeFileName).path)
    }

    /// Inhalt von `fileName` in der Sicherung `id`, wenn Ablage und Ordner vertrauenswürdig sind und die Datei – am
    /// geöffneten Deskriptor geprüft, ohne Symlink – eine reguläre, eigene, private Datei bis `maximumSize` ist.
    private func trustedContents(of fileName: String, in id: UUID, maximumSize: Int) -> Data? {
        let folder = folder(for: id)
        guard Self.isTrusted(root.path, type: S_IFDIR), Self.isTrusted(folder.path, type: S_IFDIR) else { return nil }
        let descriptor = open(folder.appending(path: fileName).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.isPrivate(info, type: S_IFREG), !AccessControlList.grantsAccess(descriptor: descriptor),
              Int(info.st_size) <= maximumSize else { return nil }
        return try? AgentConfigFileAccess.contents(of: descriptor, expectedSize: Int(info.st_size))
    }

    /// Legt `url` exklusiv an (`0600`), entfernt eine geerbte ACL, bevor das erste Byte geschrieben wird, und sichert.
    private static func writeExclusively(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BoundDirectory.posixError() }
        defer { close(descriptor) }
        guard AccessControlList.remove(from: descriptor) else { throw BoundDirectory.posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Ohne Symlink-Auflösung vom Typ `type`, gehört dem Benutzer, für Gruppe und andere weder les- noch schreibbar –
    /// weder über die Modusbits noch über eine gewährende ACL.
    private static func isTrusted(_ path: String, type: mode_t) -> Bool {
        guard let info = FileType.linkStatus(of: path), isPrivate(info, type: type) else { return false }
        return !AccessControlList.grantsAccess(atPath: path)
    }

    /// Die Modusbits: Typ `type`, gehört dem Benutzer, für Gruppe und andere weder les- noch schreibbar.
    private static func isPrivate(_ info: stat, type: mode_t) -> Bool {
        (info.st_mode & S_IFMT) == type && info.st_uid == geteuid() && (info.st_mode & 0o077) == 0
    }
}

extension Array {
    /// Elemente, auf die `belongsToFirst` zutrifft, und die übrigen – beide in ursprünglicher Reihenfolge.
    fileprivate func partitioned(by belongsToFirst: (Element) -> Bool) -> (first: [Element], second: [Element]) {
        var first: [Element] = []
        var second: [Element] = []
        for element in self {
            if belongsToFirst(element) { first.append(element) } else { second.append(element) }
        }
        return (first, second)
    }
}

extension StorageLocation {
    /// Sicherungen geänderter Agenten-Konfigurationen (`AgentConfigBackupStore`).
    public var agentBackups: AgentConfigBackupStore {
        AgentConfigBackupStore(root: directory.appending(path: "AgentBackups", directoryHint: .isDirectory))
    }
}
