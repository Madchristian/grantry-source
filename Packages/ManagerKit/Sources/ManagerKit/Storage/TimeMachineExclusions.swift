import Foundation
import GrantryShared

/// Ordner, den Grantry zum Ausnehmen aus Time Machine vorschlägt (#227, `StorageCatalog.timeMachineCandidates`).
public struct TimeMachineCandidate: Identifiable, Hashable, Sendable {
    public let title: String
    public let path: String
    /// „niedrig“: vorausgewählt; „mittel“: nur auf ausdrückliche Wahl.
    public let risk: StorageRisk
    /// Speicher-Kategorie, deren Merkmal „von Time Machine gesichert“ dieser Ordner bestimmt; `nil` ohne.
    public let categoryID: String?
    /// Liegt in einem App-Container (`~/Library/Containers`): nur mit Festplattenvollzugriff geprüft.
    public let needsFullDiskAccess: Bool

    public init(title: String, path: String, risk: StorageRisk, categoryID: String?, needsFullDiskAccess: Bool = false) {
        self.title = title
        self.path = path
        self.risk = risk
        self.categoryID = categoryID
        self.needsFullDiskAccess = needsFullDiskAccess
    }

    public var id: String { path }
}

/// Antwort von `tmutil isexcluded`.
public enum TimeMachineBackupState: Hashable, Sendable {
    case included, excluded, unknown
}

/// Ein vorhandener Vorschlag mit Größe und Sicherungsstatus beim Scan.
public struct TimeMachineSuggestion: Identifiable, Hashable, Sendable {
    public let candidate: TimeMachineCandidate
    public let size: FileSize
    public let state: TimeMachineBackupState
    /// Das Objekt beim Scan; vor einer Änderung muss es noch dasselbe sein.
    let identity: FileIdentity?

    init(candidate: TimeMachineCandidate, size: FileSize, state: TimeMachineBackupState, identity: FileIdentity?) {
        self.candidate = candidate
        self.size = size
        self.state = state
        self.identity = identity
    }

    public var id: String { candidate.id }
    /// Nur Risiko „niedrig“ und nur, solange Time Machine den Ordner noch sichert.
    public var isPreselected: Bool { candidate.risk == .low && state == .included }
    /// „1,2 GB“, „Größe unbekannt“, „Größe nicht lesbar“ (`RemovalSize.text`).
    public var sizeText: String { RemovalSize(sizes: [size]).text }
}

/// Ergebnis des Scans; `failure`: `tmutil isexcluded` ist gescheitert, alle Status sind dann unbekannt.
public struct TimeMachineReport: Hashable, Sendable {
    public let suggestions: [TimeMachineSuggestion]
    public let failure: String?

    public init(suggestions: [TimeMachineSuggestion], failure: String?) {
        self.suggestions = suggestions
        self.failure = failure
    }

    /// Vorschläge der Kategorien `categoryIDs` mit unbekannter Größe: Ihre Ordner wurden gerade aufgeräumt (#285), die
    /// Größe vom Scan ist veraltet, bis `TimeMachineExclusions.refresh` sie neu liest.
    public func invalidatingSizes(ofCategories categoryIDs: Set<String>) -> TimeMachineReport {
        TimeMachineReport(suggestions: suggestions.map { suggestion in
            guard let categoryID = suggestion.candidate.categoryID, categoryIDs.contains(categoryID) else { return suggestion }
            return TimeMachineSuggestion(candidate: suggestion.candidate, size: .unknown, state: suggestion.state,
                                         identity: suggestion.identity)
        }, failure: failure)
    }
}

/// Gewünschte Änderung an der Time-Machine-Sicherung.
public enum TimeMachineChange: Hashable, Sendable {
    /// `tmutil addexclusion` (ohne `-p`: der Ausschluss haftet am Ordner und braucht weder Helper noch Admin).
    case exclude
    /// `tmutil removeexclusion`.
    case include

    var verb: String { self == .exclude ? "addexclusion" : "removeexclusion" }
    /// Status nach der Änderung; Ordner, die ihn schon haben, werden übersprungen.
    var resultingState: TimeMachineBackupState { self == .exclude ? .excluded : .included }
    var method: StorageCleanOutcome.Method { self == .exclude ? .timeMachineExclude : .timeMachineInclude }
}

/// Liest und ändert Time-Machine-Ausschlüsse über `/usr/bin/tmutil` (#227) – nie automatisch, nur für bestätigte
/// Vorschläge. Jeder Aufruf läuft über `CommandRunning` mit `timeout` und außerhalb des Aufrufer-Actors. Die Ausgänge
/// sind Zeilen für `CleanupLog`.
public struct TimeMachineExclusions: Sendable {
    static let tmutil = "/usr/bin/tmutil"
    public static let timeout: Duration = .seconds(30)
    /// Kategorie der Ausgänge im `CleanupLog`.
    public static let categoryID = "timeMachineExclusions"

