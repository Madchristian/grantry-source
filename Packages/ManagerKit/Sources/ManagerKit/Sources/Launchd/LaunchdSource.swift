import Foundation
import os

/// Ein Verzeichnis mit launchd-Plists und die zugehörige launchctl-Domain.
public struct LaunchdDirectory: Sendable, Hashable {
    public let path: String
    public let kind: AutostartKind
    public let domain: AutostartDomain
    /// z. B. `gui/501` oder `system`.
    public let launchctlDomain: String

    public init(path: String, kind: AutostartKind, domain: AutostartDomain, launchctlDomain: String) {
        self.path = path
        self.kind = kind
        self.domain = domain
        self.launchctlDomain = launchctlDomain
    }

    /// Die drei Standardverzeichnisse für den aktuellen Benutzer.
    ///
    /// Setzt einen Benutzerkontext voraus: Als root (z. B. im Helper) ergäbe `getuid()` die Domain `gui/0`.
    public static func standard(uid: uid_t = getuid(), home: String = NSHomeDirectory()) -> [LaunchdDirectory] {
        let gui = "gui/\(uid)"
        return [
            LaunchdDirectory(path: home + "/Library/LaunchAgents", kind: .launchAgent, domain: .user, launchctlDomain: gui),
            LaunchdDirectory(
                path: PrivilegedOperationPolicy.systemLaunchAgentsDirectory, kind: .launchAgent, domain: .system, launchctlDomain: gui
            ),
            LaunchdDirectory(
                path: PrivilegedOperationPolicy.systemLaunchDaemonsDirectory, kind: .launchDaemon, domain: .system,
                launchctlDomain: PrivilegedOperationPolicy.systemLaunchctlDomain
            ),
        ]
    }
}

/// Fehler der launchd-Quelle.
public enum LaunchdSourceError: LocalizedError, Equatable {
    /// `launchctl arguments` scheiterte für `domain`: Exit-Code ungleich 0 oder – mit `exitCode == nil` –
    /// Start-/Timeout-Fehler.
    case launchctlFailed(domain: String, arguments: [String], exitCode: Int32?, message: String)

    public var errorDescription: String? {
        switch self {
        case .launchctlFailed(_, let arguments, let exitCode, let message):
            let command = (["launchctl"] + arguments).joined(separator: " ")
            let exit = exitCode.map { " (Exit \($0))" } ?? ""
            let detail = message.isEmpty ? "" : ": \(message)"
            return "\(command) fehlgeschlagen\(exit)\(detail)"
        }
    }
}

