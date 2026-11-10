import Foundation
import GrantryShared

/// Ein Befund über den Zustand des Macs (Spec 2026-11-08 §4.3): gemeinsames Modell für Lagezeile, Wachbuch, Takt und
/// Thermik, Belegung und Erweiterungen. Befunde entstehen aus Regeln über Messreihen (`FindingRules`), nie aus einem
/// einzelnen Messwert.
public struct SystemFinding: Hashable, Sendable, Identifiable {
    /// Art des Befunds; der Rohwert ist der maschinenlesbare Typ im Wachbuch und ändert sich daher nicht.
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        /// CPU gesamt dauerhaft hoch.
        case systemLoad = "load.system"
        /// Ein Prozess belegt dauerhaft fast einen ganzen Kern.
        case processLoad = "load.process"
        /// macOS meldet erhöhten oder kritischen Speicherdruck.
        case memoryPressure = "memory.pressure"
        /// Der Auslagerungsspeicher wächst schnell.
        case swapGrowth = "memory.swap"
        /// Thermischer Zustand dauerhaft erhöht.
        case thermalState = "thermal.state"
        /// Der Mac senkt unter Last und thermischem Druck den Takt (braucht die Sensoren des Helpers).
        case throttling = "thermal.throttling"
        /// Datenträger dauerhaft stark belastet.
        case diskLoad = "disk.load"
        /// Anhaltend hoher Upload.
        case sustainedUpload = "network.upload"
        /// Der Akku entlädt sich schnell.
        case batteryDrain = "battery.drain"
        /// Ein Dienst ist neu aus dem Netz erreichbar (aus dem Verlauf, keine Messreihe).
        case exposedService = "network.exposed"
        /// Ein Volume ist fast voll (aus dem Volume-Inventar, keine Messreihe).
        case volumeFull = "storage.volume"
        /// Ein Datenträger meldet einen SMART-Fehler.
        case smartFailure = "storage.smart"
        /// Lokale Time-Machine-Snapshots bleiben ungewöhnlich lange liegen.
        case staleSnapshots = "storage.snapshots"
        /// Eine Erweiterung ist auffällig (`ExtensionRiskRules`, aus dem Inventar, keine Messreihe).
        case extensionRisk = "extension.risk"
    }

    /// `finding` (Bernstein) oder `critical`.
    public typealias Tone = WatchbookEvent.Tone

    /// Worauf sich der Befund bezieht; ohne Bezug gilt er für den ganzen Mac.
    public enum Subject: Hashable, Sendable {
        /// Ein Prozess – PID plus Startzeit, denn PIDs werden neu vergeben. Der Name folgt der Regel des Wachbuchs
        /// (`WatchbookSubject`: andere Benutzer ohne Namen); `nil`, wenn er nicht lesbar war.
        case process(ProcessKey, WatchbookSubject?)
        case app(bundleIdentifier: String, name: String)
        case systemExtension(identifier: String, name: String)
        /// Ein Volume oder ein ganzer Datenträger, mit seinem Namen.
        case volume(name: String)
        /// Ein Netzwerkdienst (`NetworkListener.id`, für Sprünge in die Liste); der Name folgt der Regel des Wachbuchs.
        case networkService(listenerID: String, name: WatchbookSubject?)
    }

    /// Belegwerte: die Schwelle der Regel und die Werte, mit denen sie überschritten wurde, in der Einheit der Regel.
    public struct Evidence: Hashable, Sendable {
        public let limit: Double
        public let peak: Double
        /// Mittel der Werte über der Schwelle.
        public let mean: Double

        public init(limit: Double, peak: Double, mean: Double) {
            self.limit = limit
            self.peak = peak
            self.mean = mean
        }
    }

    /// Längengrenze für fremde Namen (Volumes, Erweiterungen, Apps; Spec §4.5).
    static let maximumNameLength = 80

    public let kind: Kind
    public let tone: Tone
    /// Grund in einem Satz.
    public let reason: String
    /// Erster Messpunkt, an dem die Bedingung galt – nicht der Zeitpunkt, an dem die Mindestdauer erreicht war.
    public let start: Date
    /// Letzter Messpunkt, an dem die Bedingung galt; `nil`, solange der Befund läuft.
    public let end: Date?
    public let evidence: Evidence
    public let subject: Subject?

    public init(kind: Kind, tone: Tone, reason: String, start: Date, end: Date?, evidence: Evidence,
                subject: Subject?) {
        self.kind = kind
        self.tone = tone
        self.reason = DisplayText.singleLine(reason)
        self.start = start
        self.end = end
        self.evidence = evidence
        self.subject = subject.map(Self.sanitized)
    }

    /// Stabil über Art, Bezug und Beginn: Wird derselbe Befund später mit Ende erneut ermittelt, behält er seine ID und
    /// ersetzt im Wachbuch den laufenden Eintrag.
    public var id: UUID {
        UUID(stableHashOf: "\(kind.rawValue)|\(subjectKey)|\(start.timeIntervalSince1970)")
    }

    public var isOngoing: Bool { end == nil }

    /// Bezug als Schlüssel; Art und Bezug zusammen bezeichnen einen Befund über seine Dauer (Wachbuch, TM-12.3).
    var subjectKey: String {
        switch subject {
        case .process(let key, _): "process:\(key.id)"
        case .app(let bundleIdentifier, _): "app:\(bundleIdentifier)"
        case .systemExtension(let identifier, _): "extension:\(identifier)"
        case .volume(let name): "volume:\(name)"
        case .networkService(let listenerID, _): "service:\(listenerID)"
        case nil: ""
        }
    }

    private static func sanitized(_ subject: Subject) -> Subject {
        switch subject {
        case .process, .networkService: subject
        case .app(let bundleIdentifier, let name):
            .app(bundleIdentifier: limited(bundleIdentifier), name: limited(name))
        case .systemExtension(let identifier, let name):
            .systemExtension(identifier: limited(identifier), name: limited(name))
        case .volume(let name): .volume(name: limited(name))
        }
    }

    static func limited(_ text: String) -> String {
        String(DisplayText.singleLine(text).prefix(maximumNameLength))
    }
}

extension SystemFinding: WatchbookEventConvertible {
    /// Volumes und Erweiterungen sind keine Programme und bleiben im Wachbuch ohne Verursacher.
    public var watchbookEvent: WatchbookEvent {
        WatchbookEvent(id: id, kind: .finding, type: kind.rawValue, start: start, end: end, tone: tone,
                       subject: watchbookSubject, process: processKey, summary: reason)
    }

    /// Der Prozess, auf den sich der Befund bezieht; `WatchbookEvent` verwirft ihn für „Andere Konten“.
    private var processKey: ProcessKey? {
        if case .process(let key, _) = subject { key } else { nil }
    }

    private var watchbookSubject: WatchbookSubject? {
        switch subject {
        case .process(_, let subject), .networkService(_, let subject): subject
        case .app(_, let name): .program(name)
        case .systemExtension, .volume, nil: nil
        }
    }
}
