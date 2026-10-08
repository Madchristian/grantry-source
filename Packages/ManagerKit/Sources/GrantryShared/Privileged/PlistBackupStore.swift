import Foundation

/// Fehler bei Sicherung oder Wiederherstellung einer Plist.
public enum BackupError: LocalizedError, Equatable {
    case notManaged(String)
    case outsideStore(String)
    case destinationExists(String)
    case unrestorableName(String)
    case untrustedStore(String)
    case invalidContent(String)
    case superseded(String)
    /// Die gesicherte Datei ist unter ihrem Namen nicht mehr dasselbe Dateiobjekt mit demselben Inhalt (ersetzt,
    /// in-place umgeschrieben, verlinkt oder entfernt).
    case sourceChanged(String)
    /// Die Plist trägt nicht mehr den Fingerabdruck aus dem Scan (#156): ersetzt oder umgeschrieben, bevor sie gesichert
    /// wurde.
    case changedSinceScan(String)

    public var errorDescription: String? {
        switch self {
        case .notManaged(let path): "Nicht gesicherter Speicherort: \(path)"
        case .outsideStore(let path): "Kein Backup dieses Speichers: \(path)"
        case .destinationExists(let path): "Wiederherstellen nicht möglich, Datei existiert bereits: \(path)"
        case .unrestorableName(let path): "Dateiname wäre nicht wiederherstellbar, keine Sicherung angelegt: \(path)"
        case .untrustedStore(let path): "Backup nicht vertrauenswürdig (fremder Eigentümer oder für andere beschreibbar): \(path)"
        case .invalidContent(let path): "Backup enthält kein zulässiges launchd-Label: \(path)"
        case .superseded(let path): "Nicht das neueste Backup dieser Datei; wiederherstellbar ist nur das neueste: \(path)"
        case .sourceChanged(let path):
            "Datei seit der Sicherung ersetzt, verändert oder entfernt, nichts gelöscht (die Sicherung bleibt) – bitte neu scannen: \(path)"
        case .changedSinceScan(let path):
            "Datei hat sich seit dem letzten Scan geändert, nichts gesichert oder gelöscht – bitte neu scannen: \(path)"
        }
    }
}

/// Angelegte Sicherung einer Plist samt Bindung an genau das gesicherte Dateiobjekt **und** dessen gesicherten Inhalt,
/// die `remove()` löscht.
///
/// Hält das verwaltete Verzeichnis als Dateideskriptor offen (`BoundPlistFile`). Ein nachträglicher Austausch des
/// Verzeichnisses – etwa `~/Library/LaunchAgents` gegen einen Symlink auf ein fremdes Verzeichnis – erreicht
/// `remove()` daher nicht; ein Austausch der Datei selbst (andere Inode, Symlink, entfernt) ebenso wie ein
/// In-place-Umschreiben (andere Bytes, Größe, ctime) lässt `remove()` mit `BackupError.sourceChanged` abbrechen, ohne
/// etwas zu löschen – gelöscht wird nur, was die Sicherung enthält (#156). Der Deskriptor schließt sich beim Freigeben.
public final class PendingPlistRemoval: Sendable {
    /// Pfad der angelegten Sicherung; `PlistBackupStore.restore(_:)` nimmt ihn an.
    public let backupPath: String
    /// Kanonischer Pfad der gesicherten Datei (für Meldungen).
    public var sourcePath: String { source.sourcePath }
    private let source: BoundPlistFile

    fileprivate init(source: BoundPlistFile, backupPath: String) {
        self.source = source
        self.backupPath = backupPath
    }

    /// Löscht genau die gesicherte Datei: Unter ihrem Namen im gebundenen Verzeichnis muss noch dieselbe reguläre
    /// Datei (Gerät und Inode) mit unverändertem Fingerabdruck (Änderungsdatum, ctime, Größe) und denselben Bytes wie
    /// in der Sicherung liegen, sonst `BackupError.sourceChanged` – und nichts wird gelöscht, die Sicherung bleibt.
    /// Ein zweiter Aufruf nach Erfolg scheitert ebenso (`sourceChanged`).
    ///
    /// - Note: Zwischen Prüfung und Löschung (`unlinkat`) bleibt ein Fenster von wenigen Systemaufrufen, aber nur
    ///   innerhalb des gebundenen verwalteten Verzeichnisses: Wer dort Schreibrecht hat (Helper: nur root;
    ///   Benutzer-Speicher: der Benutzer selbst), könnte in diesem Moment die Datei umschreiben oder einen anderen
    ///   Eintrag unter diesen Namen verschieben – nie etwas außerhalb des Verzeichnisses. Dass die Inode-Nummer der
    ///   gesicherten Datei nicht sofort neu vergeben wird, gilt auf APFS; andere Dateisysteme garantieren das nicht.
    public func remove() throws {
        try source.unlinkIfUnchanged()
    }

