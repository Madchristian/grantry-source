import CryptoKit
import Darwin
import Foundation

/// Metadaten aller Einträge statt nur des Bundle-Siegels: liest keine Ressourceninhalte.
/// Physischer Baum, kein Betreten von Symlinks. Interne Links sind durch ihre Ziele im Baum abgedeckt; ebenso ein
/// verwaister Link, dessen fehlendes Ziel im Baum liegt (#650, etwa `PrivateHeaders` → `Versions/Current/PrivateHeaders`
/// in Python-Frameworks): Entsteht das Ziel später, ist es ein neuer Eintrag im Baum und ändert den Fingerabdruck.
/// Externe Ziele, fehlende Ziele außerhalb des Baums, Sonderdateien, Lesefehler und erreichte Grenzen verhindern jede
/// Cache-Wiederverwendung.
/// ctime mit Nanosekunden erkennt auch gleich große Änderungen mit zurückgesetzter mtime.
/// `path` ist bereits kanonisch (`FileFingerprint.target`), damit interne Links vergleichbar sind.
struct CodeTreeFingerprint {
    /// Ganzer Baum am Stück (Vollscan, Tiefenprüfung); `nil`, wenn er nicht vollständig erfassbar ist.
    static func read(at path: String, maximumEntries: Int = CodeTreeWalk.defaultMaximumEntries,
                     timeout: Duration = CodeTreeWalk.defaultTimeout) -> String? {
        guard let walk = CodeTreeWalk(path: path, maximumEntries: maximumEntries, timeout: timeout),
              case .finished(let fingerprint) = walk.advance(cpuBudget: nil).progress else { return nil }
        return fingerprint
    }

    /// Ein Eintrag des Baums für den Fingerabdruck; `nil`, wenn er jede Cache-Wiederverwendung verhindert (externes
    /// oder fehlendes Link-Ziel außerhalb des Baums, Sonderdatei, Lesefehler).
    fileprivate static func record(of entry: UnsafeMutablePointer<FTSENT>, in path: String,
                                   volumes: [MountedVolume]) -> String? {
        let itemPath = String(cString: entry.pointee.fts_path)
        guard let info = entry.pointee.fts_statp else { return nil }
        let status = info.pointee
        if FileType.isSymbolicLink(status) {
            // Keine Metadaten externer Link-Ziele lesen (z. B. Automounter/Netzlaufwerk).
            var missingInTree = false
            guard let target = LocalPathResolver.resolve(itemPath, volumes: volumes, entry: { candidate in
                guard candidate == path || path.hasPrefix(candidate + "/") || candidate.hasPrefix(path + "/")
                else { return .unavailable }
                let entry = LocalPathResolver.entry(at: candidate)
                if case .missing = entry { missingInTree = candidate.hasPrefix(path + "/") }
                return entry
            }), target.path.hasPrefix(path + "/") else { return nil }
            switch target.entry {
            case .directory, .regularFile: break
            // Fehlt das Ziel nachweislich im Baum, deckt dessen Fingerabdruck ein späteres Erscheinen ab (#650).
            case .missing where missingInTree: break
            default: return nil
            }
        }
        return record(itemPath, status)
    }

    /// Bundle-Einträge, deren Metadaten `stamp(at:)` neben dem Ziel selbst erfasst.
    static let stampedBundlePaths = [
        "Contents", "Contents/_CodeSignature", "Contents/_CodeSignature/CodeResources", "Contents/Info.plist",
        "Contents/MacOS", "Contents/Resources", "Contents/Frameworks",
    ]

