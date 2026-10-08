import Darwin
import Foundation
import GrantryShared
import os

/// Privater Ordner der App für Verlauf und Wiederherstellungsbelege (#141): Ordner `0700`, Dateien `0600`.
///
/// Geöffnet wird wie jede private Datei der App über `PrivateFile.trustedDirectory` (`BoundDirectory`, ohne
/// Symlink-Auflösung, jeder Ordner der Kette geprüft); fehlende Ordner entstehen mit `0700`. Bevor der Ordner selbst
/// geprüft wird, wird er gehärtet – eine ältere Installation mit `0775` bliebe sonst abgelehnt statt repariert.
///
/// Gehärtet wird gezielt am Deskriptor (`harden`): Jeder Eintrag wird mit `O_NOFOLLOW` relativ zum gebundenen Ordner
/// geöffnet und erst nach `fstat` per `fchmod` verschärft – Gruppen- und Weltrechte entfallen (`& ~0o077`), mehr nie;
/// eine ACL mit Allow-Einträgen wird entfernt. Unverändert bleiben und werden als `Restriction` protokolliert und
/// gemeldet: Symlinks (der Link könnte auf eine fremde Datei zeigen), Einträge eines anderen Eigentümers, Dateien mit
/// mehreren Namen (Hardlink – das Verschärfen träfe auch den anderen Namen) und alles außer regulären Dateien und
/// Ordnern.
///
/// Warum keine prozessweite `umask(077)`: Sie gälte für jeden Thread und jede Datei des Prozesses – auch für vom
/// Benutzer bearbeitete Agenten-Konfigurationen oder Exporte, die dann unerwartet `0600` würden. Stattdessen schützt
/// der `0700`-Ordner jede darin entstehende Datei ab ihrem ersten Byte (andere Benutzer kommen nicht hinein, gleich
/// welche Rechte SQLite oder SwiftData einer neuen Datei geben); die Dateien selbst werden zusätzlich verschärft.
///
/// SQLite-Dateien dürfen dabei nur gehärtet werden, solange dieser Prozess sie nicht geöffnet hat: SQLite sperrt mit
/// POSIX-`fcntl`-Sperren, und das Schließen *irgendeines* Deskriptors auf die Datei gäbe sie für den ganzen Prozess
/// frei. Deshalb wird die Ablage vor dem Öffnen gehärtet und eine neue Datenbank vorab leer mit `0600` angelegt
/// (`createFileIfMissing`); `-wal`/`-shm` legt SQLite mit den Rechten der Hauptdatei an, also ebenfalls `0600`.
final class PrivateDirectory {
    /// Ein Eintrag, der bewusst nicht verändert wurde.
    struct Restriction: Equatable, Sendable, CustomStringConvertible {
        enum Reason: Equatable, Sendable {
            case symbolicLink
            case foreignOwner
            case multipleLinks
            case unsupportedType
            /// Öffnen, `fstat`, `fchmod` oder das Entfernen der ACL scheiterte mit diesem `errno`.
            case failed(Int32)
        }

        let path: String
        let reason: Reason

        var description: String { "\(path): \(reason)" }
    }