    /// Ob `path` – der Pfad, den `launchctl bootstrap` erhalten soll – noch genau auf die gesicherten Bytes im
    /// gebundenen Verzeichnis führt (Rollback, #166; Prüfung wie `BoundPlistContents.isUnchanged()`).
    public func hasBackedUpContents(at path: String) throws -> Bool {
        try source.isUnchanged(reachedVia: path)
    }
}

/// Inhalt einer Plist, gelesen über ihr gebundenes Verzeichnis (Deskriptor, ohne Symlinks) – Grundlage des Rollbacks
/// nach einem `bootout` (#166): Wieder geladen wird nur, wenn am Pfad noch genau diese Bytes liegen.
///
/// Für Plists, die nicht in einem `PlistBackupStore` gesichert werden (Systemagenten der App, deren Sicherung der
/// Helper erst nach dem `bootout` anlegt); `PendingPlistRemoval.hasBackedUpContents(at:)` leistet dasselbe für
/// gesicherte.
public final class BoundPlistContents: Sendable {
    private let file: BoundPlistFile
    /// Pfad wie übergeben – derselbe, den `launchctl bootstrap` beim Rollback erhält.
    private let path: String

    /// Liest die Plist unter `path`; das Elternverzeichnis wird kanonisch (`realpath`) aufgelöst und dann ohne Symlinks
    /// gebunden. Trägt sie nicht `expected` (Scan-Fingerabdruck), wirft es `BackupError.changedSinceScan`; ist dort keine
    /// reguläre Datei, `BackupError.sourceChanged`.
    public init(path: String, expecting expected: FileFingerprint?) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let directory = PlistBackupStore.canonicalPath(url.deletingLastPathComponent().path)
        file = try BoundPlistFile(
            directory: directory, fileName: url.lastPathComponent, sourcePath: url.path, expected: expected
        )
        self.path = path
    }

    /// Ob der Pfad aus `init` noch genau auf die gelesenen Bytes im gebundenen Verzeichnis führt: Sein Elternverzeichnis
    /// muss weiterhin kanonisch auf das gebundene auflösen, ohne Symlinks neu geöffnet **dasselbe** Verzeichnisobjekt sein
    /// (Gerät und Inode), und die Datei darin – über das neu geöffnete Verzeichnis gelesen – genau diese Bytes enthalten.
    /// Ein umbenanntes und durch ein neues ersetztes Verzeichnis zählt so als geändert, auch wenn die alte Datei im
    /// gehaltenen Deskriptor unverändert ist.
    public func isUnchanged() throws -> Bool {
        try file.isUnchanged(reachedVia: path)
    }
}

