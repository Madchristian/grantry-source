import Foundation

/// Rechte-Schicht einer Erweiterung nach Nähe zum Kern, von innen nach außen (Spec § 4.1, § 5.2).
public enum ExtensionLayer: Int, Hashable, Sendable, Codable, CaseIterable, Comparable {
    /// Läuft im Kern (Kernel-Erweiterung).
    case kernel
    /// Systemerweiterung mit Sonderrechten (Netzwerk, Endpoint Security, Kamera).
    case systemExtension
    /// Treiber (DriverKit).
    case driver
    /// Plug-in, das ein Systemdienst lädt (Audio, Video).
    case servicePlugin

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Liste, aus der ein Eintrag stammt – je Liste ein eigener Leser (`ExtensionInventorySource`).
public enum ExtensionGroup: String, Hashable, Sendable, Codable, CaseIterable {
    case systemExtensions, kernelExtensions, servicePlugins
}

/// Art einer Erweiterung.
public enum ExtensionKind: Hashable, Sendable, Codable {
    case kernelExtension
    /// Treiber-Systemerweiterung (DriverKit).
    case driver
    case network
    case endpointSecurity
    case camera
    /// Systemerweiterung unbekannter Art mit der Kennung aus `systemextensionsctl`.
    case otherSystemExtension(String)
    /// Audio-Server-Plug-in (`coreaudiod`).
    case audioPlugin
    /// CoreMediaIO-DAL-Plug-in (veraltete Technik).
    case videoPlugin

    public var layer: ExtensionLayer {
        switch self {
        case .kernelExtension: .kernel
        case .network, .endpointSecurity, .camera, .otherSystemExtension: .systemExtension
        case .driver: .driver
        case .audioPlugin, .videoPlugin: .servicePlugin
        }
    }

    public var group: ExtensionGroup {
        switch self {
        case .kernelExtension: .kernelExtensions
        case .driver, .network, .endpointSecurity, .camera, .otherSystemExtension: .systemExtensions
        case .audioPlugin, .videoPlugin: .servicePlugins
        }
    }
}

/// Zustand einer Erweiterung, über alle Arten vereinheitlicht.
public enum ExtensionState: Hashable, Sendable, Codable {
    /// Systemerweiterung aktiviert und eingeschaltet.
    case enabled
    /// Systemerweiterung aktiviert, aber ausgeschaltet.
    case disabled
    /// Systemerweiterung wartet auf die Freigabe in den Systemeinstellungen.
    case waitingForUser
    /// Systemerweiterung ersetzt oder deinstalliert; der nächste Neustart entfernt sie.
    case removalPending
    /// Kernel-Erweiterung geladen.
    case loaded
    /// Kernel-Erweiterung installiert, aber nicht geladen.
    case notLoaded
    /// Plug-in vorhanden; sein Systemdienst lädt es bei Bedarf.
    case installed
    /// Unbekannter Zustand einer Systemerweiterung im Wortlaut.
    case unknown(String)
}

/// Eine Erweiterung im Inventar (TM-13.3): Kernel-Erweiterung, Systemerweiterung oder Plug-in in einem Systemdienst.
///
/// Identität: Systemerweiterungen über Team-ID und Bundle-ID (eine fremde Erweiterung mit gleicher Bundle-ID ist eine
/// andere), Kernel-Erweiterungen über die Bundle-ID (geladene und installierte Fassung sind ein Eintrag), Plug-ins über
/// ihren Pfad. Als Änderung zählen Version, Zustand und Signatur; Name, Pfad, ältere Versionen, „erstmals gesehen“ und
/// die zugehörige App sind Anzeige.
///
/// Texte stammen vom Hersteller und sind einzeilig und gekürzt (`ExtensionText`).
public struct ExtensionRecord: InventoryRecord, Codable {
    public let kind: ExtensionKind
    public let bundleID: String
    /// Team-ID laut `systemextensionsctl` bzw. Signatur; `nil`, wenn unbekannt.
    public let teamID: String?
    public var name: String?
    /// `CFBundleShortVersionString` der maßgeblichen Fassung.
    public var version: String?
    /// `CFBundleVersion`; `nil`, wenn unbekannt.
    public var buildVersion: String?
    public var state: ExtensionState
    /// Weitere Versionen derselben Systemerweiterung, neueste zuerst – meist alte, die auf den Neustart warten.
    public var otherVersions: [String]
    /// Signatur für Kernel-Erweiterungen und Plug-ins; `nil` für Systemerweiterungen, die macOS bei der Aktivierung
    /// prüft (ihr Team steht in `teamID`), und für Kernel-Erweiterungen ohne bekannten Pfad.
    public var signing: SigningInfo?
    /// `false`, wenn die Signaturprüfung nicht rechtzeitig endete: `signing` ist dann `.unknown`.
    public var isSigningConclusive: Bool
    /// Zugehörige App (`AppExtensionIndex`); `nil`, solange keine Zuordnung möglich war.
    public var owner: ExtensionOwnership?
    /// Bundle-Pfad; `nil` für Systemerweiterungen und Kernel-Erweiterungen ohne bekannten Pfad.
    public let path: String?
    /// Erster Scan, in dem Grantry den Eintrag gesehen hat (über Scans fortgeschrieben).
    public var firstSeenAt: Date

