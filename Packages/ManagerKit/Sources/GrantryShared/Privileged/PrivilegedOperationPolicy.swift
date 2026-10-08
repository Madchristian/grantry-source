import Foundation

/// Verstoß gegen die Regeln für privilegierte Operationen.
public enum PolicyViolation: LocalizedError, Equatable {
    case invalidLabel(String)
    case appleLabel(String)
    case pathNotAllowed(String)
    /// Unter dem Label ist ein Dienst aus einer anderen (oder keiner erkennbaren) Plist geladen; labelgebundene
    /// Befehle träfen ihn (`LaunchdServiceBinding.loadedFromElsewhere`).
    case conflictingService(String)
    /// Eine zweite Plist in den Verzeichnissen der Domain trägt dasselbe Label; ein Override (`enable`/`disable`)
    /// gilt in launchd je Label und schaltete sie mit um.
    case ambiguousLabel(String, otherPath: String)
    /// Ein vorhandenes Verzeichnis ließ sich nicht lesen; ob ein Label dort doppelt vorkommt, ist damit unbekannt.
    case unreadableDirectory(String)
    /// Eine weitere reguläre Plist im Verzeichnis ließ sich nicht auswerten (keine Leserechte, zu groß, kaputt); ob sie
    /// dasselbe Label trägt, ist damit unbekannt.
    case unverifiableLabel(String)
    /// Der mitgeschickte Fingerabdruck einer Plist (`FileFingerprint`, JSON) ist nicht lesbar.
    case invalidFingerprint

    public var errorDescription: String? {
        switch self {
        case .invalidLabel(let label): "Ungültiges launchd-Label: \(label)"
        case .appleLabel(let label): "Apple-Komponenten sind schreibgeschützt: \(label)"
        case .pathNotAllowed(let path): "Pfad ist für diese Aktion nicht erlaubt: \(path)"
        case .conflictingService(let label):
            "Ein gleichnamiger Dienst aus einer anderen Datei ist geladen – Aktion abgebrochen: \(label)"
        case .ambiguousLabel(let label, let otherPath):
            "Eine andere Datei trägt dasselbe Label – Aktion abgebrochen: \(label) (\(otherPath))"
        case .unreadableDirectory(let path): "Verzeichnis nicht lesbar – Aktion abgebrochen: \(path)"
        case .unverifiableLabel(let path): "Label einer anderen Plist nicht prüfbar – Aktion abgebrochen: \(path)"
        case .invalidFingerprint: "Fingerabdruck der Datei nicht lesbar – Aktion abgebrochen, bitte neu scannen"
        }
    }
}

/// Prüft jede Eingabe einer privilegierten Operation, bevor sie ausgeführt wird. Wird von App und Helper
/// gleichermaßen genutzt; maßgeblich ist die Prüfung im Helper.
public struct PrivilegedOperationPolicy: Sendable {
    public init() {}

    /// launchd-Labels: Buchstaben, Ziffern, `.`, `_`, `-`, `@`, `+`; beginnt alphanumerisch; höchstens 255 Zeichen;
    /// nicht `com.apple.*`. `@` kommt real vor (z. B. `homebrew.mxcl.postgresql@14`).
    public func validateLabel(_ label: String) throws(PolicyViolation) {
        try validateLabelSyntax(label)
        guard !AppleIdentifier.matches(label) else { throw .appleLabel(label) }
    }