    let runner: any CommandRunning
    let measurer: any FileSizeMeasuring
    let canReadAppContainers: @Sendable () async -> Bool

    init(runner: any CommandRunning, measurer: any FileSizeMeasuring, canReadAppContainers: @escaping @Sendable () async -> Bool) {
        self.runner = runner
        self.measurer = measurer
        self.canReadAppContainers = canReadAppContainers
    }

    /// Mit den echten Abhängigkeiten der App.
    public init() {
        self.init(runner: ProcessCommandRunner(), measurer: FileSizeCalculator(timeout: FileSizeCalculator.appTimeout),
                  canReadAppContainers: { await FullDiskAccessProbe().hasFullDiskAccess() })
    }

    /// Vorhandene Ordner (keine Symlinks) mit Größe und Status; ein einziger `tmutil isexcluded`-Aufruf für alle.
    /// Gemessen wird nur, was `knownSizes` (`knownSizes(from:)`) nicht schon kennt.
    @concurrent
    public func scan(_ candidates: [TimeMachineCandidate],
                     knownSizes: [String: FileSize] = [:]) async -> TimeMachineReport {
        let readsContainers = candidates.contains(where: \.needsFullDiskAccess) ? await canReadAppContainers() : false
        let present = candidates.compactMap { candidate -> (TimeMachineCandidate, FileIdentity)? in
            guard readsContainers || !candidate.needsFullDiskAccess, let identity = FileIdentity.of(candidate.path),
                  identity.type == .directory else { return nil }
            return (candidate, identity)
        }
        guard !present.isEmpty else { return TimeMachineReport(suggestions: [], failure: nil) }
        let paths = present.map(\.0.path)
        let (states, failure) = await states(of: paths)
        let unmeasured = paths.filter { knownSizes[$0] == nil }
        let measured = Dictionary(zip(unmeasured, await ConcurrentMeasurement.sizes(of: unmeasured, measurer: measurer)),
                                  uniquingKeysWith: { first, _ in first })
        let suggestions = present.map { candidate, identity in
            TimeMachineSuggestion(candidate: candidate, size: knownSizes[candidate.path] ?? measured[candidate.path] ?? .unknown,
                                  state: states[candidate.path] ?? .unknown, identity: identity)
        }
        return TimeMachineReport(suggestions: suggestions, failure: failure)
    }

