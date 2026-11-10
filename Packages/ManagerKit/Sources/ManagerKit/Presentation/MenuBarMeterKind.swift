/// Ein Element der Menüleiste (TM17, Spec 2026-11-09 § 2): je Messgröße ein eigenes Statusobjekt, dazu die Anzeige
/// „Übersicht“ (bis #495 „Auslastung“ aus TM6), deren Popover alle wichtigen Werte zeigt. Die Reihenfolge der Fälle ist
/// die der Einstellungen.
public enum MenuBarMeterKind: String, CaseIterable, Codable, CodingKeyRepresentable, Hashable, Sendable, Identifiable {
    case overview, cpu, gpu, memory, network, disk, thermal, battery

    public var id: Self { self }

    public var title: String {
        switch self {
        case .overview: "Übersicht"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Arbeitsspeicher"
        case .network: "Netz"
        case .disk: "Datenträger"
        case .thermal: "Thermik"
        case .battery: "Akku"
        }
    }

    /// Kurzbezeichnung im Element; Netz und Datenträger stehen mit Pfeilen bzw. L/S schon für sich.
    public var tag: String {
        switch self {
        case .overview: ""
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "RAM"
        case .network: "NETZ"
        case .disk: "SSD"
        case .thermal: "THERMIK"
        case .battery: "AKKU"
        }
    }

    public var styles: [MenuBarMeterStyle] {
        switch self {
        case .overview: [.graphAndBar]
        case .cpu, .gpu, .memory: [.number, .graph, .bar, .numberAndGraph, .numberAndBar]
        case .network, .disk: [.number, .graph, .numberAndGraph]
        case .thermal, .battery: [.number, .bar, .numberAndBar]
        }
    }

    public var defaultStyle: MenuBarMeterStyle {
        switch self {
        case .overview: .graphAndBar
        case .cpu, .gpu: .numberAndGraph
        case .memory, .thermal, .battery: .numberAndBar
        case .network, .disk: .number
        }
    }

    /// Quellen des Task-Managers, die das Element braucht; Thermik kommt aus `ThermalStateSource` ohne Quelle. Die
    /// Übersicht liest Datenträger und Netz für die Verläufe ihres Popovers; was es nur offen braucht, liest der Abnehmer
    /// `menuBarPopover`.
    public var sources: Set<TaskManagerSource> {
        switch self {
        case .overview: [.cpu, .memory, .disks, .interfaces]
        case .cpu: [.cpu]
        case .gpu: [.gpu]
        case .memory: [.memory]
        case .network: [.interfaces]
        case .disk: [.disks]
        case .thermal: []
        case .battery: [.battery]
        }
    }
}

/// Darstellung eines Elements: Zahl, Verlauf (Mini-Graph), Pegel (Balken) oder eine Kombination.
public enum MenuBarMeterStyle: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case number, graph, bar, numberAndGraph, numberAndBar
    /// Nur „Auslastung“: CPU-Verlauf und Speicherpegel wie in TM6.
    case graphAndBar

    public var id: Self { self }

    public var title: String {
        switch self {
        case .number: "Zahl"
        case .graph: "Verlauf"
        case .bar: "Pegel"
        case .numberAndGraph: "Zahl + Verlauf"
        case .numberAndBar: "Zahl + Pegel"
        case .graphAndBar: "Verlauf + Pegel"
        }
    }

    public var showsNumber: Bool { [.number, .numberAndGraph, .numberAndBar].contains(self) }
    public var showsGraph: Bool { [.graph, .numberAndGraph, .graphAndBar].contains(self) }
    public var showsBar: Bool { [.bar, .numberAndBar, .graphAndBar].contains(self) }
}
