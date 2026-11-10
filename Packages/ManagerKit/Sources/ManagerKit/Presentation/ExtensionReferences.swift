import Foundation

// Querverweise der Erweiterungen (TM-13.6, Spec 2026-11-08 § 5.2, § 3.3): Erweiterungen tauchen dort auf, wo über Apps
// und Aufräumen entschieden wird – im App-Detail, beim Entfernen einer App, als Reste in „Aufräumen“ und im Zähler der
// Kachel „Auffällig“. Einmal je Zustand in `PresentationSnapshot.make` berechnet; Views lesen nur.

/// Eine Erweiterung als Verweis in einem anderen Bereich; der Sprung zeigt sie im Bereich „Erweiterungen“ (`id` ist die
/// `ExtensionRecord.id`, wie dort die Auswahl).
public struct ExtensionReference: Identifiable, Hashable, Sendable {
    public let record: ExtensionRecord

    public var id: String { record.id }
    /// Name, ersatzweise die Bundle-ID – einzeilig und gekürzt (`ExtensionTexts.label`).
    public var title: String { ExtensionTexts.label(of: record) }
    public var symbol: String { record.kind.symbol }
    /// „Netzwerkerweiterung · aktiv“.
    public var subtitle: String { "\(record.kind.displayName) · \(record.state.displayName)" }

    /// „Vendor Filter (Netzwerkerweiterung)“.
    var namedKind: String { "\(title) (\(record.kind.displayName))" }
}

/// Erweiterung, zu der keine installierte App mehr gehört („Aufräumen › App-Reste“): Hinweis, wie sie verschwindet, und
/// die Aktionen aus dem Bereich „Erweiterungen“ – Kernel- und Systemerweiterungen entfernt Grantry nicht selbst.
public struct ExtensionLeftover: Identifiable, Hashable, Sendable {
    public let reference: ExtensionReference
    public let note: String
    public let actions: [ExtensionAction]

    public var id: String { reference.id }

    init(_ record: ExtensionRecord) {
        reference = ExtensionReference(record: record)
        guard record.state != .removalPending else {
            note = String(localized: "Wird beim nächsten Neustart entfernt – sonst ist nichts zu tun.")
            actions = []
            return
        }
        note = switch record.kind.group {
        case .systemExtensions:
            String(localized: "Grantry entfernt Systemerweiterungen nicht selbst: Deinstallieren lässt sie das Programm des Herstellers, ausschalten die Systemeinstellungen.")
        case .kernelExtensions:
            String(localized: "Grantry entfernt Kernel-Erweiterungen nicht selbst: Deinstallieren lässt sie das Programm des Herstellers.")
        case .servicePlugins:
            String(localized: "Gehört zu keiner App mehr. „In den Papierkorb …“ legt es nach Bestätigung über den Finder weg; „Zurücklegen“ bleibt möglich.")
        }
        actions = ExtensionDetail.actions(for: record)
    }
}

/// Erweiterungen je App und ohne App, so wie der Bereich „Erweiterungen“ sie zeigt: ohne die ausgeblendeten Plug-ins von
/// Apple (`ExtensionRecord.isApplePlugin`).
public struct ExtensionReferences: Hashable, Sendable {
    /// Höchstzahl der Namen im Hinweis beim Entfernen; der Rest steht als „und 2 weitere“.
    static let maximumNamesInNote = 3

    /// IDs der gezeigten Erweiterungen – je Eintrag einmal in der Kachel „Auffällig“ (`FlaggedBreakdown`).
    public let recordIDs: [String]
    /// Ohne zugehörige App (`ExtensionOwnership.missing`), von innen nach außen, darin nach Name.
    public let leftovers: [ExtensionLeftover]
    /// Je Pfad der zugehörigen App (`ExtensionOwnership.app`), von innen nach außen, darin nach Name.
    private let byAppPath: [String: [ExtensionReference]]

    public static let empty = ExtensionReferences(records: [])

    public init(records: [ExtensionRecord]) {
        let shown = records.filter { !$0.isApplePlugin }.sorted(by: Self.displayOrder)
        recordIDs = shown.map(\.id)
        leftovers = shown.filter { $0.owner == .missing }.map(ExtensionLeftover.init)
        byAppPath = Dictionary(grouping: shown.compactMap { record -> (String, ExtensionReference)? in
            guard case .app(let path, _)? = record.owner else { return nil }
            return (path, ExtensionReference(record: record))
        }, by: \.0).mapValues { $0.map(\.1) }
    }

    private static func displayOrder(_ lhs: ExtensionRecord, _ rhs: ExtensionRecord) -> Bool {
        if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
        return ExtensionTexts.label(of: lhs).localizedStandardCompare(ExtensionTexts.label(of: rhs)) == .orderedAscending
    }

    /// Erweiterungen, die die App an `path` mitbringt oder deren Team nur sie hat (`InstalledApp.path`).
    public func owned(byAppAt path: String) -> [ExtensionReference] { byAppPath[path] ?? [] }

    /// Hinweis im Entfernen-Blatt: welche Systemerweiterungen die App mitbringt und dass sie erst ein Neustart endgültig
    /// entfernt; welche übrigen Erweiterungen installiert bleiben. `nil` ohne solche – bereits ausgebaute (warten auf den
    /// Neustart) zählen nicht. Der Ablauf des Entfernens bleibt unverändert.
    public func removalNote(forAppAt path: String) -> String? {
        let owned = owned(byAppAt: path).filter { $0.record.state != .removalPending }
        let system = owned.filter { $0.record.kind.group == .systemExtensions }
        let remaining = owned.filter { $0.record.kind.group != .systemExtensions }
        var sentences: [String] = []
        if !system.isEmpty {
            let count = system.count == 1 ? String(localized: "eine Systemerweiterung")
                : String(localized: "\(system.count) Systemerweiterungen")
            sentences.append(String(localized: "Die App bringt \(count) mit: \(Self.names(system)). macOS schaltet sie ab, sobald die App im Papierkorb liegt; endgültig entfernt sie erst ein Neustart."))
        }
        if !remaining.isEmpty {
            sentences.append(remaining.count == 1
                ? String(localized: "Nicht mit entfernt wird \(Self.names(remaining)); es bleibt installiert, „Aufräumen“ zeigt es danach als Rest.")
                : String(localized: "Nicht mit entfernt werden \(Self.names(remaining)); sie bleiben installiert, „Aufräumen“ zeigt sie danach als Reste."))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// „A (Art), B (Art) und 2 weitere“.
    private static func names(_ references: [ExtensionReference]) -> String {
        let shown = references.prefix(maximumNamesInNote).map(\.namedKind)
        let hidden = references.count - shown.count
        return hidden == 0 ? shown.enumerationText
            : (shown + [String(localized: "\(hidden) weitere")]).enumerationText
    }
}

extension ExtensionRecord {
    /// Plug-in von Apple: gehört zu macOS, der Bereich „Erweiterungen“ blendet es aus und zählt es nur.
    var isApplePlugin: Bool { kind.group == .servicePlugins && signing?.isAppleSigned == true }
}

extension ExtensionFilter {
    /// Filter, mit dem der Bereich nach einem Sprung mit Befund-Filter öffnet (Kachel „Auffällig“, Hinweis über anderen
    /// Listen): „Auffällig“ bei mittel und hoch; Hinweise allein haben keinen eigenen Filter, dann alle.
    public init(findings: FindingFilter) {
        self = findings == .flagged ? .findings : .all
    }
}
