import Foundation

/// Kachel des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2). Die Rohwerte stehen in gespeicherten
/// Anordnungen und ändern sich nie; neue Kacheln kommen hinten dazu. Jede Kachel steht höchstens einmal auf der Tafel.
public enum OverviewTileKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case cpu, cores, processes, gpu, memory, disk, network, thermal, battery, loadAverage, uptime

    public var id: Self { self }

    public var title: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .cores: String(localized: "Kerne")
        case .processes: String(localized: "Prozesse")
        case .gpu: String(localized: "GPU")
        case .memory: String(localized: "Arbeitsspeicher")
        case .disk: String(localized: "Datenträger")
        case .network: String(localized: "Netz")
        case .thermal: String(localized: "Thermik")
        case .battery: String(localized: "Akku")
        case .loadAverage: String(localized: "Durchschnittslast")
        case .uptime: String(localized: "Laufzeit")
        }
    }

    /// SF Symbol im Katalog des Bearbeitungsmodus.
    public var symbolName: String {
        switch self {
        case .cpu: "cpu"
        case .cores: "square.grid.3x3"
        case .processes: "list.bullet.rectangle"
        case .gpu: "rectangle.3.group"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .thermal: "thermometer.medium"
        case .battery: "battery.75percent"
        case .loadAverage: "gauge.with.dots.needle.33percent"
        case .uptime: "clock"
        }
    }

    /// Erlaubte Größen, aufsteigend. Die Kacheln passen ihren Inhalt jeder davon an (Spec § 2, Tabelle).
    public var allowedSpans: [OverviewTileSpan] {
        switch self {
        case .cpu: OverviewTileSpan.all
        case .cores: [.wide, .large, .banner, .panel]
        case .processes: [.wide, .large, .banner, .panel]
        case .gpu, .memory, .disk, .network: [.small, .wide, .large, .banner]
        case .thermal, .battery, .loadAverage, .uptime: [.small, .wide]
        }
    }

    /// Größe beim Hineinziehen aus dem Katalog.
    public var defaultSpan: OverviewTileSpan {
        switch self {
        case .cpu, .gpu, .memory, .disk, .network: .wide
        case .cores: .banner
        case .processes: .large
        case .thermal, .battery, .loadAverage, .uptime: .small
        }
    }

    /// Was die Kachel zum Anzeigen braucht. Gemessen wird nur, was eine Kachel auf der Tafel verlangt (Spec § 7).
    public var requirements: OverviewTileRequirements {
        switch self {
        case .cpu: OverviewTileRequirements(sources: [.cpu], context: [.sensors])
        case .cores: OverviewTileRequirements(sources: [.cpu])
        case .processes: OverviewTileRequirements(sources: [.processes], context: [.runningApps])
        case .gpu: OverviewTileRequirements(sources: [.gpu], context: [.sensors])
        case .memory: OverviewTileRequirements(sources: [.memory])
        case .disk: OverviewTileRequirements(sources: [.disks], context: [.startupVolume])
        case .network: OverviewTileRequirements(sources: [.interfaces])
        case .thermal: OverviewTileRequirements()
        case .battery: OverviewTileRequirements(sources: [.battery])
        case .loadAverage: OverviewTileRequirements(context: [.loadAverage])
        case .uptime: OverviewTileRequirements(context: [.uptime])
        }
    }

    /// Ohne eingerichtete Quelle (Akku am Mac ohne Akku) fehlt die Kachel im Katalog und im Standard.
    public func isAvailable(configured: Set<TaskManagerSource>) -> Bool {
        requirements.sources.isSubset(of: configured)
    }
}

/// Bedarf einer Kachel: Quellen des Task-Managers und Werte außerhalb des Takts (`MenuBarOverviewContext`).
public struct OverviewTileRequirements: Hashable, Sendable {
    public var sources: Set<TaskManagerSource>
    public var context: Set<OverviewContextNeed>

    public init(sources: Set<TaskManagerSource> = [], context: Set<OverviewContextNeed> = []) {
        self.sources = sources
        self.context = context
    }

    public func union(_ other: Self) -> Self {
        Self(sources: sources.union(other.sources), context: context.union(other.context))
    }
}

/// Werte außerhalb des Messtakts; jeder kostet nur, wenn eine gezeigte Kachel ihn verlangt.
public enum OverviewContextNeed: String, Hashable, Sendable, CaseIterable {
    /// Takt und Temperaturen, nur wenn der Helper ohnehin misst (`SensorModel`).
    case sensors
    /// Belegung des Startvolumes, einmal beim Öffnen (`VolumeUsage`).
    case startupVolume
    /// Laufende Apps für Symbole und Gruppen wie im Prozess-Tab.
    case runningApps
    /// `getloadavg`, nur bei offenem Popover.
    case loadAverage
    /// Zeit seit dem Start des Macs.
    case uptime
}
