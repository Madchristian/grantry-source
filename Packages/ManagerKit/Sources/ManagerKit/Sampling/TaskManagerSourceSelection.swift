import Synchronization

extension TaskManagerSources {
    /// Nur die Quellen aus `selection`; die übrigen fehlen, als wären sie nicht eingerichtet.
    public func restricted(to selection: Set<TaskManagerSource>) -> TaskManagerSources {
        TaskManagerSources(
            processes: selection.contains(.processes) ? processes : nil,
            cpu: selection.contains(.cpu) ? cpu : nil,
            memory: selection.contains(.memory) ? memory : nil,
            disks: selection.contains(.disks) ? disks : nil,
            interfaces: selection.contains(.interfaces) ? interfaces : nil,
            gpu: selection.contains(.gpu) ? gpu : nil,
            battery: selection.contains(.battery) ? battery : nil
        )
    }
}

extension TaskManagerModel.Consumer {
    /// Quellen, die der Abnehmer ohne eigene Angabe braucht. Die Menüleiste nennt beim Start die Quellen ihrer
    /// eingeschalteten Elemente (TM17, `MenuBarMeterKind.sources`); ohne Angabe die der Anzeige „Auslastung“: nur CPU,
    /// Speicher, Datenträger und Netz (Spec §2), keine Prozesse – Budget unter 1 % CPU (Spec §4, #318). Das Fenster liest
    /// alle Quellen, auch den Akku (Energie-Tab, TM8), ebenso das offene Popover der Übersicht (#495) – nur solange es
    /// offen ist.
    public var sources: Set<TaskManagerSource> {
        switch self {
        case .window, .menuBarPopover: Set(TaskManagerSource.allCases)
        case .menuBar: [.cpu, .memory, .disks, .interfaces]
        }
    }
}

/// Quellen, die ein laufender Takt liest. Das Model passt sie an, wenn Abnehmer kommen oder gehen, ohne die Messung neu
/// zu starten: Öffnet man das Fenster, behält die Menüleiste ihren Verlauf.
final class TaskManagerSourceSelection: Sendable {
    private let selected: Mutex<Set<TaskManagerSource>>

    init(_ selected: Set<TaskManagerSource>) {
        self.selected = Mutex(selected)
    }

    var current: Set<TaskManagerSource> { selected.withLock { $0 } }

    func select(_ sources: Set<TaskManagerSource>) {
        selected.withLock { $0 = sources }
    }
}
