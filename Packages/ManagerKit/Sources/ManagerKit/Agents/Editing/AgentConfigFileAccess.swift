import CryptoKit
import Darwin
import Foundation
import GrantryShared
import os

/// Eine zum Ändern gelesene Konfigurationsdatei: Inhalt, Prüfsumme und die gelesenen Dateisystemobjekte.
struct ConfigFileSnapshot: Sendable {
    let path: String
    let home: String
    let contents: Data
    /// SHA-256 des Inhalts, hexadezimal.
    let digest: String
    /// Das gelesene Dateiobjekt (Gerät und Inode).
    let identity: FileIdentity
    /// Der Ordner, in dem die Datei gelesen wurde (Gerät und Inode); `replace` verlangt denselben.
    let directoryIdentity: FileIdentity
}

/// Liest und ersetzt Agenten-Konfigurationen für Änderungen (Stufe 2), strenger als der Scan (`AgentConfigReader`):
///
/// - nur Dateien im eigenen Benutzerordner. Der Ordner der Datei wird ab `/` Bestandteil für Bestandteil ohne
///   Symlink-Auflösung geöffnet (`BoundDirectory`: `O_DIRECTORY | O_NOFOLLOW` je Ebene) und als Deskriptor gehalten;
///   jeder Ordner der Kette gehört dem Benutzer oder root (root-eigene nicht fremd-beschreibbar). Die Datei selbst wird
///   relativ zu diesem Deskriptor geöffnet (`O_NOFOLLOW | O_NONBLOCK`). Ein Symlink irgendwo im Pfad → „bitte im
///   Editor ändern“,
/// - nur auf einem lokalen Volume (`MNT_LOCAL`, nicht schreibgeschützt), kein iCloud-Platzhalter (`SF_DATALESS`, würde
///   beim Lesen heruntergeladen – geprüft, bevor die Datei geöffnet wird, und ohne Nachladen auf diesem Thread),
/// - nur reguläre, nicht geschützte (`uchg`/`schg`/`uappnd`/`sappnd`) Dateien des Benutzers mit genau einem Namen (ein
///   Hardlink würde durch das Ersetzen getrennt; kommt er erst nach dem Lesen hinzu → `fileChanged`), höchstens
///   `AgentConfigReader.maximumFileSize`, und genau so viele Bytes, wie `fstat` ankündigt (sonst wird sie gerade
///   geschrieben → `fileChanged`).
///
/// Ersetzt wird ausschließlich am gebundenen Ordner, der dasselbe Verzeichnisobjekt sein muss wie beim Lesen: Die neue
/// Fassung entsteht als temporäre Datei `.<Name>.grantry-<UUID>.tmp` darin (`O_CREAT | O_EXCL | O_NOFOLLOW`, Modus
/// `0600`), übernimmt ACL und erweiterte Attribute (`fcopyfile`), Rechte, Gruppe und die Flags `hidden`/`nodump` des
/// dafür erneut geöffneten Originals und wird mit `F_FULLFSYNC` gesichert. Dann **tauscht** `renameatx_np(RENAME_SWAP)`
/// beide Namen atomar; danach muss unter dem temporären Namen genau das gelesene Objekt liegen (Gerät/Inode) und sein
/// Inhalt noch die gelesene Prüfsumme haben (erst die Größe, dann der Inhalt) – sonst wird zurückgetauscht und
/// `fileChanged` gemeldet. Zurückgetauscht wird nur, wenn unter dem Namen noch die eigene neue Fassung liegt – dasselbe
/// Objekt (Gerät/Inode der angelegten Datei) mit unverändertem Inhalt, denn ein Programm, das über den Namen in die
/// Datei schreibt, ändert den Inhalt und nicht das Objekt –, und gelöscht nur, was nachweislich die eigene ist: Hat ein
/// anderes Programm inzwischen seine Fassung unter den Namen gelegt oder die neue dort verändert, bleibt sie dort und
/// die vorige unter dem temporären Namen – `replacedUnverified` nennt beides. Scheitert der Rücktausch, ebenfalls
/// `replacedUnverified`. Erst nach gelungener Nachprüfung wird das alte Objekt gelöscht (`unlinkat`) und der Ordner
/// synchronisiert. Alle Schritte laufen über den Ordner-Deskriptor; ein Austausch des Ordners oder der Datei über Pfade
/// erreicht sie nicht. Dateisysteme ohne `RENAME_SWAP` werden abgelehnt.
///
/// Verbleibende Grenzen: Ein Tool, das genau zwischen der Prüfung nach dem Tausch und dem Löschen in das alte Objekt
/// schreibt, verliert diese Bytes; ersetzt es die Datei in diesem Moment per `rename`, gewinnt seine Fassung (der Scan
/// danach zeigt es). Deshalb der Hinweis, das Tool vorher zu beenden. Ownership-Prüfungen schützen nicht vor einem
/// Angreifer, der als derselbe Benutzer läuft – dagegen hilft nur die Bindung an das Verzeichnisobjekt.
enum AgentConfigFileAccess {
    static let symlinkReason = "Der Pfad enthält einen symbolischen Link"
    static let networkReason = "Die Datei liegt auf einem Netzlaufwerk"
    static let readOnlyVolumeReason = "Das Volume ist schreibgeschützt"
    static let placeholderReason = "Die Datei ist ein iCloud-Platzhalter und noch nicht geladen"
    static let protectedReason = "Die Datei ist geschützt"
    static let swapUnsupportedReason = "Das Dateisystem unterstützt kein atomares Ersetzen"
    static let untrustedDirectoryReason = "Ein Ordner im Pfad gehört einem anderen Benutzer oder ist für andere beschreibbar"
    static let hardLinkReason = "Die Datei hat mehrere Namen (Hardlink)"
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "agent-config")

    static func read(_ path: String, home: String, maximumSize: Int = AgentConfigReader.maximumFileSize) throws(AgentConfigEditError) -> ConfigFileSnapshot {
        let location = try Location(path, home: home)
        let directory = try ConfigDirectory.open(location.directory)
        let file = try directory.openFile(named: location.name, maximumSize: maximumSize)
        guard file.hasSingleName else { throw .notEditable(hardLinkReason) }
        return ConfigFileSnapshot(
            path: path, home: home, contents: file.contents, digest: file.digest, identity: FileIdentity(file.info),
            directoryIdentity: directory.identity
        )
    }

    /// Ersetzt die Datei von `snapshot` durch `contents`, wenn Ordner und Datei seit dem Lesen unverändert sind.
    ///
    /// Jeder Fehler außer `replacedUnverified` lässt die Datei unverändert: Scheitert die Nachprüfung nach dem Tausch,
    /// wird zurückgetauscht (`fileChanged`); gelingt das nicht oder unterbleibt es, weil unter dem Namen inzwischen eine
    /// fremde Fassung steht, ist das `replacedUnverified` – der Aufrufer behält die Sicherung.
    static func replace(_ snapshot: ConfigFileSnapshot, with contents: Data) throws(AgentConfigEditError) {
        try replace(snapshot, with: contents) {}
    }

    /// Wie `replace(_:with:)`; `afterSwap` ist eine Testnaht: läuft nach dem Tausch, vor der Nachprüfung.
    static func replace(_ snapshot: ConfigFileSnapshot, with contents: Data, afterSwap: () -> Void) throws(AgentConfigEditError) {
        let location = try Location(snapshot.path, home: snapshot.home)
        let directory = try ConfigDirectory.open(location.directory)
        guard directory.identity.isSameObject(as: snapshot.directoryIdentity) else { throw .fileChanged }
        let original = try directory.openFile(named: location.name, maximumSize: AgentConfigReader.maximumFileSize)
        // Ein inzwischen hinzugekommener zweiter Name ist eine Änderung seit dem Lesen, kein Dauerzustand der Datei.
        guard FileIdentity(original.info).isSameObject(as: snapshot.identity), original.digest == snapshot.digest,
              original.hasSingleName else {
            throw .fileChanged
        }
        let temporary = ".\(location.name).grantry-\(UUID().uuidString).tmp"
        let written = try directory.createFile(named: temporary, contents: contents, like: original)
        var temporaryHoldsNewContents = true
        defer { if temporaryHoldsNewContents { directory.remove(temporary) } }
        try directory.swap(temporary, location.name)
        temporaryHoldsNewContents = false
        afterSwap()
        // Unter dem temporären Namen liegt jetzt das alte Objekt – es muss das gelesene sein, mit dem gelesenen Inhalt.
        let unchanged = directory.holds(snapshot.identity, under: temporary) && original.currentDigest() == snapshot.digest
        guard unchanged else {
            try swapBack(temporary: temporary, file: location.name, written: written, in: directory)
            temporaryHoldsNewContents = true
            throw .fileChanged
        }
        // Das Ersetzen ist gelungen; ein Rest unter dem temporären Namen wäre nur Unordnung – aber keine stille.
        if !directory.remove(temporary) {
            logger.error("Alte Fassung nach dem Ersetzen nicht gelöscht (\(String(cString: strerror(errno)), privacy: .public)): \(temporary, privacy: .public)")
        }
        directory.synchronize()
    }

    /// Rücktausch nach gescheiterter Nachprüfung. Nur, wenn unter `file` noch unverändert die eigene neue Fassung
    /// (`written`) liegt: Eine inzwischen von einem anderen Programm dorthin gelegte oder dort veränderte Fassung bleibt
    /// – zurückgetauscht landete sie unter dem temporären Namen und würde gelöscht. Nach dem Tausch muss unter
    /// `temporary` die eigene Fassung liegen, wieder Objekt und Inhalt; erst dann darf der Aufrufer sie löschen. Jede
    /// Abweichung ist `replacedUnverified` mit beiden Orten, die Datei bleibt, wie sie ist.
    private static func swapBack(temporary: String, file: String, written: WrittenFile, in directory: ConfigDirectory) throws(AgentConfigEditError) {
        if directory.holdsUnchanged(written, under: file) == false {
            throw .replacedUnverified("die Datei wurde zwischenzeitlich durch ein anderes Programm ersetzt oder verändert und bleibt so; die vorige Fassung liegt unter \(temporary)")
        }
        do throws(AgentConfigEditError) {
            try directory.swap(temporary, file)
        } catch .fileChanged {
            // `ENOENT`: Einer der beiden Namen ist inzwischen weg.
            throw .replacedUnverified(vanishedSwapBackReason(file: file, temporary: temporary, in: directory))
        } catch {
            let reason = switch error {
            case .writeFailed(let reason), .notEditable(let reason): reason
            default: error.localizedDescription
            }
            throw .replacedUnverified("die Datei wurde zwischenzeitlich ersetzt und der Rücktausch scheiterte (\(reason)); die vorige Fassung liegt unter \(temporary)")
        }
        guard directory.holdsUnchanged(written, under: temporary) == true else {
            throw .replacedUnverified("die Datei wurde zwischenzeitlich durch ein anderes Programm ersetzt oder verändert; die vorige Fassung steht wieder unter ihrem Namen, die fremde liegt unter \(temporary)")
        }
    }

    /// Grund nach einem Rücktausch, der an einem fehlenden Namen scheiterte (`ENOENT`) – je nachdem, was noch wo liegt:
    /// unter dem Namen die neue Fassung, unter dem temporären die vorige.
    private static func vanishedSwapBackReason(file: String, temporary: String, in directory: ConfigDirectory) -> String {
        let fileExists = (try? directory.status(of: file)) != nil
        let temporaryExists = (try? directory.status(of: temporary)) != nil
        return switch (fileExists, temporaryExists) {
        case (true, false): "die Datei wurde zwischenzeitlich ersetzt; die neue Fassung ist geschrieben, die vorige nicht mehr auffindbar"
        case (true, true): "die Datei wurde zwischenzeitlich ersetzt; die neue Fassung ist geschrieben, die vorige liegt unter \(temporary)"
        case (false, true): "die Datei wurde zwischenzeitlich entfernt; die vorige Fassung liegt unter \(temporary)"
        case (false, false): "die Datei wurde zwischenzeitlich entfernt; auch die vorige Fassung ist nicht mehr auffindbar"
        }
    }

    /// SHA-256 hexadezimal.
    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Grund, aus dem ein Volume mit `statfs`-Flags `flags` nicht änderbar ist: nicht lokal oder schreibgeschützt.
    static func volumeRefusal(flags: UInt32) -> String? {
        if flags & UInt32(MNT_LOCAL) == 0 { return networkReason }
        if flags & UInt32(MNT_RDONLY) != 0 { return readOnlyVolumeReason }
        return nil
    }

    /// Grund, aus dem eine Datei mit BSD-Flags `flags` nicht änderbar ist: iCloud-Platzhalter oder geschützt
    /// (unveränderbar bzw. nur anfügbar – das alte Objekt ließe sich auch nicht löschen).
    static func flagRefusal(flags: UInt32) -> String? {
        if flags & UInt32(SF_DATALESS) != 0 { return placeholderReason }
        if flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0 { return protectedReason }
        return nil
    }

    /// Die BSD-Flags, die die neue Fassung übernimmt: nur `hidden` und `nodump`. `SF_*` kann nur root setzen,
    /// `UF_COMPRESSED` beschreibt den (hier nicht vorhandenen) komprimierten Inhalt, `UF_TRACKED` und `UF_DATAVAULT`
    /// gehören dem System.
    static func preservedFlags(_ flags: UInt32) -> UInt32 {
        flags & UInt32(UF_HIDDEN | UF_NODUMP)
    }

    /// Liest genau `expectedSize` Bytes von `descriptor`; liefert die Datei mehr oder weniger, wird sie gerade
    /// geschrieben → `fileChanged`.
    static func contents(of descriptor: Int32, expectedSize: Int) throws(AgentConfigEditError) -> Data {
        guard let data = AgentConfigReader.contents(of: descriptor, maximumLength: expectedSize + 1) else {
            throw .unreadable(AgentConfigReader.unreadableText)
        }
        guard data.count == expectedSize else { throw .fileChanged }
        return data
    }

    /// Ordner und Name eines Pfads, der absolut, ohne `.`/`..` und im Benutzerordner liegt.
    private struct Location {
        let directory: String
        let name: String

        init(_ path: String, home: String) throws(AgentConfigEditError) {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.hasPrefix("/"), !components.contains(".."),
                  !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." }),
                  AgentConfigReader.isInside(path, home), let name = components.last.map(String.init), !name.isEmpty else {
                throw .notEditable("Die Datei liegt außerhalb deines Benutzerordners")
            }
            self.name = name
            let directory = String(path.dropLast(name.count + 1))
            self.directory = directory.isEmpty ? "/" : directory
        }
    }
}

