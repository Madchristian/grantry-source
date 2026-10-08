import Foundation
import Observation

/// Zustand der Ansicht „Aktivität“ im Bereich Netzwerk (Spec §3/§4): misst nur zwischen `start()` und `stop()` – die
/// Oberfläche koppelt beides an die Sichtbarkeit, `AppModel.stop()` wartet beim Beenden der App mit `stopAndWait()`.
///
/// nettop läuft in einem Kind-Task außerhalb des Main Actors (`NettopSampler`, `ActivityPipeline`); auf dem Main Actor
/// kommen nur fertige Anzeigestände (`ActivityFrame`) an. Signaturen prüft `ActivityProgramResolver` auf eigener Queue,
/// sie erscheinen mit einer späteren Messung. `stop()` kehrt sofort zurück (ein gleich folgendes `start()`
/// beginnt einen neuen Lauf), nettop endet im Hintergrund; `stopAndWait()` wartet auf das Ende aller Läufe – es bleibt
/// kein Prozess zurück. Gesamtbytes zählen je Sichtbarkeit neu („seit Öffnen“).
///
/// `rows` wird nur neu aufgebaut, wenn sich Messung, Hostnamen, Filter, Suche oder Sortierung ändern; fertige
/// Hostnamen-Abfragen werden gesammelt und gebündelt übernommen (mit der nächsten Messung, spätestens nach
/// `hostNameBatchDelay`). Nachgeschlagen werden nur Gegenstellen offener Verbindungen; ausgegraute behalten ihren
/// Namen. Die Sortierung gilt für Prozesse; Verbindungen innerhalb eines Prozesses bleiben nach
/// Gesamtrate sortiert.
@MainActor
@Observable
public final class NetworkActivityModel {
    public enum Status: Hashable, Sendable {
        case idle
        case running
        case failed(NetworkActivityFailure)

        public var failure: NetworkActivityFailure? {
            if case .failed(let failure) = self { failure } else { nil }
        }
    }

    public private(set) var status: Status = .idle
    public private(set) var frame: ActivityFrame = .empty
    /// Hostnamen der Gegenstellen, sobald bekannt (sonst zeigt die Tabelle die IP).
    public private(set) var hostNames: [String: String] = [:]
    /// Gefilterte, durchsuchte und sortierte Zeilen des aktuellen Stands.
    public private(set) var rows: [NetworkActivityRow] = []
    public var filter = NetworkActivityFilter() {
        didSet { if filter != oldValue { refreshRows() } }
    }
    public var query = "" {
        didSet { if query != oldValue { refreshRows() } }
    }
    /// Reihenfolge der Prozesszeilen; Verbindungen bleiben nach Gesamtrate sortiert.
    public var sortOrder: [KeyPathComparator<NetworkActivityRow>] = NetworkActivityPresenter.defaultSortOrder {
        didSet { if sortOrder != oldValue { refreshRows() } }
    }

    /// Längste Wartezeit, bis fertige Hostnamen ohne neue Messung übernommen werden.
    static let hostNameBatchDelay: Duration = .milliseconds(250)

    @ObservationIgnored private let sampler: NettopSampler
    @ObservationIgnored private let programs: ActivityProgramResolver
    @ObservationIgnored private let resolver: HostNameResolver
    @ObservationIgnored private let systemVersion: String
    @ObservationIgnored private var startsSampling = true
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Abgebrochene Läufe, deren nettop noch endet (`stopAndWait()`), nach Generation.
    @ObservationIgnored private var stoppingTasks: [Int: Task<Void, Never>] = [:]
    /// Zählt Starts; Ergebnisse eines älteren Laufs werden verworfen.
    @ObservationIgnored private var generation = 0
    /// Laufende Hostnamen-Abfragen; jede trägt sich bei ihrem Ende selbst aus.
    @ObservationIgnored private var lookupTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextLookupID = 0
    /// Fertige, noch nicht übernommene Hostnamen und der Task, der sie nach `hostNameBatchDelay` übernimmt.
    @ObservationIgnored private var resolvedHostNames: [String: String] = [:]
    @ObservationIgnored private var hostNameFlush: Task<Void, Never>?

    public init(
        sampler: NettopSampler = NettopSampler(),
        programs: ActivityProgramResolver = ActivityProgramResolver(),
        hostNameResolver: HostNameResolver = HostNameResolver(),
        systemVersion: String = NetworkActivityModel.currentSystemVersion
    ) {
        self.sampler = sampler
        self.programs = programs
        resolver = hostNameResolver
        self.systemVersion = systemVersion
    }