    /// Wie tief Unterordner (etwa SwiftDatas `.<Name>_SUPPORT/_EXTERNAL_DATA`) höchstens durchlaufen werden.
    private static let maximumDepth = 8
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "storage")

    let bound: BoundDirectory
    /// Bisher nicht veränderte Einträge (auch der Ordner selbst), in der Reihenfolge ihres Auftretens.
    private(set) var restrictions: [Restriction] = []
    /// Eigentümer, dessen Einträge verschärft werden; nur Tests geben einen anderen an.
    private let owner: uid_t

    /// Öffnet (und legt bei Bedarf mit `0700` an) den Ordner `url` und härtet ihn.
    /// - Throws: `PrivateFileRefusal.untrustedDirectory`, `POSIXError` (`ELOOP` für einen Symlink im Pfad).
    init(at url: URL, owner: uid_t = geteuid()) throws {
        self.owner = owner
        var found: Restriction?
        bound = try PrivateFile.trustedDirectory(
            at: url.path(percentEncoded: false), creatingMissingWith: PrivateFile.directoryMode
        ) { descriptor, path in
            found = Self.tighten(descriptor, owner: owner).map { Restriction(path: path, reason: $0) }
        }
        found.map(record)
    }

    /// Legt `name` leer als vertrauliche Datei an (`PrivateFile.createConfidential`, `0600`), falls er fehlt – damit
    /// eine Datei, die eine Bibliothek gleich öffnet und füllt, von Anfang an privat ist. Eine vorhandene bleibt
    /// unangetastet.
    func createFileIfMissing(_ name: String) throws {
        do {
            close(try PrivateFile.createConfidential(named: name, in: bound))
        } catch let error as POSIXError where error.code == .EEXIST {
            return
        }
    }

    /// Härtet die Einträge `names` (Ordner samt Inhalt); fehlende werden übergangen.
    func harden(_ names: [String]) {
        for name in names { harden(name, in: bound.descriptor, path: bound.path, depth: 0) }
    }

    /// Härtet alle Einträge des Ordners, für die `include` gilt (`isDirectory` ohne Symlink-Auflösung).
    func hardenEntries(where include: (_ name: String, _ isDirectory: Bool) -> Bool) {
        harden(Self.entries(of: bound.descriptor).filter { include($0, Self.isDirectory($0, in: bound.descriptor)) })
    }

    private func harden(_ name: String, in parent: Int32, path parentPath: String, depth: Int) {
        let path = parentPath == "/" ? "/" + name : parentPath + "/" + name
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code != ENOENT { record(Restriction(path: path, reason: code == ELOOP ? .symbolicLink : .failed(code))) }
            return
        }
        defer { close(descriptor) }
        if let reason = Self.tighten(descriptor, owner: owner) {
            record(Restriction(path: path, reason: reason))
            return
        }
        guard depth < Self.maximumDepth, Self.isDirectory(descriptor) else { return }
        for child in Self.entries(of: descriptor) { harden(child, in: descriptor, path: path, depth: depth + 1) }
    }

    private func record(_ restriction: Restriction) {
        restrictions.append(restriction)
        Self.logger.error("Ablage nicht gehärtet, unverändert gelassen: \(restriction.description, privacy: .public)")
    }

    /// Verschärft den geöffneten Eintrag (siehe Typbeschreibung); `nil`, wenn er nun privat ist.
    private static func tighten(_ descriptor: Int32, owner: uid_t) -> Restriction.Reason? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .failed(errno) }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { return .unsupportedType }
        guard info.st_uid == owner else { return .foreignOwner }
        guard type == S_IFDIR || info.st_nlink == 1 else { return .multipleLinks }
        let permissions = info.st_mode & 0o7777
        let tightened = permissions & ~0o077
        guard tightened == permissions || fchmod(descriptor, tightened) == 0 else { return .failed(errno) }
        guard !AccessControlList.grantsAccess(descriptor: descriptor) || AccessControlList.remove(from: descriptor) else {
            return .failed(errno)
        }
        return nil
    }

    /// Namen der Einträge des geöffneten Ordners ohne `.` und `..`; leer, wenn er sich nicht lesen lässt.
    private static func entries(of directory: Int32) -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0 else { return [] }
        guard let stream = fdopendir(duplicate) else {
            close(duplicate)
            return []
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private static func isDirectory(_ name: String, in directory: Int32) -> Bool {
        var info = stat()
        return fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isDirectory(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}

extension StorageLocation {
    /// Öffnet den Ablageort privat (`PrivateDirectory`) und härtet, was eine ältere Installation mit weiteren Rechten
    /// hinterlassen hat: alle Dateien direkt darin (Verlauf samt `-wal`/`-shm`, Belege, beiseitegelegte Dateien) und
    /// SwiftDatas Ordner externer Daten. Andere Unterordner bleiben unberührt – die Benutzer-Backups haben eigene
    /// Rechteregeln (`PlistBackupStore`), eine zweite Instanz hat ihren eigenen Ablageort; der `0700`-Ordner schützt
    /// sie ohnehin. Ebenso unberührt bleiben die selbst geprüften Dateien (`selfCheckedFileNames`).
    func openPrivately(owner: uid_t = geteuid()) throws -> PrivateDirectory {
        let storage = try PrivateDirectory(at: directory, owner: owner)
        let supportPrefix = SwiftDataSnapshotStore.supportDirectoryName(of: historyStoreURL)
        let selfChecked = selfCheckedFileNames
        storage.hardenEntries { name, isDirectory in
            isDirectory ? name.hasPrefix(supportPrefix) : !selfChecked.contains(name)
        }
        return storage
    }

    /// Dateien, deren Komponente eine unzulässige Datei ablehnt bzw. ersetzt statt sie zu reparieren – ein Härten
    /// vorab machte eine schon offengelegte Datei unbemerkt wieder „gültig“: Die Schlüsseldatei
    /// (`SecretFingerprintKeyFile`) muss nach `0644` oder einer ACL rotiert werden, denn `chmod` macht einen evtl. schon
    /// kopierten Schlüssel nicht wieder geheim; die Instanzsperre (`InstanceLock`) lehnt eine für andere änderbare Datei
    /// ab.
    var selfCheckedFileNames: Set<String> {
        [secretFingerprintKeyURL.lastPathComponent, instanceLockURL.lastPathComponent]
    }
}