/// Die eigene neue Fassung, wie `ConfigDirectory.createFile` sie angelegt hat: Objekt (Gerät/Inode) und Inhalt
/// (Prüfsumme, Größe) – um sie später von fremden und von inzwischen veränderten zu unterscheiden.
private struct WrittenFile {
    let identity: FileIdentity
    let digest: String
    let size: Int
}

/// Eine zum Lesen geöffnete Konfigurationsdatei: Deskriptor, `fstat` und der daraus gelesene Inhalt. Schließt den
/// Deskriptor beim Freigeben.
private final class OpenConfigFile {
    let descriptor: Int32
    let info: stat
    let contents: Data
    let digest: String

    init(descriptor: Int32, info: stat, contents: Data) {
        self.descriptor = descriptor
        self.info = info
        self.contents = contents
        digest = AgentConfigFileAccess.digest(of: contents)
    }

    deinit { close(descriptor) }

    /// Genau ein Name (`st_nlink == 1`) – ein Hardlink würde durch das Ersetzen getrennt.
    var hasSingleName: Bool { info.st_nlink == 1 }

    /// Prüfsumme des Inhalts, wie er jetzt in diesem Dateiobjekt steht; `nil`, wenn er nicht lesbar ist oder schon
    /// seine Größe nicht mehr die gelesene ist (dann wird nichts gelesen – auch keine inzwischen riesige Datei).
    func currentDigest() -> String? {
        var current = stat()
        guard fstat(descriptor, &current) == 0, current.st_size == info.st_size, lseek(descriptor, 0, SEEK_SET) == 0,
              let data = try? AgentConfigFileAccess.contents(of: descriptor, expectedSize: contents.count) else { return nil }
        return AgentConfigFileAccess.digest(of: data)
    }
}