/// Identität eines regulären Dateiobjekts: Gerät und Inode.
private struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    /// `nil`, wenn `info` keine reguläre Datei beschreibt.
    init?(regular info: stat) {
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// Eine über ihr Verzeichnis gebundene Plist: gebundener Verzeichnis-Deskriptor (`BoundDirectory`), Dateiname,
/// Identität, Fingerabdruck und der Inhalt, wie er aus genau diesem Dateiobjekt gelesen wurde.
private final class BoundPlistFile: Sendable {
    let contents: Data
    /// Kanonischer Pfad der Datei, nur für Meldungen.
    let sourcePath: String
    private let directory: BoundDirectory
    private let fileName: String
    private let identity: FileIdentity
    /// Fingerabdruck (`fstat`) des Dateiobjekts, aus dem `contents` stammt.
    private let fingerprint: FileFingerprint

    /// Öffnet `directory` komponentenweise ab `/` ohne Symlinks zu folgen (`BoundDirectory`) und liest darin
    /// `fileName` (`readSnapshot`). Ist das Objekt keine reguläre Datei oder ändert es sich während des Lesens, wirft
    /// es `BackupError.sourceChanged(sourcePath)`. Trägt es nicht den Fingerabdruck `expected` aus dem Scan, wirft es
    /// `BackupError.changedSinceScan(sourcePath)` – gebunden und gesichert werden so nur genau die Bytes mit dem
    /// erwarteten Fingerabdruck (#156).
    ///
    /// `directory` muss der bereits als vertrauenswürdig feststehende kanonische Pfad sein (nicht erst jetzt aus der
    /// Quelle aufgelöst), sonst würde ein zwischenzeitlich eingehängter Symlink mit aufgelöst statt abgelehnt.
    init(directory: String, fileName: String, sourcePath: String, expected: FileFingerprint?) throws {
        self.directory = try BoundDirectory(path: directory)
        self.fileName = fileName
        self.sourcePath = sourcePath
        guard let snapshot = try Self.readSnapshot(fileName, in: self.directory) else {
            throw BackupError.sourceChanged(sourcePath)
        }
        if let expected, !expected.matches(snapshot.fingerprint) { throw BackupError.changedSinceScan(sourcePath) }
        identity = snapshot.identity
        fingerprint = snapshot.fingerprint
        contents = snapshot.contents
    }

    /// Löscht `fileName` im gebundenen Verzeichnis, wenn dort noch dasselbe Dateiobjekt mit unverändertem
    /// Fingerabdruck und denselben Bytes liegt und der Name unmittelbar vor dem Löschen noch auf dieses Objekt zeigt;
    /// sonst `BackupError.sourceChanged(sourcePath)` (auch wenn sie verschwunden ist).
    func unlinkIfUnchanged() throws {
        guard let current = try Self.readSnapshot(fileName, in: directory),
              current.identity == identity, current.fingerprint == fingerprint, current.contents == contents
        else { throw BackupError.sourceChanged(sourcePath) }
        var info = stat()
        guard fstatat(directory.descriptor, fileName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard errno == ENOENT else { throw Self.posixError() }
            throw BackupError.sourceChanged(sourcePath)
        }
        guard FileIdentity(regular: info) == identity else { throw BackupError.sourceChanged(sourcePath) }
        guard unlinkat(directory.descriptor, fileName, 0) == 0 else { throw Self.posixError() }
    }

    /// Ob `path` (für `launchctl bootstrap`) noch genau zu `contents` führt – unabhängig von Identität und Zeitstempeln
    /// der Datei (dieselbe Konfiguration), aber nur über **dasselbe** Verzeichnisobjekt (#166):
    /// 1. `path` endet auf `fileName`, und sein Elternverzeichnis löst (`realpath`, wie launchd es auflöst) auf den
    ///    gebundenen kanonischen Pfad auf – ein eingehängter Symlink fällt so auf;
    /// 2. dieser Pfad, jetzt erneut ohne Symlinks geöffnet (`BoundDirectory`), ist dasselbe Verzeichnis (Gerät und Inode)
    ///    wie das gebundene – ein umbenanntes und neu angelegtes fällt so auf;
    /// 3. die Datei, über das **neu geöffnete** Verzeichnis gelesen, enthält genau `contents`.
    /// Sonst `false` (auch wenn etwas fehlt, ein Symlink ist oder sich beim Lesen ändert).
    func isUnchanged(reachedVia path: String) throws -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == fileName,
              let resolved = realpath(url.deletingLastPathComponent().path, nil) else { return false }
        defer { free(resolved) }
        guard String(cString: resolved) == directory.path,
              let reopened = try? BoundDirectory(path: directory.path),
              Self.isSameDirectory(reopened.descriptor, directory.descriptor) else { return false }
        return try Self.readSnapshot(fileName, in: reopened)?.contents == contents
    }

    /// Ob beide Deskriptoren dasselbe Verzeichnisobjekt bezeichnen (Gerät und Inode).
    private static func isSameDirectory(_ first: Int32, _ second: Int32) -> Bool {
        guard let first = try? status(of: first), let second = try? status(of: second) else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    /// Identität, Fingerabdruck und Inhalt eines Dateiobjekts – gelesen über **einen** Deskriptor.
    private struct Snapshot {
        let identity: FileIdentity
        let fingerprint: FileFingerprint
        let contents: Data
    }

    /// Öffnet `fileName` relativ zu `directory` ohne Symlink (`O_NOFOLLOW`, `O_NONBLOCK` gegen blockierende FIFOs) und
    /// liest es bis zum Ende. `nil`, wenn dort nichts oder ein Symlink liegt, keine reguläre Datei, oder wenn sich der
    /// Fingerabdruck während des Lesens ändert (die Bytes gehörten dann zu keinem festen Stand).
    private static func readSnapshot(_ fileName: String, in directory: BoundDirectory) throws -> Snapshot? {
        let descriptor = openat(directory.descriptor, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP { return nil }
            throw posixError()
        }
        defer { close(descriptor) }
        let before = try status(of: descriptor)
        guard let identity = FileIdentity(regular: before) else { return nil }
        let contents = try readToEnd(descriptor)
        let fingerprint = FileFingerprint(status: before)
        guard FileFingerprint(status: try status(of: descriptor)) == fingerprint else { return nil }
        return Snapshot(identity: identity, fingerprint: fingerprint, contents: contents)
    }

    /// `fstat` von `descriptor`.
    private static func status(of descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        return info
    }

    /// Liest `descriptor` bis zum Ende.
    private static func readToEnd(_ descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw posixError()
            }
            data.append(buffer, count: count)
        }
    }

    /// `POSIXError` zu `code` (standardmäßig das aktuelle `errno`).
    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        BoundDirectory.posixError(code)
    }
}

