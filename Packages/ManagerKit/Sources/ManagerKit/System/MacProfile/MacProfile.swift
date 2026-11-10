import Foundation
import GrantryShared

/// Steckbrief dieses Macs (Dieser Mac, TM16) aus öffentlichen Quellen. Bewusst nicht `Codable` und ohne Seriennummer:
/// Die liefert nur `MacProfileSource.serialNumber()` auf Abruf. Fehlende Werte bleiben `nil` und erscheinen als „–“.
public struct MacProfile: Hashable, Sendable {
    /// macOS laut `SystemVersion.plist`.
    public struct OperatingSystem: Hashable, Sendable {
        /// „macOS“.
        public var name: String?
        /// „27.2“.
        public var version: String?
        /// „26B123“.
        public var build: String?
        /// Sicherheits-Nachlieferung („(a)“); `nil` ohne.
        public var securityResponse: String?

        public init(name: String?, version: String?, build: String?, securityResponse: String?) {
            self.name = name
            self.version = version
            self.build = build
            self.securityResponse = securityResponse
        }

        /// Aus dem Inhalt von `SystemVersion.plist`; `nil`, wenn er kein Dictionary ist.
        public init?(plist data: Data) {
            guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
            let text = { (key: String) in (values[key] as? String).flatMap(MacProfile.cleaned) }
            self.init(name: text("ProductName"), version: text("ProductVersion"), build: text("ProductBuildVersion"),
                      securityResponse: text("ProductVersionExtra"))
        }
    }

    /// Längste angezeigte Zeichenkette fremder Herkunft.
    public static let maximumTextLength = 128

    /// Marketingname („MacBook Pro (14-inch, Nov 2024)“).
    public var name: String?
    /// `hw.model` („Mac16,6“).
    public var modelIdentifier: String?
    public var chip: String?
    public var memoryBytes: UInt64?
    /// Version der System-Firmware ohne Ladernamen („20457.41.3“).
    public var firmware: String?
    public var system: OperatingSystem?
    /// Start des Macs (`kern.boottime`); die Laufzeit rechnet `uptimeText(at:)` zum Anzeigezeitpunkt.
    public var bootTime: Date?
    /// `kern.wakereason` beim Lesen des Steckbriefs.
    public var lastWakeReason: String?

    public init(name: String? = nil, modelIdentifier: String? = nil, chip: String? = nil, memoryBytes: UInt64? = nil,
                firmware: String? = nil, system: OperatingSystem? = nil, bootTime: Date? = nil,
                lastWakeReason: String? = nil) {
        self.name = name
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.memoryBytes = memoryBytes
        self.firmware = firmware
        self.system = system
        self.bootTime = bootTime
        self.lastWakeReason = lastWakeReason
    }

    /// Fremder Text als eine Zeile, höchstens `maximumTextLength` Zeichen; leer wird `nil`.
    static func cleaned(_ text: String) -> String? {
        let line = String(DisplayText.singleLine(text).prefix(maximumTextLength))
        return line.isEmpty ? nil : line
    }
}

// MARK: - Anzeige

extension MacProfile {
    private static let missing = PerformancePresentation.missing

    public var nameText: String { name ?? Self.missing }
    public var modelText: String { modelIdentifier ?? Self.missing }
    public var chipText: String { chip ?? Self.missing }
    public var memoryText: String { memoryBytes.map(ProcessCleanupPresentation.memoryText) ?? Self.missing }
    public var firmwareText: String { firmware ?? Self.missing }
    public var wakeReasonText: String { lastWakeReason ?? Self.missing }

    /// „macOS 27.2 (a) (26B123)“; ohne Version „–“.
    public var systemText: String {
        guard let system, system.version != nil else { return Self.missing }
        return "\(system.name ?? "macOS") \(systemVersionText)"
    }

    /// „27.2 (a) (26B123)“ ohne Produktnamen (Messfeld „macOS“); ohne Version „–“.
    public var systemVersionText: String {
        guard let system, let version = system.version else { return Self.missing }
        let parts = [version, system.securityResponse, system.build.map { "(\($0))" }]
        return parts.compactMap(\.self).joined(separator: " ")
    }

    /// Laufzeit seit dem Start zum Zeitpunkt `now` wie im Task-Manager (Tage:Stunden:Minuten:Sekunden).
    public func uptimeText(at now: Date) -> String {
        bootTime.map { PerformancePresentation.uptimeText(now.timeIntervalSince($0)) } ?? Self.missing
    }
}