    /// Billige Metadaten für Teilscans (#259) statt der vollständigen Traversierung von `read(at:)`: das Ziel selbst,
    /// bei Bundles zusätzlich `stampedBundlePaths` und alle direkten Einträge von `Contents/MacOS` – je ein `lstat`.
    /// Erkennt Austausch des Bundles, neue Signatur, ein ersetztes oder verändertes Hauptprogramm sowie hinzugefügte,
    /// entfernte oder umbenannte Einträge dieser Verzeichnisse. Eine in place überschriebene Datei tiefer im Baum
    /// erkennt erst `read(at:)`. `nil`, wenn etwas nicht lesbar ist oder `Contents/MacOS` mehr als
    /// `maximumExecutables` Einträge hat – dann zählt nur `read(at:)`.
    static func stamp(at path: String, maximumExecutables: Int = 64) -> String? {
        guard case .present(let status) = metadata(of: path) else { return nil }
        var records = [record(path, status)]
        guard FileType.isDirectory(status) else { return digest(of: records) }
        let executables = path + "/Contents/MacOS"
        var paths = stampedBundlePaths.map { path + "/" + $0 }
        if case .present(let directory) = metadata(of: executables), FileType.isDirectory(directory) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: executables),
                  names.count <= maximumExecutables else { return nil }
            paths += names.map { executables + "/" + $0 }
        }
        for itemPath in paths {
            switch metadata(of: itemPath) {
            case .present(let status): records.append(record(itemPath, status))
            case .missing: records.append("\(itemPath.utf8.count):\(itemPath):-")
            case nil: return nil
            }
        }
        return digest(of: records)
    }

    private enum Metadata {
        case present(stat)
        case missing
    }

    /// `lstat`-Ergebnis; `nil` bei anderen Fehlern als einem fehlenden Eintrag.
    private static func metadata(of path: String) -> Metadata? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : nil }
        return .present(status)
    }

    // Length-prefix paths so filenames containing separators/newlines cannot alias another record.
    private static func record(_ itemPath: String, _ status: stat) -> String {
        "\(itemPath.utf8.count):\(itemPath):\(status.st_dev):\(status.st_ino):\(status.st_mode):\(status.st_uid):\(status.st_gid):\(status.st_size):\(status.st_flags):\(status.st_gen):\(status.st_mtimespec.tv_sec):\(status.st_mtimespec.tv_nsec):\(status.st_ctimespec.tv_sec):\(status.st_ctimespec.tv_nsec):\(status.st_birthtimespec.tv_sec):\(status.st_birthtimespec.tv_nsec)"
    }

    fileprivate static func digest(of records: [String]) -> String? {
        guard !records.isEmpty else { return nil }
        var hash = SHA256()
        for record in records.sorted() {
            hash.update(data: Data("\(record.utf8.count):\(record)".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}


/// Schritt einer fortsetzbaren Traversierung (`CodeTreeWalking.advance(cpuBudget:)`).
struct CodeTreeWalkStep: Equatable, Sendable {
    enum Progress: Equatable, Sendable {
        /// Budget erschöpft; der nächste Aufruf liest weiter.
        case partial
        /// Baum zu Ende gelesen: der Fingerabdruck wie `CodeTreeFingerprint.read(at:)`, `nil`, wenn er nicht vollständig
        /// erfassbar ist.
        case finished(String?)
    }

    let progress: Progress
    /// Rechenzeit dieses Schritts.
    let cpuTime: Duration
}

/// Fortsetzbare Traversierung eines Code-Baums für die Komplettprüfung in Blöcken (#662); `CodeTreeWalk`, in Tests ein
/// Double. Nur seriell benutzen (die Metadaten-Queue des `DeepSignatureVerifier`).
protocol CodeTreeWalking: AnyObject, Sendable {
    /// Liest weiter, bis der Baum zu Ende ist oder die Rechenzeit dieses Aufrufs `cpuBudget` erreicht (`nil`: ohne
    /// Budget, am Stück). Nach dem Ende liefert jeder weitere Aufruf dasselbe Ergebnis ohne Rechenzeit.
    func advance(cpuBudget: Duration?) -> CodeTreeWalkStep
}

/// `CodeTreeFingerprint.read(at:)` in Abschnitten (#662): Ein Block liest bis zu seinem CPU-Budget, der nächste setzt an
/// derselben Stelle fort; der Fingerabdruck gleicht dem am Stück. Die Grenzen gelten über alle Abschnitte: höchstens
/// `maximumEntries` Einträge und `timeout` aktive Lesezeit (ohne die Pausen zwischen den Blöcken). Eine Änderung im noch
/// nicht gelesenen Teil ändert den Fingerabdruck; eine im schon gelesenen erkennt – wie bei einer Traversierung am
/// Stück – erst die nächste Komplettprüfung oder der Bundle-Stempel, den der Verifier vor jedem Abschnitt vergleicht.
///
/// Hält den `fts`-Strom zwischen den Abschnitten offen; nur seriell benutzen (`@unchecked Sendable`: Der Verifier ruft
/// ausschließlich auf seiner seriellen Metadaten-Queue auf).
final class CodeTreeWalk: CodeTreeWalking, @unchecked Sendable {
    static let defaultMaximumEntries = 500_000
    static let defaultTimeout: Duration = .seconds(30)

    private let path: String
    private let maximumEntries: Int
    private let timeout: Duration
    /// Einträge zwischen zwei Blicken auf die Rechenzeit (ein Systemaufruf je Blick).
    private let checkInterval: Int
    private let volumes: [MountedVolume]
    private var argument: UnsafeMutablePointer<CChar>?
    private var stream: UnsafeMutablePointer<FTS>?
    private var records: [String] = []
    private var activeTime: Duration = .zero
    private var result: String??

    /// `nil`, wenn der Baum sich nicht öffnen lässt (etwa fehlt).
    init?(path: String, maximumEntries: Int = defaultMaximumEntries, timeout: Duration = defaultTimeout,
          checkInterval: Int = 32) {
        guard let argument = strdup(path) else { return nil }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            free(argument)
            return nil
        }
        self.path = path
        self.maximumEntries = maximumEntries
        self.timeout = timeout
        self.checkInterval = max(checkInterval, 1)
        self.argument = argument
        self.stream = stream
        volumes = MountedVolume.current()
    }

    deinit { close() }

    func advance(cpuBudget: Duration?) -> CodeTreeWalkStep {
        if let result { return CodeTreeWalkStep(progress: .finished(result), cpuTime: .zero) }
        let started = (cpu: ThreadCPUTime.now, wall: ContinuousClock.now)
        let deadline = started.wall + (timeout - activeTime)
        let progress = read(until: deadline, startedAt: started.cpu, cpuBudget: cpuBudget)
        activeTime += started.wall.duration(to: .now)
        return CodeTreeWalkStep(progress: progress, cpuTime: ThreadCPUTime.now - started.cpu)
    }

    private func read(until deadline: ContinuousClock.Instant, startedAt cpu: Duration,
                      cpuBudget: Duration?) -> CodeTreeWalkStep.Progress {
        guard let stream else { return finish(nil) }
        var processed = 0
        while true {
            if let cpuBudget, processed > 0, processed.isMultiple(of: checkInterval), ThreadCPUTime.now - cpu >= cpuBudget {
                return .partial
            }
            processed += 1
            errno = 0
            guard let entry = fts_read(stream) else { return finish(errno == 0 ? CodeTreeFingerprint.digest(of: records) : nil) }
            guard records.count < maximumEntries, ContinuousClock.now < deadline else { return finish(nil) }
            switch Int32(entry.pointee.fts_info) {
            case FTS_DP: continue
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE: break
            default: return finish(nil)
            }
            guard let record = CodeTreeFingerprint.record(of: entry, in: path, volumes: volumes) else { return finish(nil) }
            records.append(record)
        }
    }

    /// Ende: Ergebnis merken, Strom und Einträge freigeben.
    private func finish(_ fingerprint: String?) -> CodeTreeWalkStep.Progress {
        result = .some(fingerprint)
        close()
        records = []
        return .finished(fingerprint)
    }

    private func close() {
        if let stream { fts_close(stream) }
        stream = nil
        free(argument)
        argument = nil
    }
}