/// Sichert launchd-Plists vor dem Löschen und stellt sie wieder her.
///
/// Ablage: `<root>/<yyyyMMdd-HHmmss-SSS>/<Name des verwalteten Verzeichnisses>/<Datei>`. Der Verzeichnisname
/// (z. B. `LaunchDaemons`) identifiziert beim Wiederherstellen das Zielverzeichnis; die letzten Pfadkomponenten
/// der verwalteten Verzeichnisse müssen daher eindeutig sein. `restore(_:)` verlangt exakt dieses Layout und
/// lehnt Symlinks auf jeder Stufe unterhalb von `root` sowie Pfade außerhalb des aufgelösten `root` ab.
///
/// Je Datei (Verzeichnisname + Dateiname) bleiben höchstens `retainedBackupCount` Backups erhalten; wiederherstellbar
/// ist nur das jeweils neueste. Ältere Backups entsprechen einem überholten Zustand und würden ihn sonst zurückholen.
///
/// Sichern und Löschen gehören zusammen: `backupForRemoval(_:expecting:)` legt die Sicherung an, prüft sie mit
/// denselben Bedingungen wie `restore(_:)` und liefert eine `PendingPlistRemoval`, deren `remove()` genau das
/// gesicherte Dateiobjekt mit genau dem gesicherten Inhalt löscht – so ist jede Löschung umkehrbar und trifft nie eine
/// inzwischen untergeschobene oder umgeschriebene Datei.
///
/// Labels (Dateiname und Inhalt) prüft `PrivilegedOperationPolicy.validateLabel(_:)` – samt Sperre für `com.apple.*`.
/// Nur der Benutzer-Speicher (`allowsAppleLabels`) prüft allein die Syntax: Dort entscheidet die App anhand der
/// Herkunft, ob ein Apple-Label echt ist, und ein als Apple getarnter Agent muss sich entfernen lassen. Der
/// System-Speicher des Helpers bleibt strikt.
public struct PlistBackupStore: Sendable {
    /// Höchstzahl aufbewahrter Backups je Datei.
    public static let retainedBackupCount = 5

    public let root: URL
    public let managedDirectories: [String]
    /// Ob `com.apple.`-Labels gesichert und wiederhergestellt werden dürfen (nur Benutzer-Speicher).
    public let allowsAppleLabels: Bool
    /// Kanonische Pfade (`canonicalPath`, bei der Erzeugung bestimmt) zu `managedDirectories`, gleiche Reihenfolge;
    /// sie werden beim Sichern komponentenweise ohne Symlink-Auflösung geöffnet. `resolvingSymlinksInPath()` lässt
    /// `/var` → `/private/var` ungelöst, daher der eigene Satz.
    private let canonicalManagedDirectories: [String]
    private let now: @Sendable () -> Date

    public init(
        root: URL, managedDirectories: [String], allowsAppleLabels: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(Set(managedDirectories.map { URL(fileURLWithPath: $0).lastPathComponent }).count == managedDirectories.count,
                     "Verzeichnisnamen müssen eindeutig sein")
        self.root = root
        self.managedDirectories = managedDirectories.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        canonicalManagedDirectories = self.managedDirectories.map(Self.canonicalPath)
        self.allowsAppleLabels = allowsAppleLabels
        self.now = now
    }