    /// Freigabe ohne `stop()`: Lauf und Abfragen abbrechen – der Abbruch beendet nettop (`LineStreaming`).
    isolated deinit {
        runTask?.cancel()
        cancelHostNameLookups()
        programs.cancelPendingInspections()
    }

    /// „27.0.1“ bzw. „27.0“.
    public nonisolated static var currentSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    public var notice: NetworkActivityNotice? {
        .make(failure: status.failure, skippedLineCount: frame.report.skippedLineCount, systemVersion: systemVersion)
    }

    /// Wer gerade misst; die Ansicht „Aktivität“ und das Detail eines Netzwerkdienstes teilen sich einen Lauf.
    public enum Consumer: Hashable, Sendable {
        case activityView, listenerDetail
    }

    /// Abnehmer, für die gerade gemessen wird (`start(for:)`).
    @ObservationIgnored private var consumers: Set<Consumer> = []

    /// Misst für `consumer`; läuft schon ein Lauf für einen anderen, bleiben Stand und Summen erhalten. Die Reihenfolge
    /// von Erscheinen und Verschwinden zweier Ansichten (Wechsel „Dienste | Aktivität“) spielt so keine Rolle.
    public func start(for consumer: Consumer) {
        consumers.insert(consumer)
        start()
    }

    /// Hört für `consumer` auf; gemessen wird weiter, solange ein anderer Abnehmer misst.
    public func stop(for consumer: Consumer) {
        consumers.remove(consumer)
        if consumers.isEmpty { stop() }
    }

    /// Aktivität des Programms unter `executablePath` im aktuellen Stand (Detail eines Netzwerkdienstes).
    public func listenerActivity(forProgramAt executablePath: String) -> ListenerActivity {
        ListenerActivityPresenter.activity(forProgramAt: executablePath, frame: frame, hostNames: hostNames)
    }

    /// Beginnt zu messen, falls nicht schon gemessen wird; ein früherer Stand und frühere Summen entfallen.
    public func start() {
        guard startsSampling, runTask == nil else { return }
        generation += 1
        let generation = generation
        status = .running
        show(.empty, hostNames: [:])
        let sampler = sampler
        let pipeline = ActivityPipeline(tracker: TrafficTracker(), programs: programs)
        runTask = Task { [weak self] in
            let (frames, continuation) = AsyncStream.makeStream(of: ActivityFrame.self,
                                                                bufferingPolicy: .bufferingNewest(1))
            async let failure = Self.sample(sampler, pipeline: pipeline, into: continuation)
            for await frame in frames {
                self?.apply(frame, generation: generation)
            }
            let outcome = await failure
            self?.finish(outcome, generation: generation)
            self?.stoppingTasks[generation] = nil
        }
    }

    /// Hört auf zu messen; nettop endet im Hintergrund, eingereihte Signaturprüfungen und laufende
    /// Hostnamen-Abfragen entfallen.
    public func stop() {
        cancelHostNameLookups()
        guard let task = runTask else { return }
        runTask = nil
        status = .idle
        stoppingTasks[generation] = task
        task.cancel()
        programs.cancelPendingInspections()
    }

    /// Hört auf zu messen und wartet, bis nettop aus diesem und allen früher abgebrochenen Läufen beendet ist und
    /// die abgebrochenen Hostnamen-Abfragen zurückgekehrt sind. Ruft während des Wartens jemand `start()` auf, wartet
    /// es auch auf das Ende dieses neuen Laufs nicht – der läuft weiter, bis ihn ein weiteres `stop()` beendet.
    public func stopAndWait() async {
        consumers.removeAll()
        stop()
        while let (generation, task) = stoppingTasks.first {
            await task.value
            stoppingTasks[generation] = nil
        }
        while let (id, task) = lookupTasks.first {
            await task.value
            lookupTasks[id] = nil
        }
    }

    /// „Erneut versuchen“ nach einem Fehlerzustand.
    public func retry() {
        guard status.failure != nil else { return }
        start()
    }