/// Der gebundene Ordner einer Konfigurationsdatei (`BoundDirectory`) samt Identität; alle Zugriffe laufen relativ zu
/// seinem Deskriptor und treffen so genau dieses Verzeichnisobjekt.
private final class ConfigDirectory {
    let identity: FileIdentity
    private let bound: BoundDirectory

    private init(bound: BoundDirectory, identity: FileIdentity) {
        self.bound = bound
        self.identity = identity
    }

    /// Öffnet `path` gebunden (jeder Ordner vertrauenswürdig, `checkTrusted`) und verlangt ein lokales, beschreibbares
    /// Volume.
    static func open(_ path: String) throws(AgentConfigEditError) -> ConfigDirectory {
        let bound: BoundDirectory
        do {
            bound = try BoundDirectory(path: path) { descriptor, _ in try checkTrusted(descriptor) }
        } catch let error as AgentConfigEditError {
            throw error
        } catch let error as POSIXError {
            switch error.code {
            case .ENOENT, .ENOTDIR: throw .missing
            case .ELOOP: throw .notEditable(AgentConfigFileAccess.symlinkReason)
            default: throw .unreadable(AgentConfigReader.unreadableText)
            }
        } catch {
            throw .unreadable(AgentConfigReader.unreadableText)
        }
        var info = stat()
        var volume = statfs()
        guard fstat(bound.descriptor, &info) == 0, fstatfs(bound.descriptor, &volume) == 0 else {
            throw .unreadable(AgentConfigReader.unreadableText)
        }
        if let reason = AgentConfigFileAccess.volumeRefusal(flags: volume.f_flags) { throw .notEditable(reason) }
        return ConfigDirectory(bound: bound, identity: FileIdentity(info))
    }

