import Darwin
import Foundation

/// Endgültiges Löschen eines geprüften Speicher-Eintrags, ohne Symlinks oder verschachtelten Volumes zu folgen.
/// Eine vollständige Vorprüfung lehnt bereits vorhandene Mounts und unlesbare Teilbäume vor der ersten Löschung ab.
/// Auch beim Löschen gilt `FTS_XDEV`; neu auftretende Fehler brechen ab und werden nie als Erfolg bilanziert.
/// Die beiden Durchläufe sind keine Transaktion: Ein Fehler im zweiten kann einen teilweise geleerten Cache lassen.
struct StorageTreeRemover: Sendable {
    enum Failure: LocalizedError {
        case mountPoint, changed, unreadable

        var errorDescription: String? {
            switch self {
            case .mountPoint: "Verschachtelter Einhängepunkt"
            case .changed: "Eintrag wurde ersetzt"
            case .unreadable: "Ordner nicht vollständig lesbar"
            }
        }
    }

    /// Gerätekennung aus den Traversierungs-Metadaten; austauschbar ohne echte Mounts anzulegen.
    let deviceOf: @Sendable (stat) -> dev_t

    init(deviceOf: @escaping @Sendable (stat) -> dev_t = { $0.st_dev }) {
        self.deviceOf = deviceOf
    }

    func remove(_ path: String, identity: FileIdentity) throws {
        try walk(path, identity: identity, deleting: false)
        try walk(path, identity: identity, deleting: true)
    }

    private func walk(_ path: String, identity: FileIdentity, deleting: Bool) throws {
        guard FileIdentity.of(path) == identity else { throw Failure.changed }
        guard let argument = strdup(path) else { throw POSIXError(.ENOMEM) }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { fts_close(stream) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = fts_read(stream) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return
            }
            let node = entry.pointee
            let kind = Int32(node.fts_info)
            switch kind {
            case FTS_DNR, FTS_ERR, FTS_NS, FTS_NSOK, FTS_DC:
                throw Failure.unreadable
            default: break
            }
            guard let status = node.fts_statp?.pointee else { throw Failure.unreadable }
            // FTS_XDEV liefert den Mount selbst, steigt aber nicht hinein. Nicht still überspringen oder entfernen.
            guard deviceOf(status) == identity.device else { throw Failure.mountPoint }
            if node.fts_level == 0, FileIdentity(status) != identity { throw Failure.changed }
            guard deleting, kind != FTS_D else { continue }
            // fts-Statistik kann vom Eintritt in den Ordner stammen; vor unlink/rmdir erneut prüfen.
            var current = stat()
            guard lstat(node.fts_accpath, &current) == 0, FileIdentity(current) == FileIdentity(status) else {
                throw Failure.changed
            }
            // Ausschließlich einzelne Einträge entfernen, niemals einen rekursiven FileManager-Aufruf verwenden.
            let result = kind == FTS_DP ? rmdir(node.fts_accpath) : unlink(node.fts_accpath)
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
}