    /// Nach dem Aufräumen der Kategorien `categoryIDs` nur deren Vorschläge neu lesen (#285): Größen aus dem Nachscan
    /// `reports`, sonst gemessen; die übrigen bleiben unverändert und werden weder gemessen noch abgefragt. Inzwischen
    /// fehlende Ordner fallen weg.
    @concurrent
    public func refresh(_ report: TimeMachineReport, categories categoryIDs: Set<String>,
                        reports: [StorageCategoryReport]) async -> TimeMachineReport {
        func isAffected(_ suggestion: TimeMachineSuggestion) -> Bool {
            suggestion.candidate.categoryID.map(categoryIDs.contains) ?? false
        }
        let affected = report.suggestions.filter(isAffected)
        guard !affected.isEmpty else { return report }
        let refreshed = await scan(affected.map(\.candidate), knownSizes: Self.knownSizes(from: reports))
        let byPath = Dictionary(refreshed.suggestions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return TimeMachineReport(suggestions: report.suggestions.compactMap { isAffected($0) ? byPath[$0.id] : $0 },
                                 failure: refreshed.failure ?? report.failure)
    }

    /// Ein `tmutil isexcluded`-Aufruf für alle Pfade; `failure`, wenn er scheitert.
    private func states(of paths: [String]) async -> (states: [String: TimeMachineBackupState], failure: String?) {
        do {
            let result = try await runner.run(Self.tmutil, ["isexcluded"] + paths, timeout: Self.timeout)
            return result.succeeded ? (Self.parse(result.stdout), nil) : ([:], result.failureReason)
        } catch {
            return ([:], error.readableDescription)
        }
    }

    /// Bekannte Größen aus dem Speicher-Scan, damit große Ordner nicht doppelt gemessen werden: jeder Eintrag mit
    /// gelesener Größe und jede Kategorie-Wurzel als Summe ihrer direkten Einträge, sofern alle gelesen sind. Auslassungen
    /// der Kategorie (versteckte Namen, `com.apple.…`) fehlen in der Summe.
    public static func knownSizes(from reports: [StorageCategoryReport]) -> [String: FileSize] {
        var sizes: [String: FileSize] = [:]
        for report in reports {
            for item in report.items { if let path = item.path, let bytes = item.size.bytes { sizes[path] = .bytes(bytes) } }
            for root in report.category.roots {
                let children = report.items.filter { $0.path.map { ($0 as NSString).deletingLastPathComponent } == root }
                let bytes = children.compactMap(\.size.bytes)
                if !children.isEmpty, bytes.count == children.count { sizes[root] = .bytes(bytes.reduce(0, +)) }
            }
        }
        return sizes
    }

    /// Je Vorschlag ein Ausgang. Übersprungen wird, was den Zielstatus schon hat oder seit dem Scan ersetzt wurde; nach
    /// einem Abbruch werden die übrigen nicht mehr angefasst.
    @concurrent
    public func apply(_ change: TimeMachineChange, to suggestions: [TimeMachineSuggestion]) async -> [StorageCleanOutcome] {
        var outcomes: [StorageCleanOutcome] = []
        for suggestion in suggestions {
            outcomes.append(Task.isCancelled
                ? Self.outcome(change, suggestion, .skipped(StorageRemover.cancelledReason))
                : await apply(change, to: suggestion))
        }
        return outcomes
    }

    private func apply(_ change: TimeMachineChange, to suggestion: TimeMachineSuggestion) async -> StorageCleanOutcome {
        func outcome(_ result: StorageCleanOutcome.Result) -> StorageCleanOutcome { Self.outcome(change, suggestion, result) }
        let path = suggestion.candidate.path
        if suggestion.state == change.resultingState {
            return outcome(.skipped(change == .exclude ? "Bereits ausgenommen" : "Bereits gesichert"))
        }
        guard let identity = suggestion.identity else { return outcome(.skipped("Kein Scan-Beleg")) }
        guard let current = FileIdentity.of(path) else { return outcome(.skipped("Nicht vorhanden")) }
        guard current == identity else { return outcome(.skipped("Geändert seit Scan")) }
        do {
            let result = try await runner.run(Self.tmutil, [change.verb, path], timeout: Self.timeout)
            guard result.succeeded else { return outcome(.failed("Exit \(result.exitCode): \(result.failureReason)")) }
        } catch CommandError.timedOut {
            return outcome(.failed("Zeitüberschreitung"))
        } catch {
            return outcome(.failed(error.readableDescription))
        }
        return outcome(await verify(change, at: path))
    }

    /// Exit 0 heißt nicht, dass der Zielstatus erreicht ist: `removeexclusion` hebt weder den Ausschluss eines
    /// übergeordneten Ordners noch einen festen Pfadausschluss (`addexclusion -p`) auf. Erfolg daher nur, wenn
    /// `isexcluded` für den Ordner und seine übergeordneten Ordner den Zielstatus bestätigt.
    private func verify(_ change: TimeMachineChange, at path: String) async -> StorageCleanOutcome.Result {
        let chain = Self.pathWithAncestors(path)
        let (states, failure) = await states(of: chain)
        if let failure { return .failed("Status nicht bestätigt: \(failure)") }
        let state = states[path] ?? .unknown
        if change == .include, let parent = chain.dropFirst().first(where: { states[$0] == .excluded }) {
            return .failed("Weiter ausgenommen: übergeordneter Ordner \(parent) ist ausgenommen")
        }
        switch (change, state) {
        case (_, .unknown): return .failed("Status nicht bestätigt")
        case (.exclude, .included): return .failed("Weiter gesichert: Time Machine hat den Ausschluss nicht übernommen")
        case (.include, .excluded):
            return .failed("Weiter ausgenommen: fester Pfadausschluss, nur mit „sudo tmutil removeexclusion -p“ aufhebbar")
        default: return .removed
        }
    }

    /// Der Pfad und seine übergeordneten Ordner bis unterhalb von `/`, nächster zuerst.
    static func pathWithAncestors(_ path: String) -> [String] {
        Array(sequence(first: path) { current in
            let parent = (current as NSString).deletingLastPathComponent
            return parent == current || parent == "/" || parent.isEmpty ? nil : parent
        })
    }

    private static func outcome(_ change: TimeMachineChange, _ suggestion: TimeMachineSuggestion,
                                _ result: StorageCleanOutcome.Result) -> StorageCleanOutcome {
        StorageCleanOutcome(categoryID: categoryID, target: suggestion.candidate.path, method: change.method,
                            freedBytes: nil, result: result)
    }

    /// Zeilen wie `[Excluded]  /Pfad`, `[Included]  /Pfad`, `[UNKNOWN]  /Pfad` je Pfad; anderes wird übergangen.
    static func parse(_ output: String) -> [String: TimeMachineBackupState] {
        var states: [String: TimeMachineBackupState] = [:]
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { continue }
            let path = line[line.index(after: end)...].drop { $0 == " " || $0 == "\t" }
            guard !path.isEmpty else { continue }
            states[String(path)] = switch line[line.index(after: line.startIndex)..<end] {
            case "Excluded": .excluded
            case "Included": .included
            default: .unknown
            }
        }
        return states
    }
}