    public init(
        kind: ExtensionKind, bundleID: String, teamID: String?, name: String?, version: String?, buildVersion: String?,
        state: ExtensionState, otherVersions: [String] = [], signing: SigningInfo? = nil, isSigningConclusive: Bool = true,
        path: String? = nil, owner: ExtensionOwnership? = nil, firstSeenAt: Date
    ) {
        self.kind = kind
        self.bundleID = bundleID
        self.teamID = teamID
        self.name = name
        self.version = version
        self.buildVersion = buildVersion
        self.state = state
        self.otherVersions = otherVersions
        self.signing = signing
        self.isSigningConclusive = isSigningConclusive
        self.path = path
        self.owner = owner
        self.firstSeenAt = firstSeenAt
    }

    public var id: String {
        switch kind.group {
        case .systemExtensions: RecordIdentity.join(["systemExtension", teamID ?? "", bundleID])
        case .kernelExtensions: RecordIdentity.join(["kernelExtension", bundleID])
        case .servicePlugins: RecordIdentity.join(["servicePlugin", path ?? bundleID])
        }
    }

    public var source: SourceID { .extensions }

    public var layer: ExtensionLayer { kind.layer }

    public func hasSignificantChanges(comparedTo other: ExtensionRecord) -> Bool {
        version != other.version || buildVersion != other.buildVersion || state != other.state
            || signingDiffers(from: other) || teamDiffers(from: other)
    }

    /// Beide Signaturarten bekannt und verschieden; eine nicht prüfbare zählt nicht.
    func signingDiffers(from other: ExtensionRecord) -> Bool {
        guard let before = other.signing?.kind.known, let after = signing?.kind.known else { return false }
        return before != after
    }

    /// Beide Team-IDs bekannt und verschieden (Plug-ins und Kernel-Erweiterungen; bei Systemerweiterungen gehört das Team
    /// zur Identität).
    func teamDiffers(from other: ExtensionRecord) -> Bool {
        guard let before = other.teamID, let after = teamID else { return false }
        return before != after
    }
}

/// Beitrag der Erweiterungs-Quelle zu einem Snapshot (`InventoryContribution.extensions`).
public struct ExtensionContribution: Sendable, Equatable {
    public var records: [ExtensionRecord]
    /// Listen, die nicht oder nur teilweise gelesen wurden: Ihre fehlenden Einträge werden aus dem Vorgänger
    /// fortgeschrieben, statt als entfernt zu gelten (`Snapshot.addingExtensions`).
    public var incompleteGroups: Set<ExtensionGroup>
    /// Nicht auswertbare Bundles und Ordner: Fehlende Einträge an oder unter diesen Pfaden werden fortgeschrieben.
    public var incompletePaths: [String]

    public init(records: [ExtensionRecord] = [], incompleteGroups: Set<ExtensionGroup> = [], incompletePaths: [String] = []) {
        self.records = records
        self.incompleteGroups = incompleteGroups
        self.incompletePaths = incompletePaths
    }

    mutating func append(_ other: ExtensionContribution) {
        records += other.records
        incompleteGroups.formUnion(other.incompleteGroups)
        incompletePaths += other.incompletePaths
    }
}