    private func apply(_ frame: ActivityFrame, generation: Int) {
        guard generation == self.generation, runTask != nil else { return }
        let addresses = frame.remoteAddresses
        var names = hostNames.merging(takeResolvedHostNames()) { _, new in new }.filter { addresses.contains($0.key) }
        for address in addresses where names[address] == nil {
            if let name = resolver.cachedName(for: address) {
                names[address] = name
            } else if frame.activeRemoteAddresses.contains(address), resolver.needsLookup(address) {
                let id = nextLookupID
                nextLookupID += 1
                lookupTasks[id] = Task { [weak self, resolver] in
                    let name = await resolver.resolve(address)
                    self?.finishLookup(id, name: name, for: address, generation: generation)
                }
            }
        }
        show(frame, hostNames: names)
    }

    /// Übernimmt Stand und Hostnamen und baut `rows` einmal neu auf; unveränderte Hostnamen lösen keine Änderung aus.
    private func show(_ frame: ActivityFrame, hostNames names: [String: String]) {
        self.frame = frame
        if names != hostNames { hostNames = names }
        refreshRows()
    }

    private func refreshRows() {
        rows = NetworkActivityPresenter.rows(frame: frame, hostNames: hostNames, filter: filter, query: query,
                                             sortOrder: sortOrder)
    }

    /// Merkt einen fertigen Namen vor; übernommen wird er mit der nächsten Messung, spätestens nach
    /// `hostNameBatchDelay`.
    private func finishLookup(_ id: Int, name: String?, for address: String, generation: Int) {
        lookupTasks[id] = nil
        guard let name, generation == self.generation, frame.remoteAddresses.contains(address) else { return }
        resolvedHostNames[address] = name
        guard hostNameFlush == nil else { return }
        hostNameFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.hostNameBatchDelay)
            guard !Task.isCancelled else { return }
            self?.flushResolvedHostNames()
        }
    }

    private func flushResolvedHostNames() {
        let names = takeResolvedHostNames().filter { frame.remoteAddresses.contains($0.key) }
        guard !names.isEmpty else { return }
        hostNames.merge(names) { _, new in new }
        refreshRows()
    }

    /// Vorgemerkte Namen; beendet die Wartezeit des gebündelten Übernehmens.
    private func takeResolvedHostNames() -> [String: String] {
        hostNameFlush?.cancel()
        hostNameFlush = nil
        defer { resolvedHostNames = [:] }
        return resolvedHostNames
    }

    /// Laufende Hostnamen-Abfragen (Tests).
    var hostNameLookupCount: Int { lookupTasks.count }

    /// Bricht laufende Abfragen ab (`HostNameResolver.resolve` kehrt dann sofort mit `nil` zurück) und verwirft
    /// vorgemerkte Namen.
    private func cancelHostNameLookups() {
        for task in lookupTasks.values {
            task.cancel()
        }
        _ = takeResolvedHostNames()
    }

    private func finish(_ failure: NetworkActivityFailure?, generation: Int) {
        guard generation == self.generation, runTask != nil else { return }
        runTask = nil
        if let failure {
            cancelHostNameLookups()
            status = .failed(failure)
            show(.empty, hostNames: [:])
        } else {
            status = .idle
        }
    }

    /// Läuft außerhalb des Main Actors, bis der Sampler endet; `nil` bei Abbruch.
    private nonisolated static func sample(
        _ sampler: NettopSampler, pipeline: ActivityPipeline, into continuation: AsyncStream<ActivityFrame>.Continuation
    ) async -> NetworkActivityFailure? {
        defer { continuation.finish() }
        do {
            try await sampler.run { sample in
                // Nach dem Abbruch keinen Resolver- oder Tracker-Zustand mehr ändern; die Messung entfällt.
                guard !Task.isCancelled else { return }
                continuation.yield(pipeline.frame(for: sample))
            }
            return nil
        } catch let error as NettopSamplerError {
            return NetworkActivityFailure(error)
        } catch is CancellationError {
            return nil
        } catch {
            return .unavailable(reason: error.readableDescription)
        }
    }
}

#if DEBUG
extension NetworkActivityModel {
    /// Fester Zustand für SwiftUI-Previews; startet nie nettop.
    public static func preview(frame: ActivityFrame, status: Status, hostNames: [String: String] = [:]) -> NetworkActivityModel {
        let model = NetworkActivityModel(systemVersion: "27.0.1")
        model.startsSampling = false
        model.status = status
        model.show(frame, hostNames: hostNames)
        return model
    }
}
#endif