    /// Nur die Syntax von `validateLabel(_:)`, ohne Apple-Sperre: für Operationen im Benutzerkontext, bei denen der
    /// Aufrufer anhand der Herkunft (Signatur, Pfad) entschieden hat, dass ein `com.apple.`-Label nur Tarnung ist.
    public func validateLabelSyntax(_ label: String) throws(PolicyViolation) {
        guard label.count <= 255, label.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._@+-]*/) != nil else {
            throw .invalidLabel(label)
        }
    }

    /// Die Datei muss eine reguläre `.plist`-Datei (kein Symlink) **direkt** in einem der verwalteten
    /// Verzeichnisse sein; ein Pfad mit abschließendem `/` wird abgelehnt.
    ///
    /// - Returns: den aufgelösten, kanonischen Pfad. Aufrufer müssen mit **diesem** Pfad weiterarbeiten,
    ///   nie mit dem ursprünglichen Eingabepfad (der kanonische Pfad hat Symlinks bereits aufgelöst).
    @discardableResult
    public func validatePlistPath(_ path: String, managedDirectories: [String]) throws(PolicyViolation) -> String {
        guard !path.hasSuffix("/") else { throw .pathNotAllowed(path) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "plist",
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink != true, values.isRegularFile == true else {
            throw .pathNotAllowed(path)
        }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let allowed = managedDirectories.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        guard allowed.contains(parent) else { throw .pathNotAllowed(path) }
        return url.resolvingSymlinksInPath().path
    }

    /// Systemweites LaunchDaemons-Verzeichnis – einziger Ort, auf dessen Plists der Helper launchctl anwendet.
    public static let systemLaunchDaemonsDirectory = "/Library/LaunchDaemons"

    /// launchctl-Domain der LaunchDaemons.
    public static let systemLaunchctlDomain = "system"

    /// Systemweites LaunchAgents-Verzeichnis; seine Agents laufen wie die aus `~/Library/LaunchAgents` in `gui/<uid>`.
    public static let systemLaunchAgentsDirectory = "/Library/LaunchAgents"

    /// Apples LaunchDaemons-Verzeichnisse: Ihre Plists belegen ebenfalls Labels der Domain `system` (auch solche ohne
    /// `com.apple.`-Präfix wie `org.cups.cupsd` oder `com.openssh.sshd`), der Helper verändert sie nie.
    public static let appleLaunchDaemonsDirectories = [
        "/System/Library/LaunchDaemons", "/Library/Apple/System/Library/LaunchDaemons",
    ]

    /// Stellt sicher, dass keine andere Plist direkt in einem der `directories` das Label `label` trägt. Overrides
    /// (`launchctl enable|disable`) gelten in launchd je Label: Eine zweite Plist mit demselben Label – auch eine
    /// gerade nicht geladene – würde mit umgeschaltet, deshalb lehnt der Helper die Änderung dann ab.
    ///
    /// Zählt nur Dateien mit Endung `.plist` (Symlinks werden gefolgt, launchd läse sie ebenso). Fehlende Dateien und
    /// Verzeichnisse, Plists ohne `Label` und Einträge, die keine reguläre Datei sind (FIFO, Gerät, Verzeichnis – launchd
    /// lädt sie nicht), stören nicht. Gelesen wird über `RegularFileReader` – eine FIFO oder ein Gerät mit
    /// Plist-Endung hält die Prüfung nicht an. Die eigene Plist (`plistPath`, kanonisch verglichen) ist keine zweite.
    ///
    /// Fail-closed: Was vorhanden ist, aber nicht ausgewertet werden kann, ist kein „eindeutig“ – lieber ablehnen als
    /// blind umschalten. Ein Verzeichnis, das nicht nachweislich fehlt, aber nicht auflistbar ist (auch mangels
    /// Suchrecht auf einem übergeordneten Verzeichnis, `DirectoryReader`), ergibt `unreadableDirectory`, eine reguläre Plist ohne
    /// Leserecht, über `maximumPlistSize` oder mit kaputtem Inhalt `unverifiableLabel` (ihr Label könnte das
    /// gesuchte sein).
    public func ensureLabelIsUnique(_ label: String, ofPlistAt plistPath: String, in directories: [String]) throws(PolicyViolation) {
        let own = FilePath.canonical(plistPath)
        for directory in directories {
            let entries: [String]
            switch DirectoryReader.entries(atPath: directory) {
            case .missing: continue
            case .unreadable: throw .unreadableDirectory(directory)
            case .entries(let names): entries = names
            }
            for name in entries where name.hasSuffix(".plist") {
                let candidate = URL(fileURLWithPath: directory).appending(path: name)
                let canonical = FilePath.canonical(candidate.path)
                guard canonical != own else { continue }
                switch Self.candidateLabel(ofPlistAt: candidate) {
                case .absent: continue
                case .known(let candidateLabel): if candidateLabel == label { throw .ambiguousLabel(label, otherPath: canonical) }
                case .unknown: throw .unverifiableLabel(canonical)
                }
            }
        }
    }

    /// Höchstgröße einer gelesenen launchd-Plist – echte sind wenige KB groß.
    public static let maximumPlistSize = 1 << 20

    /// Was über das Label einer Plist bekannt ist (`candidateLabel(ofPlistAt:)`).
    private enum CandidateLabel: Equatable {
        /// Keine Plist, die launchd laden könnte: Die Datei fehlt (auch ein ins Leere zeigender Symlink) oder ist keine
        /// reguläre Datei.
        case absent
        /// Gelesen; `nil`, wenn sie kein `Label` (als Text) trägt – launchd lädt sie dann nicht.
        case known(String?)
        /// Reguläre Datei, aber nicht auswertbar (keine Leserechte, zu groß, kaputt): Das Label ist unbekannt.
        case unknown
    }

    /// Label der Plist unter `url`, unterschieden nach „fehlt“, „gelesen“ und „vorhanden, aber nicht auswertbar“.
    private static func candidateLabel(ofPlistAt url: URL) -> CandidateLabel {
        switch RegularFileReader.read(atPath: url.path, maximumSize: maximumPlistSize) {
        case .missing:
            return .absent
        case .contents(let data, _):
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            else { return .unknown }
            return .known(plist["Label"] as? String)
        case .unreadable:
            // Erst der Grund entscheidet: Eine Sonderdatei lädt launchd nicht, eine unlesbare reguläre Datei schon.
            var info = stat()
            guard stat(url.path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .absent : .unknown }
            return info.st_mode & S_IFMT == S_IFREG ? .unknown : .absent
        }
    }

    /// `Label` der Plist oder `nil`, wenn sie fehlt, keine reguläre Datei bis `maximumPlistSize`, unlesbar ist oder
    /// keines trägt.
    private static func readLabel(ofPlistAt url: URL) -> String? {
        if case .known(let label) = candidateLabel(ofPlistAt: url) { label } else { nil }
    }

    /// Liest das `Label` aus einer Plist, die direkt in einem der `managedDirectories` liegt, und validiert
    /// Pfad und Label (`validatePlistPath`, `validateLabel`). So wirkt eine privilegierte Operation nie auf
    /// eine Apple-Plist (`com.apple.*`), auch wenn Dateiname oder Aufrufer etwas anderes behaupten.
    /// - Returns: den kanonischen Pfad (siehe `validatePlistPath`) und das validierte Label.
    public func label(
        forPlistAt path: String,
        managedDirectories: [String]
    ) throws(PolicyViolation) -> (path: String, label: String) {
        let canonicalPath = try validatePlistPath(path, managedDirectories: managedDirectories)
        guard let label = Self.readLabel(ofPlistAt: URL(fileURLWithPath: canonicalPath)) else { throw .pathNotAllowed(path) }
        try validateLabel(label)
        return (canonicalPath, label)
    }

    /// Wie `label(forPlistAt:managedDirectories:)`, aber ausschließlich für Plists direkt in
    /// `launchDaemonsDirectory`. Der Helper ermittelt Labels für launchctl **ausschließlich** über diese
    /// Methode – nie über ein vom Aufrufer mitgeliefertes Label – damit er stets auf das tatsächlich
    /// installierte LaunchDaemon wirkt.
    public func launchDaemonLabel(
        forPlistAt path: String,
        launchDaemonsDirectory: String = systemLaunchDaemonsDirectory
    ) throws(PolicyViolation) -> (path: String, label: String) {
        try label(forPlistAt: path, managedDirectories: [launchDaemonsDirectory])
    }
}
