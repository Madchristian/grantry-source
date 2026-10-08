import Foundation

/// Art eines Rests; die Reihenfolge der Fälle ist die Anzeigereihenfolge.
public enum LeftoverKind: String, Hashable, Sendable, CaseIterable {
    case appBundle, container, groupContainer, applicationSupport, caches, preferences, savedState, httpStorage, webKit,
         logs, applicationScripts
}

/// `safe`: per Bundle-/Team-ID belegt, vorausgewählt. `uncertain`: nur über den Namen, nicht vorausgewählt.
public enum LeftoverConfidence: String, Hashable, Sendable {
    case safe, uncertain
}

/// Ein Pfad, der in den Papierkorb gelegt werden könnte.
public struct LeftoverCandidate: Identifiable, Hashable, Sendable {
    public let path: String
    public let kind: LeftoverKind
    public let confidence: LeftoverConfidence
    /// Belegter Speicher (gemessen erst nach der Prüfung durch den `RemovalGuard`).
    public var size: FileSize
    /// Warnhinweis, z. B. weitere installierte Apps desselben Herstellers.
    public let note: String?
    /// Das Objekt bei der Suche; vor dem Papierkorb prüft `RemovalGuard.check(_:allowingAppleIDOf:)`, dass es noch
    /// dasselbe ist. `nil` (unbekannt) wird dort immer gesperrt.
    public let identity: FileIdentity?

    /// Nur in der Suche: Mit `identity` belegt ein Kandidat, welches Objekt in den Papierkorb darf.
    init(
        path: String, kind: LeftoverKind, confidence: LeftoverConfidence, size: FileSize = .unknown, note: String? = nil,
        identity: FileIdentity? = nil
    ) {
        self.path = path
        self.kind = kind
        self.confidence = confidence
        self.size = size
        self.note = note
        self.identity = identity
    }

    public var id: String { path }
    public var isPreselected: Bool { confidence == .safe }

    /// Sichere vor unsicheren, dann nach Pfad.
    static func displayOrder(_ lhs: LeftoverCandidate, _ rhs: LeftoverCandidate) -> Bool {
        if lhs.confidence != rhs.confidence { return lhs.confidence == .safe }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }
}

/// Ergebnis der Reste-Suche: Kandidaten und Reste-Orte, die sich nicht lesen ließen (z. B. ohne Festplattenvollzugriff) –
/// dort ist „keine Reste“ nicht belegt.
public struct LeftoverScanResult: Hashable, Sendable {
    public private(set) var candidates: [LeftoverCandidate]
    public private(set) var unreadableLocations: [String]

    public init(candidates: [LeftoverCandidate], unreadableLocations: [String] = []) {
        self.candidates = candidates
        self.unreadableLocations = unreadableLocations
    }
}

/// Wie die Einträge eines Reste-Ortes heißen.
enum LeftoverNaming: Sendable, Equatable {
    case bundleID, preferences, savedState, groupContainer

    /// Kennung im Eintragsnamen; `nil`, wenn der Name nicht zur Art passt.
    func identifier(in name: String) -> String? {
        switch self {
        case .bundleID, .groupContainer: name
        case .preferences: Self.dropping(".plist", from: name)
        case .savedState: Self.dropping(".savedState", from: name)
        }
    }

    private static func dropping(_ suffix: String, from name: String) -> String? {
        name.count > suffix.count && name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : nil
    }
}

/// Ein Ort, an dem Reste liegen (Spec v3 §3).
struct LeftoverLocation: Sendable, Equatable {
    let kind: LeftoverKind
    let directory: String
    let naming: LeftoverNaming
    /// Hier werden auch Ordner nach App- oder Herstellername gesucht (unsicher, Abweichung 7).
    let allowsNameMatches: Bool
}