    /// Backups der App für `~/Library/LaunchAgents`, standardmäßig in
    /// `~/Library/Application Support/Grantry/Backups`.
    public static func user(home: String = NSHomeDirectory()) -> PlistBackupStore {
        user(root: URL(fileURLWithPath: home + "/Library/Application Support/Grantry/Backups", isDirectory: true), home: home)
    }

    /// Backups der App für `~/Library/LaunchAgents` unter `root` (z. B. im Ablageort einer zweiten Instanz).
    public static func user(root: URL, home: String = NSHomeDirectory()) -> PlistBackupStore {
        PlistBackupStore(root: root, managedDirectories: [home + "/Library/LaunchAgents"], allowsAppleLabels: true)
    }

    /// Backups des Helpers für `/Library/LaunchAgents` und `/Library/LaunchDaemons` (root-eigen).
    public static let system = PlistBackupStore(
        root: URL(fileURLWithPath: "/Library/Application Support/Grantry/Backups", isDirectory: true),
        managedDirectories: [
            PrivilegedOperationPolicy.systemLaunchAgentsDirectory, PrivilegedOperationPolicy.systemLaunchDaemonsDirectory,
        ]
    )

    /// Sichert die Plist ins Backup und liefert die an genau dieses Dateiobjekt und seinen Inhalt gebundene Löschung.
    /// Das Original bleibt unverändert, bis der Aufrufer `PendingPlistRemoval.remove()` ruft.
    ///
    /// Mit `expected` (Fingerabdruck aus dem Scan, `AutostartItem.plistFingerprint`) wird nur gesichert, wenn die
    /// geöffnete Datei genau diesen Fingerabdruck trägt; sonst `BackupError.changedSinceScan`, ohne Sicherung (#156).
    /// Geprüft wird das geöffnete Dateiobjekt selbst, nicht erst der Pfad: Ein Austausch zwischen einer früheren
    /// Prüfung und dem Öffnen fällt so auf.
    ///
    /// `plistPath` muss der von `PrivilegedOperationPolicy.validatePlistPath(_:managedDirectories:)`
    /// zurückgegebene kanonische Pfad sein. Das verwaltete Verzeichnis wird über seinen bei der Erzeugung des Speichers
    /// festgelegten kanonischen Pfad komponentenweise ohne Symlink-Auflösung als Deskriptor geöffnet – ein inzwischen
    /// eingehängter Symlink lässt das scheitern statt ihm zu folgen – und die Plist relativ dazu (`O_NOFOLLOW`);
    /// gesichert werden die Bytes genau dieses Dateiobjekts, exklusiv geschrieben (nie überschreibend). Neu angelegte
    /// Backup-Ordner erhalten den Modus `0700`, die Kopie unabhängig von der Quelle `0644` (als root zusätzlich
    /// `root:wheel`); misslingt das, wird die Kopie gelöscht und der Fehler weitergereicht.
    ///
    /// Eine Löschung muss umkehrbar sein, daher wird nur gesichert, was `restore(_:)` annähme: Ein bereits
    /// vorhandener `root`, der kein vertrauenswürdiges Verzeichnis ist, wird vorab abgelehnt (`untrustedStore`), ein
    /// Dateiname, den `restore(_:)` ablehnen würde, ebenfalls (`unrestorableName`). Der Zeitstempel-Ordner liegt
    /// stets nach dem neuesten vorhandenen Backup derselben Datei (`removalTimestamp`), damit die neue Sicherung
    /// auch nach einem Uhrsprung die wiederherstellbare ist. Nach dem Schreiben durchläuft die Kopie exakt die
    /// Prüfung von `restore(_:)` (`restorableBackup(at:)`: Layout, Vertrauenskette, `Label` im Inhalt, neuestes
    /// Backup); scheitert sie, wird die Kopie samt leer gewordener Ordner entfernt und der Fehler weitergereicht.
    /// Erst dann werden ältere, vertrauenswürdige Backups derselben Datei über `retainedBackupCount` hinaus gelöscht
    /// (samt dadurch leer gewordener Ordner); nicht vertrauenswürdige Einträge bleiben unberührt.
    public func backupForRemoval(_ plistPath: String, expecting expected: FileFingerprint? = nil) throws -> PendingPlistRemoval {
        let source = URL(fileURLWithPath: plistPath).resolvingSymlinksInPath()
        let directory = source.deletingLastPathComponent().path
        let fileName = source.lastPathComponent
        guard let managedIndex = managedDirectories.firstIndex(of: directory) else { throw BackupError.notManaged(plistPath) }
        guard isRestorableFileName(fileName) else { throw BackupError.unrestorableName(plistPath) }
        let rootPath = root.resolvingSymlinksInPath().path
        if Self.exists(rootPath), !Self.isTrusted(rootPath, expecting: S_IFDIR) { throw BackupError.untrustedStore(rootPath) }

        let bound = try BoundPlistFile(
            directory: canonicalManagedDirectories[managedIndex], fileName: fileName, sourcePath: source.path, expected: expected
        )
        let directoryName = URL(fileURLWithPath: directory).lastPathComponent
        let folder = root
            .appending(path: removalTimestamp(directoryName: directoryName, fileName: fileName))
            .appending(path: directoryName)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let destination = folder.appending(path: fileName)
        try bound.contents.write(to: destination, options: .withoutOverwriting)
        do {
            try Self.normaliseOrRemove(destination)
            _ = try restorableBackup(at: destination.path)
        } catch {
            Self.removeBackupAndEmptyFolders(destination.path)
            throw error
        }
        pruneBackups(directoryName: directoryName, fileName: fileName, keeping: destination.resolvingSymlinksInPath().path)
        return PendingPlistRemoval(source: bound, backupPath: destination.path)
    }

