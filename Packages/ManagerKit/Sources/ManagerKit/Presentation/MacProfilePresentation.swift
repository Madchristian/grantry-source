import Foundation
import GrantryShared

/// Steckbrief und Sprungzeilen im Bereich „Sicherheit“ (TM-16.3, #408, Spec 2026-11-08 § 5.5) als fertige Texte: Name,
/// Modell und Messfelder aus `MacProfile`, dazu je eine Zeile Datenträger (TM-15.1), Akku (Energie) und Netz (Leistung).
/// Datenträger und Akku fehlen ohne Daten; das Netz zeigt ohne aktive Schnittstelle „Offline“.
public enum MacProfilePresentation {
    private static let missing = PerformancePresentation.missing

    /// Marketingname; ohne ihn die Modellkennung, ohne beides „Dieser Mac“.
    public static func name(of profile: MacProfile) -> String {
        profile.name ?? profile.modelIdentifier ?? "Dieser Mac"
    }

    /// Modellkennung im Peilkopf; leer, wenn sie schon als Name steht oder fehlt.
    public static func detail(of profile: MacProfile) -> String {
        profile.name == nil ? "" : profile.modelIdentifier ?? ""
    }

    /// Messfelder Chip, Speicher, macOS, Firmware und Laufzeit zum Zeitpunkt `now`; die Seriennummer zeigt die Ansicht.
    public static func fields(of profile: MacProfile, at now: Date) -> [PerformanceStat] {
        [PerformanceStat("Chip", profile.chipText), PerformanceStat("Speicher", profile.memoryText),
         PerformanceStat("macOS", profile.systemVersionText), PerformanceStat("Firmware", profile.firmwareText),
         PerformanceStat("Laufzeit", profile.uptimeText(at: now))]
    }

    /// Alle Sprungzeilen in fester Reihenfolge; fehlende Zeilen entfallen.
    public static func links(storage: VolumeInventory?, battery: BatteryReading?,
                             interfaces: [InterfaceCounters]?) -> [MacLink] {
        [storageLink(storage), batteryLink(battery), networkLink(interfaces)].compactMap(\.self)
    }

    /// Startcontainer (enthält das Volume an „/“, sonst der erste gemessene eines internen Datenträgers): frei von gesamt,
    /// dazu der SMART-Zustand des Datenträgers. `nil` ohne gemessenen Platz.
    public static func storageLink(_ inventory: VolumeInventory?) -> MacLink? {
        guard let inventory else { return nil }
        let measured = inventory.devices.flatMap { device in
            device.containers.compactMap { container in container.usage.map { (device, container, $0) } }
        }
        let startup = measured.first { $0.1.volumes.contains { $0.mountPoint == "/" } }
            ?? measured.first { $0.0.isInternal == true }
        guard let (device, _, usage) = startup else { return nil }
        let summary = "\(AppTexts.formattedSize(usage.availableBytes)) frei von \(AppTexts.formattedSize(usage.totalBytes))"
        return MacLink(kind: .storage, symbol: "internaldrive", title: "Datenträger", summary: summary,
                       status: MacLink.Status(text: "SMART \(device.smartStatus.title)", tone: device.smartStatus.tone))
    }

    /// Ladestand und Zustand wie im Tab „Energie“; `nil` ohne eingebauten Akku.
    public static func batteryLink(_ battery: BatteryReading?) -> MacLink? {
        guard let battery else { return nil }
        let status: MacLink.Status? = switch battery.condition {
        case .normal: MacLink.Status(text: "Zustand normal", tone: .positive)
        case .serviceRecommended: MacLink.Status(text: "Service empfohlen", tone: .warning)
        case nil: nil
        }
        return MacLink(kind: .battery, symbol: batterySymbol(battery), title: "Akku",
                       summary: "\(EnergyPresentation.chargeText(battery)) · \(EnergyPresentation.stateText(battery))",
                       status: status)
    }

    /// Schnittstelle der Default-Route mit Namen aus den Systemeinstellungen und der ersten routbaren Adresse (IPv4
    /// zuerst); ohne sie „Keine aktive Verbindung“. `nil`, wenn die Schnittstellen nicht gelesen werden konnten.
    public static func networkLink(_ interfaces: [InterfaceCounters]?) -> MacLink? {
        guard let interfaces else { return nil }
        guard let primary = interfaces.first(where: \.isPrimary) else {
            return MacLink(kind: .network, symbol: "network", title: "Netz", summary: "Keine aktive Verbindung",
                           status: MacLink.Status(text: "Offline", tone: .neutral))
        }
        let routable = primary.addresses.filter { !PerformancePresentation.isLinkLocal($0) }
        let address = routable.first { !$0.contains(":") } ?? routable.first
        let name = primary.displayName.flatMap(MacProfile.cleaned).map { "\($0) (\(primary.name))" } ?? primary.name
        return MacLink(kind: .network, symbol: "network", title: "Netz",
                       summary: [name, address].compactMap(\.self).joined(separator: " · "))
    }

    private static func batterySymbol(_ battery: BatteryReading) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        guard let charge = battery.charge else { return "battery.0percent" }
        return switch charge {
        case 0.875...: "battery.100percent"
        case 0.625..<0.875: "battery.75percent"
        case 0.375..<0.625: "battery.50percent"
        case 0.125..<0.375: "battery.25percent"
        default: "battery.0percent"
        }
    }
}

/// Eine Sprungzeile unter dem Steckbrief; `kind` bestimmt das Ziel in der App.
public struct MacLink: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case storage, battery, network
    }

    public struct Status: Hashable, Sendable {
        public let text: String
        public let tone: PresentationTone
    }

    public let kind: Kind
    public let symbol: String
    public let title: String
    public let summary: String
    public let status: Status?

    public var id: String { kind.rawValue }

    init(kind: Kind, symbol: String, title: String, summary: String, status: Status? = nil) {
        self.kind = kind
        self.symbol = symbol
        self.title = title
        self.summary = summary
        self.status = status
    }
}

/// Seriennummer im Steckbrief (Spec § 4.5, O6): verdeckt, bis der Knopf sie einblendet; Ausblenden verwirft den Klartext,
/// erneutes Einblenden liest neu. Beschreibung und Spiegelung zeigen nur `MacSerialNumber.hiddenText`.
public struct SerialNumberReveal: Sendable, CustomStringConvertible, CustomReflectable {
    private enum Phase: Sendable {
        case hidden, loading
        case revealed(MacSerialNumber?)
    }

    private var phase = Phase.hidden

    public init() {}

    /// Eingeblendet (auch „–“, wenn sie nicht lesbar war).
    public var isRevealed: Bool {
        if case .revealed = phase { true } else { false }
    }

    public var isLoading: Bool {
        if case .loading = phase { true } else { false }
    }

    /// Anzeige: verdeckt die Punkte, eingeblendet der Klartext bzw. „–“.
    public var text: String {
        guard case .revealed(let serial) = phase else { return MacSerialNumber.hiddenText }
        return serial?.reveal() ?? PerformancePresentation.missing
    }

    /// Klick auf den Knopf. `true`: Der Aufrufer liest die Nummer und meldet sie mit `finish(_:)`.
    public mutating func toggle() -> Bool {
        guard case .hidden = phase else {
            phase = .hidden
            return false
        }
        phase = .loading
        return true
    }

    /// Ergebnis des Lesens; nach dem Ausblenden ohne Wirkung.
    public mutating func finish(_ serial: MacSerialNumber?) {
        guard isLoading else { return }
        phase = .revealed(serial)
    }

    public var description: String { MacSerialNumber.hiddenText }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