    /// Ein Ordner der Kette gehört dem Benutzer oder root; ein root-eigener darf weder für Gruppe noch für andere
    /// beschreibbar sein. Keine Ausnahme für das Sticky-Bit: Auf dem Weg zu einer Datei im Benutzerordner liegt nie
    /// ein `/tmp`-artiger Ordner, und eine Ausnahme wäre nur ein weiterer Angriffspunkt.
    private static func checkTrusted(_ descriptor: Int32) throws(AgentConfigEditError) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(AgentConfigReader.unreadableText) }
        if info.st_uid == geteuid() { return }
        guard info.st_uid == 0, (info.st_mode & 0o022) == 0 else {
            throw .notEditable(AgentConfigFileAccess.untrustedDirectoryReason)
        }
    }

    /// Öffnet `name` im gebundenen Ordner ohne Symlink und liest sie vollständig (Härtungen siehe `AgentConfigFileAccess`;
    /// die Zahl der Namen beurteilt der Aufrufer, `hasSingleName`).
    func openFile(named name: String, maximumSize: Int) throws(AgentConfigEditError) -> OpenConfigFile {
        // Vorprüfung am Namen, ohne zu öffnen: Einen iCloud-Platzhalter würde schon `open` nachladen.
        let preliminary: stat
        do {
            preliminary = try status(of: name)
        } catch {
            throw Self.openFailure(error.code.rawValue)
        }
        if let reason = AgentConfigFileAccess.flagRefusal(flags: preliminary.st_flags) { throw .notEditable(reason) }
        let descriptor = try Self.withoutMaterializingDatalessFiles { () throws(AgentConfigEditError) -> Int32 in
            let descriptor = openat(bound.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
            guard descriptor >= 0 else { throw Self.openFailure(errno) }
            return descriptor
        }
        var keep = false
        defer { if !keep { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(AgentConfigReader.unreadableText) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw .notEditable("Keine reguläre Datei") }
        guard info.st_uid == geteuid() else { throw .notEditable("Die Datei gehört einem anderen Benutzer") }
        if let reason = AgentConfigFileAccess.flagRefusal(flags: info.st_flags) { throw .notEditable(reason) }
        guard Int(info.st_size) <= maximumSize else { throw .unreadable(AgentConfigReader.sizeLimitText(maximumSize)) }
        let contents = try AgentConfigFileAccess.contents(of: descriptor, expectedSize: Int(info.st_size))
        keep = true
        return OpenConfigFile(descriptor: descriptor, info: info, contents: contents)
    }

    /// Legt `name` exklusiv an (`0600`), schreibt `contents`, übernimmt ACL, erweiterte Attribute, Rechte, Gruppe und
    /// Flags von `original` und sichert alles (`F_FULLFSYNC`, sonst `fsync`).
    /// - Returns: Die angelegte Datei (Objekt und Inhalt) – um sie später von fremden und veränderten zu unterscheiden.
    func createFile(named name: String, contents: Data, like original: OpenConfigFile) throws(AgentConfigEditError) -> WrittenFile {
        let descriptor = openat(bound.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.writeFailure(errno) }
        var created = stat()
        do throws(AgentConfigEditError) {
            try Self.write(contents, to: descriptor)
            try Self.adoptMetadata(of: original, to: descriptor)
            if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 { throw Self.writeFailure(errno) }
            guard fstat(descriptor, &created) == 0 else { throw Self.writeFailure(errno) }
        } catch {
            close(descriptor)
            remove(name)
            throw error
        }
        guard close(descriptor) == 0 else {
            let failure = errno
            remove(name)
            throw Self.writeFailure(failure)
        }
        return WrittenFile(identity: FileIdentity(created), digest: AgentConfigFileAccess.digest(of: contents), size: contents.count)
    }

    /// Ob unter `name` (ohne Symlink-Auflösung) genau das Objekt `identity` liegt; fehlt der Name, `false`.
    func holds(_ identity: FileIdentity, under name: String) -> Bool {
        (try? status(of: name)).map { FileIdentity($0).isSameObject(as: identity) } == true
    }

    /// Ob unter `name` noch genau `written` liegt: dasselbe Objekt mit unverändertem Inhalt – ein Programm, das über den
    /// Namen in die Datei schreibt, ändert den Inhalt, nicht das Objekt. Ist sie gewachsen, fällt das an der Größe auf,
    /// ohne sie zu lesen. `nil`, wenn der Name fehlt.
    func holdsUnchanged(_ written: WrittenFile, under name: String) -> Bool? {
        do {
            let file = try openFile(named: name, maximumSize: written.size)
            return FileIdentity(file.info).isSameObject(as: written.identity) && file.digest == written.digest
        } catch .missing {
            return nil
        } catch {
            return false
        }
    }

    /// Tauscht `first` und `second` atomar (`RENAME_SWAP`); ohne Unterstützung des Dateisystems wird abgelehnt statt
    /// auf ein unsicheres `rename` auszuweichen.
    func swap(_ first: String, _ second: String) throws(AgentConfigEditError) {
        guard renameatx_np(bound.descriptor, first, bound.descriptor, second, UInt32(RENAME_SWAP)) == 0 else {
            switch errno {
            case ENOTSUP, EINVAL: throw .notEditable(AgentConfigFileAccess.swapUnsupportedReason)
            case ENOENT: throw .fileChanged
            default: throw Self.writeFailure(errno)
            }
        }
    }

    /// `fstatat` ohne Symlink-Auflösung; `POSIXError` mit dem `errno`, wenn der Eintrag fehlt (`ENOENT`) oder nicht
    /// erreichbar ist.
    func status(of name: String) throws(POSIXError) -> stat {
        var info = stat()
        guard fstatat(bound.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw BoundDirectory.posixError() }
        return info
    }

    /// Löscht `name` im gebundenen Ordner (Aufräumen); `false` mit `errno`, wenn das misslingt.
    @discardableResult
    func remove(_ name: String) -> Bool {
        unlinkat(bound.descriptor, name, 0) == 0
    }

    /// Schreibt die Verzeichnisänderung durch; Fehler werden ignoriert.
    func synchronize() {
        fsync(bound.descriptor)
    }

    private static func openFailure(_ code: Int32) -> AgentConfigEditError {
        switch code {
        case ENOENT, ENOTDIR: .missing
        case ELOOP: .notEditable(AgentConfigFileAccess.symlinkReason)
        case EDEADLK: .notEditable(AgentConfigFileAccess.placeholderReason)
        default: .unreadable(AgentConfigReader.unreadableText)
        }
    }

    private static func writeFailure(_ code: Int32) -> AgentConfigEditError {
        .writeFailed(String(cString: strerror(code)))
    }

    /// Führt `body` aus, ohne dass dieser Thread iCloud-Platzhalter (`SF_DATALESS`) nachlädt: Ein Zugriff darauf
    /// scheitert mit `EDEADLK`. Die vorige Einstellung wird danach wiederhergestellt.
    private static func withoutMaterializingDatalessFiles<T>(_ body: () throws(AgentConfigEditError) -> T) throws(AgentConfigEditError) -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let changed = previous >= 0
            && setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        defer { if changed { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) } }
        return try body()
    }

    /// ACL und erweiterte Attribute (`fcopyfile`), Rechte (`fchmod`), Gruppe (nur bei Abweichung) und `preservedFlags`.
    private static func adoptMetadata(of original: OpenConfigFile, to descriptor: Int32) throws(AgentConfigEditError) {
        guard fcopyfile(original.descriptor, descriptor, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else {
            throw .writeFailed("Zugriffsrechte und Attribute nicht übernommen (\(String(cString: strerror(errno))))")
        }
        guard fchmod(descriptor, original.info.st_mode & 0o777) == 0 else { throw writeFailure(errno) }
        var created = stat()
        guard fstat(descriptor, &created) == 0 else { throw writeFailure(errno) }
        if created.st_gid != original.info.st_gid {
            guard fchown(descriptor, uid_t.max, original.info.st_gid) == 0 else { throw writeFailure(errno) }
        }
        let flags = AgentConfigFileAccess.preservedFlags(original.info.st_flags)
        if flags != 0 {
            guard fchflags(descriptor, flags) == 0 else { throw writeFailure(errno) }
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws(AgentConfigEditError) {
        let failure: Int32? = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return count < 0 ? errno : EIO }
                offset += count
            }
            return nil
        }
        if let failure { throw writeFailure(failure) }
    }
}