    /// Zeitstempel für eine neue Sicherung: `now()`, mindestens aber eine Millisekunde nach dem neuesten
    /// vertrauenswürdigen Backup derselben Datei – die Sicherung ist der aktuelle Zustand und muss das neueste
    /// (allein wiederherstellbare) Backup werden, auch wenn die Uhr zurückgesprungen ist.
    private func removalTimestamp(directoryName: String, fileName: String) -> String {
        let current = Self.timestamp(now())
        guard let newest = trustedBackups(directoryName: directoryName, fileName: fileName).first
            .map({ URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }),
              newest >= current, let newestDate = Self.date(fromTimestamp: newest) else { return current }
        return Self.timestamp(newestDate.addingTimeInterval(0.001))
    }

    /// Kopiert ein Backup an seinen Ursprungsort zurück und liefert diesen Pfad. Überschreibt nie.
    ///
    /// Nimmt nur an, was `restorableBackup(at:)` als wiederherstellbar prüft (Layout, Vertrauenskette, neuestes
    /// Backup, `Label` im Inhalt) – dieselbe Prüfung, die `backupForRemoval(_:expecting:)` vor jeder Löschung anwendet. Genau
    /// der dort gelesene Inhalt wird exklusiv (nie überschreibend) geschrieben (`destinationExists`). Setzt danach
    /// die Rechte auf `0644`; läuft der Prozess als root (`geteuid() == 0`), zusätzlich Eigentümer und Gruppe auf
    /// `root:wheel`. Schlägt das fehl, wird die Kopie wieder gelöscht und der Fehler weitergereicht.
    public func restore(_ backupPath: String) throws -> String {
        let backup = try restorableBackup(at: backupPath)
        let destination = backup.destination
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BackupError.destinationExists(destination.path)
        }
        do {
            try backup.contents.write(to: destination, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            throw BackupError.destinationExists(destination.path)
        }
        // Keine Plist mit ungeprüften Rechten/Eigentümer im launchd-Verzeichnis zurücklassen.
        try Self.normaliseOrRemove(destination)
        return destination.path
    }

    /// Ein Backup, das `restore(_:)` annimmt: sein Zielort und der geprüfte Inhalt.
    private struct RestorableBackup {
        let destination: URL
        let contents: Data
    }