/// Liest LaunchAgents/-Daemons aus den Plist-Verzeichnissen und ergänzt den Status über `launchctl`.
///
/// Fehlende Verzeichnisse und Plists gibt es nicht – ihre Einträge gelten als entfernt. Ein vorhandenes, aber nicht
/// lesbares Verzeichnis und eine vorhandene, aber nicht auswertbare Plist (kaputt, ohne Label, keine reguläre Datei, zu
/// groß, keine Leserechte, während des Lesens unruhig) belegen dagegen nichts (#139): Die Quelle meldet sie als
/// unvollständige Abdeckung (`InventoryContribution.incompletePlistPaths` samt Grund in `limitations`), der Scan schreibt
/// die bekannten Einträge daraus mit altem Stand fort (`Snapshot.carryingForwardAutostartItems`). Gelesen werden nur
/// reguläre Dateien bis `maximumPlistSize` über `RegularFileReader` – eine FIFO oder ein Gerät hält den Scan nicht an.
/// Scheitert `launchctl` für eine Domain, scheitert die ganze Quelle: Ein Rückfall auf den `Disabled`-Schlüssel
/// der Plist würde per `launchctl disable` deaktivierte Einträge als aktiv melden. So greift stattdessen die
/// Fortschreibung des letzten gültigen Stands.
///
/// Der Ladezustand folgt aus den geladenen Labels der Domain. Ist ein Label nicht eindeutig einer Plist zuzuordnen –
/// ein `com.apple.`-Label (kann mit einem echten Apple-Dienst kollidieren), dasselbe Label in mehreren Plists
/// einer Domain oder eine Domain mit nicht auswertbaren Plists (deren Labels sind unbekannt) –, fragt die Quelle den Dienst einzeln ab (`LaunchdServiceProbe`): Geladen ist dann nur die Plist,
/// aus der launchd ihn geladen hat; scheitert die Abfrage, ist der Ladezustand unbekannt (`nil`).
///
/// Inhalt und Fingerabdruck einer Plist (`AutostartItem.plistFingerprint`) stammen aus demselben Lesevorgang
/// (`readPlist(at:)`): Der Fingerabdruck gilt für genau die gelesenen Bytes, nie für eine Datei, die ein Updater
/// während der anschließenden launchctl- und Eigentümerabfragen untergeschoben hat – sonst hielte das Aufräumen aus
/// einer Beobachtung die ersetzte Plist für den beobachteten Eintrag (#156).
///
/// Die Signatur des Programms (`AutostartItem.programSigning`) wird nur für absolute, vorhandene Pfade geprüft; der
/// Standard-Inspector merkt sich die Ergebnisse pro Fingerabdruck (`CachingSigningInspector`), ein Scan prüft also nur
/// neue oder veränderte Programme. Für dieselben Pfade erkennt die Quelle Skripte am Shebang und prüft deren
/// Interpreter (`AutostartItem.programScript`).
///
/// `ProgramArguments` gehen nur maskiert ins Modell (`AutostartItem.programArguments`, #137); was maskiert wurde,
/// erfasst ein Fingerabdruck mit dem Schlüssel dieser Installation (`SecretFingerprinter`). Rohe Argumente verlassen
/// die Quelle nicht – auch nicht ins Protokoll.
public struct LaunchdSource: InventorySource {
    public let id: SourceID = .launchd
    static let launchctl = "/bin/launchctl"
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "launchd")

    private let directories: [LaunchdDirectory]
    private let runner: any CommandRunning
    private let resolver: any AppResolving
    private let inspector: any SigningInspecting
    private let fingerprinter: SecretFingerprinter
    private let volumes: @Sendable () -> [MountedVolume]
    private let queue = BlockingWorkQueue(label: "launchd-signing")

    /// - Parameter fingerprinter: Schlüssel der Argument-Fingerabdrücke. Die Vorgabe ist flüchtig (Tests); die App
    ///   übergibt den dauerhaften Schlüssel ihres Ablageorts (`StorageLocation.secretFingerprinter()`).
    public init(
        directories: [LaunchdDirectory] = LaunchdDirectory.standard(), runner: any CommandRunning,
        resolver: any AppResolving, inspector: any SigningInspecting = CachingSigningInspector(),
        fingerprinter: SecretFingerprinter = .ephemeral()
    ) {
        self.init(directories: directories, runner: runner, resolver: resolver, inspector: inspector,
                  fingerprinter: fingerprinter, volumes: MountedVolume.current)
    }

    init(
        directories: [LaunchdDirectory], runner: any CommandRunning,
        resolver: any AppResolving, inspector: any SigningInspecting = CachingSigningInspector(),
        fingerprinter: SecretFingerprinter = .ephemeral(), volumes: @escaping @Sendable () -> [MountedVolume]
    ) {
        self.volumes = volumes
        self.directories = directories
        self.runner = runner
        self.resolver = resolver
        self.inspector = inspector
        self.fingerprinter = fingerprinter
    }

    /// Jede launchctl-Domain wird pro Durchlauf höchstens einmal abgefragt, jeder Eigentümer nur einmal aufgelöst.
    public func collect() async throws -> InventoryContribution {
        let volumes = volumes()
        let listings = directories.map { directory in (directory: directory, listing: Self.plists(in: directory.path)) }
        let entries = listings.flatMap { directory, listing in
            listing.plists.map { Entry(directory: directory, path: $0.path, contents: $0.contents) }
        }
        let gaps = listings.flatMap(\.listing.gaps)
        let incompleteDomains = Set(listings.filter { !$0.listing.gaps.isEmpty }.map(\.directory.launchctlDomain))
        let labelCounts = Dictionary(entries.compactMap { $0.serviceKey.map { ($0, 1) } }, uniquingKeysWith: +)
        var states: [String: DomainState] = [:]
        var owners: [OwnerKey: AppIdentity] = [:]
        var items: [AutostartItem] = []
        for entry in entries {
            let domain = entry.directory.launchctlDomain
            let state: DomainState
            if let known = states[domain] {
                state = known
            } else {
                state = try await domainState(domain)
                states[domain] = state
            }
            var owner: AppIdentity?
            if let key = OwnerKey(entry.plist) {
                if let known = owners[key] {
                    owner = known
                } else {
                    owner = await resolve(key, volumes: volumes)
                    owners[key] = owner
                }
            }
            let isAmbiguous = entry.serviceKey.map { labelCounts[$0, default: 0] > 1 } ?? true
                || incompleteDomains.contains(domain)
            let isLoaded = try await loadState(of: entry, in: state, isAmbiguous: isAmbiguous)
            let resolvedOwner = owner
            items.append(await queue.run {
                item(from: entry, state: state, isLoaded: isLoaded, owner: resolvedOwner, volumes: volumes)
            })
        }
        return InventoryContribution(
            autostartItems: items, incompletePlistPaths: gaps.map(\.path), limitations: gaps.map(\.description)
        )
    }

    /// Eine gelesene Plist samt Verzeichnis.
    private struct Entry {
        let directory: LaunchdDirectory
        let path: String
        let contents: PlistContents

        var plist: LaunchdPlist { contents.plist }

        /// launchd führt Dienste je Domain nach Label (`AutostartItem.launchdServiceID`).
        var serviceKey: String? { AutostartItem.launchdServiceID(kind: directory.kind, label: plist.label) }
    }

    /// Inhalt einer Plist und der Fingerabdruck der Datei, aus der er gelesen wurde.
    struct PlistContents {
        let plist: LaunchdPlist
        /// `nil`, wenn die Attribute der Datei nicht lesbar waren.
        let fingerprint: FileFingerprint?
    }

    /// Wie oft `readPlist(at:)` eine Datei neu liest, die sich während des Lesens verändert hat.
    static let readAttempts = 3
    /// Höchstgröße einer gelesenen Plist (`PrivilegedOperationPolicy.maximumPlistSize`).
    static let maximumPlistSize = PrivilegedOperationPolicy.maximumPlistSize

    /// Ergebnis von `readPlist(at:)`.
    enum PlistRead {
        case contents(PlistContents)
        /// Die Datei gibt es (inzwischen) nicht.
        case missing
        /// Vorhanden, aber nicht auswertbar; Grund im Klartext ohne Inhalt.
        case unreadable(String)
    }

    /// Liest Inhalt und Fingerabdruck zusammen: Der Fingerabdruck wird vor und nach dem Lesen genommen; weichen beide
    /// ab, wurde die Datei währenddessen ersetzt oder umgeschrieben, und das Lesen beginnt von vorn (bis zu
    /// `readAttempts` Versuche). Bleibt sie unruhig, ist sie nicht auswertbar. Gelesen wird über `RegularFileReader`
    /// (nur reguläre Dateien bis `maximumPlistSize`, ohne Blockieren an Sonderdateien).
    static func readPlist(at path: String) -> PlistRead {
        for _ in 0..<readAttempts {
            let before = FileFingerprint(of: path)
            switch RegularFileReader.read(atPath: path, maximumSize: maximumPlistSize) {
            case .missing:
                return .missing
            case .unreadable(let reason):
                return .unreadable(reason)
            case .contents(let data, _):
                guard FileFingerprint(of: path) == before else { continue }
                guard let plist = try? LaunchdPlist.decode(data) else { return .unreadable(invalidPlistText) }
                return .contents(PlistContents(plist: plist, fingerprint: before))
            }
        }
        return .unreadable(changedWhileReadingText)
    }

    static let invalidPlistText = "keine gültige launchd-Plist mit Label"
    static let changedWhileReadingText = "während des Lesens mehrfach verändert"

    /// Ladezustand: nicht geladene Labels sind `false`, eindeutige geladene `true`. Mehrdeutige Labels (siehe
    /// Typ-Dokumentation) klärt `LaunchdServiceProbe`; scheitert die Abfrage, ist der Zustand `nil`.
    private func loadState(of entry: Entry, in state: DomainState, isAmbiguous: Bool) async throws -> Bool? {
        guard state.loaded.contains(entry.plist.label) else { return false }
        guard isAmbiguous || AppleIdentifier.matches(entry.plist.label) else { return true }
        do {
            let binding = try await LaunchdServiceProbe(runner: runner)
                .binding(ofLabel: entry.plist.label, in: entry.directory.launchctlDomain, toPlistAt: entry.path)
            return binding == .loadedFromPlist
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("Ladezustand von \(entry.path, privacy: .public) unbekannt: \(error.readableDescription, privacy: .public)")
            return nil
        }
    }

    /// Deaktivierungs-Overrides und geladene Labels einer launchctl-Domain.
    private struct DomainState {
        let disabledOverrides: [String: Bool]
        let loaded: Set<String>
    }

    private func domainState(_ domain: String) async throws -> DomainState {
        DomainState(
            disabledOverrides: try await parsedOutput(of: ["print-disabled", domain], domain: domain, LaunchctlParsers.disabledOverrides),
            loaded: try await parsedOutput(of: ["print", domain], domain: domain, LaunchctlParsers.loadedLabels)
        )
    }

    /// Geparste Standardausgabe von `launchctl arguments`. `CancellationError` wird unverändert weitergereicht,
    /// jeder andere Fehler, jeder Exit-Code ungleich 0 und eine vom Parser abgelehnte Ausgabe (`nil`) als
    /// `LaunchdSourceError.launchctlFailed`.
    private func parsedOutput<Parsed>(
        of arguments: [String], domain: String, _ parse: (String) -> Parsed?
    ) async throws -> Parsed {
        let result = try await runner.launchctl(arguments, domain: domain)
        if result.succeeded, let parsed = parse(result.stdout) { return parsed }
        throw LaunchdSourceError.failed(
            result, domain: domain, arguments: arguments, message: result.succeeded ? "unerwartetes Ausgabeformat" : nil
        )
    }

    private func item(from entry: Entry, state: DomainState, isLoaded: Bool?, owner: AppIdentity?, volumes: [MountedVolume]) -> AutostartItem {
        let (directory, path, plist) = (entry.directory, entry.path, entry.plist)
        let isDisabled = state.disabledOverrides[plist.label] ?? plist.disabled
        let presence = plist.executable.map { Self.programPresence($0, volumes: volumes) } ?? .unknown
        // `.present` setzt einen absoluten Pfad voraus (siehe `programPresence`).
        let presentProgram = presence == .present ? plist.executable : nil
        // Ab hier nur noch maskiert: `plist.executable` und `plist.programArguments` dienen oben und unten allein den
        // Prüfungen in der Quelle (Vorhandensein, Signatur, Skript, Eigentümer).
        let command = MaskedCommand(
            program: plist.program, arguments: plist.programArguments ?? [],
            resolvingPath: { CommandInterpreterPath.resolve($0, volumes: volumes) }, fingerprinter: fingerprinter
        )
        return AutostartItem(
            kind: directory.kind,
            domain: directory.domain,
            label: plist.label,
            program: command.program,
            programPresence: presence,
            isEnabled: !isDisabled,
            isLoaded: isLoaded,
            plistPath: path,
            owner: owner,
            source: id,
            programSigning: presentProgram.map(inspector.inspect),
            sessionTypes: plist.sessionTypes,
            launchesInterpreter: plist.launchesInterpreter,
            programScript: presentProgram.flatMap { script(at: $0, overridesPath: plist.overridesPath, volumes: volumes) },
            plistFingerprint: entry.contents.fingerprint,
            programArguments: command.arguments,
            programArgumentsFingerprint: command.fingerprint, hasHiddenScript: command.hasHiddenScript
        )
    }

    /// Skript-Angaben zu `program`, wenn es mit `#!` beginnt. Geprüft wird die Signatur des Interpreters – nur bei
    /// absolutem, vorhandenem Pfad (wie beim Programm selbst). Bei `/usr/bin/env <name>` wird `name` gegen launchds
    /// Standard-PATH aufgelöst und geprüft, sofern die Plist keinen eigenen `PATH` setzt (`overridesPath`). Die
    /// Shebang-Argumente gehen wie die `ProgramArguments` nur maskiert ins Modell (#137).
    private func script(at program: String, overridesPath: Bool, volumes: [MountedVolume]) -> ProgramScript? {
        ScriptFile.shebang(atPath: program).map { shebang in
            ProgramScript(
                interpreter: shebang.interpreter,
                arguments: Array(ArgumentRedactor.redact(arguments: [shebang.interpreter] + shebang.arguments,
                    resolvingPath: { CommandInterpreterPath.resolve($0, volumes: volumes) }).values.dropFirst()),
                interpreterSigning: signing(ofProgramAt: shebang.interpreter, volumes: volumes),
                resolvedEnvProgram: overridesPath ? nil : shebang.envProgram
                    .flatMap { LaunchdSearchPath.executable(named: $0) }
                    .map { ProgramScript.ResolvedProgram(path: $0, signing: inspector.inspect(path: $0)) }
            )
        }
    }

    /// Interpreterpfad für die Maskierung: Symlinks und bytegleiche System-Shell-Kopien, nur absolute Pfade.
    /// Keine Signaturprüfung; nicht sicher lokale Pfade gelten konservativ als Shell-Kandidaten.
    static func resolvedPath(_ path: String) -> String? {
        CommandInterpreterPath.resolve(path)
    }

    /// Signatur von `path`, nur bei absolutem, vorhandenem Pfad; sonst `nil`.
    private func signing(ofProgramAt path: String, volumes: [MountedVolume]) -> SigningInfo? {
        Self.programPresence(path, volumes: volumes) == .present ? inspector.inspect(path: path) : nil
    }

    /// Nur absolute Pfade lassen sich zuverlässig prüfen. Nackte Programmnamen (`node`, `sh`) löst launchd über
    /// einen `PATH` auf, den die Plist per `EnvironmentVariables` überschreiben kann – ihre Existenz ist daher
    /// unbekannt, statt sie fälschlich als verwaist zu markieren. Dasselbe gilt für nicht sicher lokale Pfade:
    /// Keine Existenz-/Signatur-/Shebang-Abfrage darf die Volume-Prüfung der Maskierung vorwegnehmen (#193).
    static func programPresence(_ executable: String, volumes: [MountedVolume] = MountedVolume.current()) -> Presence {
        guard let target = LocalPathResolver.resolve(executable, volumes: volumes) else { return .unknown }
        if case .missing = target.entry { return .missing }
        return .present
    }

    private func resolve(_ key: OwnerKey, volumes: [MountedVolume]) async -> AppIdentity {
        switch key {
        case .bundleID(let bundleID): return await resolver.resolve(bundleID: bundleID)
        case .path(let path):
            // A remote program's inferred bundle must not trigger metadata/signature I/O before masking either.
            guard await queue.run({ LocalPathResolver.resolve(path, volumes: volumes) != nil }) else {
                return AppIdentity(bundleID: nil, path: path, displayName: path.split(separator: "/").last.map(String.init) ?? path,
                                   signing: SigningInfo(kind: .unknown), presence: .unknown)
            }
            return await resolver.resolve(path: path)
        }
    }

    /// Woran der Eigentümer erkannt wird: zuerst `AssociatedBundleIdentifiers`, sonst das App-Bundle im Programmpfad.
    private enum OwnerKey: Hashable {
        case bundleID(String)
        case path(String)

        init?(_ plist: LaunchdPlist) {
            if let bundleID = plist.associatedBundleIdentifiers.first {
                self = .bundleID(bundleID)
            } else if let bundlePath = plist.owningAppBundlePath {
                self = .path(bundlePath)
            } else {
                return nil
            }
        }
    }

    /// Stelle, die die Quelle nicht auswerten konnte (#139): ein Verzeichnis oder eine Plist, samt Grund.
    struct CoverageGap: Equatable, CustomStringConvertible {
        let path: String
        let isDirectory: Bool
        let reason: String

        /// Einschränkung im Klartext (`SourceLimitation`).
        var description: String {
            let subject = isDirectory ? "Verzeichnis \(path) nicht lesbar" : "Plist \(path) nicht auswertbar"
            return "\(subject) (\(reason)) – bekannte Einträge bleiben mit altem Stand erhalten"
        }
    }

    /// Gelesene Plists eines Verzeichnisses und die Stellen, die sich nicht auswerten ließen.
    struct DirectoryListing {
        var plists: [(path: String, contents: PlistContents)] = []
        var gaps: [CoverageGap] = []
    }

    /// Alle `.plist`-Dateien eines Verzeichnisses, nach Namen sortiert. Ein nachweislich fehlendes Verzeichnis
    /// (`DirectoryReader`: nur `ENOENT`/`ENOTDIR`) ergibt still eine leere Liste, ebenso eine inzwischen verschwundene
    /// Plist. Ein nicht auflistbares Verzeichnis – auch mangels Suchrecht auf einem übergeordneten – und nicht
    /// auswertbare Plists werden protokolliert und als Lücke gemeldet (`CoverageGap`), die übrigen Plists weiter gelesen.
    static func plists(in directory: String) -> DirectoryListing {
        let names: [String]
        switch DirectoryReader.entries(atPath: directory) {
        case .missing:
            return DirectoryListing()
        case .unreadable(let reason):
            logger.error("Verzeichnis \(directory, privacy: .public) nicht lesbar: \(reason, privacy: .public)")
            return DirectoryListing(gaps: [CoverageGap(path: directory, isDirectory: true, reason: RegularFileReader.unreadableText)])
        case .entries(let entries):
            names = entries
        }
        var listing = DirectoryListing()
        for name in names.filter({ $0.hasSuffix(".plist") }).sorted() {
            let path = directory + "/" + name
            switch readPlist(at: path) {
            case .contents(let contents):
                listing.plists.append((path, contents))
            case .missing:
                continue
            case .unreadable(let reason):
                logger.error("Plist \(path, privacy: .public) nicht auswertbar: \(reason, privacy: .public)")
                listing.gaps.append(CoverageGap(path: path, isDirectory: false, reason: reason))
            }
        }
        return listing
    }
}