    /// Prüft `backupPath` so, wie `restore(_:)` es verlangt, und liefert Zielort und Inhalt.
    ///
    /// Verlangt exakt das Layout `<root>/<Zeitstempel>/<Verzeichnisname>/<Datei>.plist` (Zeitstempel im
    /// Format `yyyyMMdd-HHmmss-SSS`, Dateiname = zulässiges launchd-Label mit `.plist`-Endung), eine reguläre,
    /// nicht symbolisch verknüpfte Datei sowie einen nach Symlink-Auflösung innerhalb des aufgelösten
    /// `root` liegenden Pfad (`outsideStore`). Jede Stufe von `root` bis zur Datei (einschließlich) muss dem
    /// ausführenden Benutzer gehören und darf weder für Gruppe noch für andere beschreibbar sein (`untrustedStore`) –
    /// als root darf sonst niemand ein Backup unterschieben. Gibt es ein neueres vertrauenswürdiges Backup
    /// derselben Datei, wird abgelehnt (`superseded`). Der Inhalt wird einmal gelesen und sein `Label` geprüft
    /// (`invalidContent`).
    ///
    /// „Zulässig“ heißt für Dateiname und `Label` (`isValidLabel`): im System-Speicher des Helpers
    /// `PrivilegedOperationPolicy.validateLabel(_:)` samt Sperre für `com.apple.*`; im Benutzer-Speicher
    /// (`allowsAppleLabels`) nur deren Syntaxprüfung, damit ein entfernter, als Apple getarnter Agent
    /// wiederherstellbar bleibt.
    private func restorableBackup(at backupPath: String) throws -> RestorableBackup {
        guard !backupPath.hasSuffix("/") else { throw BackupError.outsideStore(backupPath) }
        let input = URL(fileURLWithPath: backupPath).standardizedFileURL
        guard let values = try? input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, values.isRegularFile == true else {
            throw BackupError.outsideStore(backupPath)
        }

        let resolved = input.resolvingSymlinksInPath()
        let resolvedRootPath = root.resolvingSymlinksInPath().path
        let rootPrefix = resolvedRootPath.hasSuffix("/") ? resolvedRootPath : resolvedRootPath + "/"
        guard resolved.path.hasPrefix(rootPrefix) else { throw BackupError.outsideStore(backupPath) }

        let relative = String(resolved.path.dropFirst(rootPrefix.count))
        let components = relative.components(separatedBy: "/")
        guard components.count == 3,
              Self.isTimestamp(components[0]),
              isRestorableFileName(components[2]),
              let directory = managedDirectories.first(where: { URL(fileURLWithPath: $0).lastPathComponent == components[1] })
        else {
            throw BackupError.outsideStore(backupPath)
        }

        if let untrusted = Self.firstUntrusted(root: resolvedRootPath, components: components) {
            throw BackupError.untrustedStore(untrusted)
        }
        guard trustedBackups(directoryName: components[1], fileName: components[2]).first == resolved.path else {
            throw BackupError.superseded(backupPath)
        }
        let contents = try validatedContents(of: resolved, backupPath: backupPath)
        return RestorableBackup(destination: URL(fileURLWithPath: directory).appending(path: components[2]), contents: contents)
    }

    /// Vertrauenswürdige Backups von `fileName` aus dem verwalteten Verzeichnis `directoryName` als aufgelöste
    /// Pfade, neueste zuerst (Zeitstempel sortieren lexikografisch chronologisch). Berücksichtigt nur reguläre,
    /// nicht symbolisch verknüpfte Dateien, deren ganze Pfadkette `isTrusted` erfüllt.
    private func trustedBackups(directoryName: String, fileName: String) -> [String] {
        let rootPath = root.resolvingSymlinksInPath().path
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: rootPath) else { return [] }
        return entries.filter(Self.isTimestamp).sorted(by: >).compactMap { timestamp in
            let components = [timestamp, directoryName, fileName]
            let path = ([rootPath] + components).joined(separator: "/")
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  Self.firstUntrusted(root: rootPath, components: components) == nil else { return nil }
            return path
        }
    }

    /// Löscht vertrauenswürdige Backups derselben Datei über `retainedBackupCount` hinaus (nie `keeping`) und
    /// danach leer gewordene Eltern-Ordner. Fehler beim Aufräumen lassen die neue Sicherung unberührt.
    private func pruneBackups(directoryName: String, fileName: String, keeping kept: String) {
        let surplus = trustedBackups(directoryName: directoryName, fileName: fileName)
            .filter { $0 != kept }
            .dropFirst(Self.retainedBackupCount - 1)
        for path in surplus { Self.removeBackupAndEmptyFolders(path) }
    }

    /// Löscht die Backup-Datei `path` und danach ihren Verzeichnis- und Zeitstempel-Ordner, sofern sie leer geworden
    /// sind (`rmdir` entfernt nur leere Ordner). Fehler werden ignoriert.
    private static func removeBackupAndEmptyFolders(_ path: String) {
        guard (try? FileManager.default.removeItem(atPath: path)) != nil else { return }
        let directoryFolder = URL(fileURLWithPath: path).deletingLastPathComponent()
        if rmdir(directoryFolder.path) == 0 {
            rmdir(directoryFolder.deletingLastPathComponent().path)
        }
    }

    /// Erste nicht vertrauenswürdige Stufe von `root` über jede Komponente bis zur Datei, sonst `nil`. Die Stufen bis
    /// zum Verzeichnisnamen müssen Verzeichnisse sein, die letzte eine reguläre Datei – ein Symlink gilt nie als
    /// vertrauenswürdig.
    private static func firstUntrusted(root: String, components: [String]) -> String? {
        let chain = [root] + components.indices.map { ([root] + components[...$0]).joined(separator: "/") }
        return chain.indices.first { !isTrusted(chain[$0], expecting: $0 == chain.indices.last ? S_IFREG : S_IFDIR) }
            .map { chain[$0] }
    }

    /// Name eines Zeitstempel-Ordners im Format `yyyyMMdd-HHmmss-SSS`.
    private static func isTimestamp(_ name: String) -> Bool {
        name.wholeMatch(of: /[0-9]{8}-[0-9]{6}-[0-9]{3}/) != nil
    }

    /// Setzt die Rechte von `file` auf `0644`; läuft der Prozess als root (`geteuid() == 0`), zusätzlich
    /// Eigentümer und Gruppe auf `root:wheel`. Schlägt das fehl, wird `file` gelöscht und der Fehler weitergereicht.
    private static func normaliseOrRemove(_ file: URL) throws {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            if geteuid() == 0 {
                try FileManager.default.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: file.path)
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Eine Stufe des Backup-Pfads ist vertrauenswürdig, wenn sie (ohne Symlink-Auflösung) vom Typ `type`
    /// (`S_IFDIR` oder `S_IFREG`) ist, dem ausführenden Benutzer gehört und weder für Gruppe noch für andere
    /// beschreibbar ist.
    private static func isTrusted(_ path: String, expecting type: mode_t) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == type && info.st_uid == geteuid() && (info.st_mode & 0o022) == 0
    }

    /// Ob unter `path` (ohne Symlink-Auflösung) ein Eintrag existiert.
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Kanonischer Pfad per `realpath` (alle Symlinks aufgelöst, auch `/var` → `/private/var`). Existiert `path` noch
    /// nicht (etwa `~/Library/LaunchAgents` vor dem ersten Agent), wird der längste vorhandene Anfang aufgelöst und der
    /// Rest wörtlich angehängt – ein später dort eingehängter Symlink wird beim Öffnen abgelehnt, nicht aufgelöst.
    static func canonicalPath(_ path: String) -> String {
        var missing: [String] = []
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        while existing.path != "/" {
            if let resolved = realpath(existing.path, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + missing.reversed()).joined(separator: "/")
            }
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        return path
    }

    /// Liest das Backup und verlangt ein gültiges `Label` im Inhalt (`isValidLabel`) – unabhängig vom Dateinamen.
    private func validatedContents(of file: URL, backupPath: String) throws -> Data {
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let label = plist["Label"] as? String, isValidLabel(label) else {
            throw BackupError.invalidContent(backupPath)
        }
        return data
    }

    /// Dateiname eines wiederherstellbaren Backups: gültiges launchd-Label (`isValidLabel`) plus `.plist`.
    private func isRestorableFileName(_ name: String) -> Bool {
        let suffix = ".plist"
        guard name.hasSuffix(suffix) else { return false }
        return isValidLabel(String(name.dropLast(suffix.count)))
    }

    /// `PrivilegedOperationPolicy.validateLabel(_:)`; mit `allowsAppleLabels` nur deren Syntaxprüfung.
    private func isValidLabel(_ label: String) -> Bool {
        let policy = PrivilegedOperationPolicy()
        return (try? allowsAppleLabels ? policy.validateLabelSyntax(label) : policy.validateLabel(label)) != nil
    }

    /// Formatiert `date` in UTC als `yyyyMMdd-HHmmss-SSS`.
    private static func timestamp(_ date: Date) -> String {
        timestampFormatter().string(from: date)
    }

    /// Umkehrung von `timestamp(_:)`; `nil` bei fremdem Format.
    private static func date(fromTimestamp timestamp: String) -> Date? {
        timestampFormatter().date(from: timestamp)
    }

    /// `DateFormatter` ist nicht `Sendable`, daher wird pro Aufruf eine neue Instanz erzeugt.
    private static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }
}
