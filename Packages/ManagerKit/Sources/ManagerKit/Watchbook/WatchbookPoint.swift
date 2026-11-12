import Foundation
import GrantryShared

/// Wer verbraucht hat (Spec 2026-11-08 §4.5): eigene Programme und Systemprozesse mit Namen, Programme anderer Benutzer
/// nur als „Andere Konten“ – ihre Namen gelangen nie ins Wachbuch. Namen sind Programmnamen ohne Pfad und Argumente.
public enum WatchbookSubject: Hashable, Sendable {
    /// Ein Programm des eigenen Benutzers.
    case program(String)
    /// Ein Prozess eines Systemkontos (root, `_windowserver` …).
    case systemProcess(String)
    /// Programme anderer Benutzer, zusammengefasst und ohne Namen.
    case otherAccounts

    /// Konten unter 500 sind auf macOS Systemkonten; Benutzerkonten beginnen bei 501. Alles andere (auch `nobody`)
    /// zählt vorsichtshalber zu „Andere Konten“.
    static let firstUserAccount: UInt32 = 500
    static let maximumNameLength = 64

    /// Nach der Regel oben; `nil`, wenn ein eigener oder ein Systemprozess keinen lesbaren Namen hat.
    public init?(processNamed name: String, uid: UInt32, currentUID: UInt32) {
        guard uid == currentUID || uid < Self.firstUserAccount else {
            self = .otherAccounts
            return
        }
        // Einzeilig (keine Tabs und Umbrüche, die das Zeilenformat brechen), ohne Pfad, begrenzt. Sichtbares ASCII ohne
        // Leerraum ändert `DisplayText.singleLine` nicht; solche Namen (fast alle) sparen die Unicode-Prüfung.
        let isPlain = name.utf8.allSatisfy { (0x21...0x7E).contains($0) }
        // Programmnamen kommen fast immer schon ohne Pfad und kurz an (`ProcessUsageSampler.name`): dann ohne Kopie.
        if isPlain, !name.utf8.contains(UInt8(ascii: "/")), name.utf8.count <= Self.maximumNameLength {
            guard !name.isEmpty else { return nil }
            self = uid == currentUID ? .program(name) : .systemProcess(name)
            return
        }
        let line = isPlain ? name : DisplayText.singleLine(name)
        let lastComponent = line.split(separator: "/").last.map(String.init) ?? ""
        let cleaned = String((isPlain ? lastComponent : DisplayText.singleLine(lastComponent))
            .prefix(Self.maximumNameLength))
        guard !cleaned.isEmpty else { return nil }
        self = uid == currentUID ? .program(cleaned) : .systemProcess(cleaned)
    }

    /// Name für die Anzeige; „Andere Konten“ setzt die Oberfläche selbst.
    public var name: String? {
        switch self {
        case .program(let name), .systemProcess(let name): name
        case .otherAccounts: nil
        }
    }
}

/// Einer der größten Verbraucher eines Punkts: CPU als Anteil aller Kerne (0…1) bzw. Speicher in Byte.
public struct WatchbookConsumer: Hashable, Sendable {
    /// Je Punkt höchstens so viele CPU- und Speicherverbraucher.
    public static let count = 3

    public let subject: WatchbookSubject
    public let value: Double

    public init(subject: WatchbookSubject, value: Double) {
        self.subject = subject
        self.value = value
    }

    /// Die größten CPU- und Speicherverbraucher: Prozesse desselben Gegenstands (gleicher Programmname, alle anderen
    /// Benutzer) zählen zusammen; Prozesse ohne Wert oder mit 0 entfallen. In einem Durchgang, und jeder Name wird nur
    /// einmal je Konto bereinigt – nicht je Prozess und Liste (bei 1 500 Prozessen sonst gut 2 ms je Takt, TM-12.3).
    static func largest(_ processes: [ProcessMeasurement],
                        currentUID: UInt32) -> (cpu: [WatchbookConsumer], memory: [WatchbookConsumer]) {
        struct Group: Hashable {
            let name: String
            let uid: UInt32
        }
        var groups: [Group: (cpu: Double, memory: Double)] = [:]
        for process in processes {
            let cpu = process.cpuLoad ?? 0, memory = process.memoryBytes.map { Double($0) } ?? 0
            guard cpu > 0 || memory > 0 else { continue }
            // Ein Zugriff je Prozess statt zwei: Bei 1 000 Prozessen im gedrosselten Hintergrund zählt jede Suche (#530).
            add(cpu: max(cpu, 0), memory: max(memory, 0), to: &groups[Group(name: process.name, uid: process.uid),
                                                                       default: (0, 0)])
        }
        var cpu: [WatchbookSubject: Double] = [:], memory: [WatchbookSubject: Double] = [:]
        for (group, totals) in groups {
            guard let subject = WatchbookSubject(processNamed: group.name, uid: group.uid,
                                                 currentUID: currentUID) else { continue }
            if totals.cpu > 0 { cpu[subject, default: 0] += totals.cpu }
            if totals.memory > 0 { memory[subject, default: 0] += totals.memory }
        }
        return (ranked(cpu), ranked(memory))
    }

    private static func add(cpu: Double, memory: Double, to totals: inout (cpu: Double, memory: Double)) {
        totals.cpu += cpu
        totals.memory += memory
    }

    /// Die `count` größten, bei Gleichstand nach Namen („Andere Konten“ zuletzt) – stabil von Takt zu Takt.
    static func ranked(_ totals: [WatchbookSubject: Double]) -> [WatchbookConsumer] {
        totals.map(WatchbookConsumer.init).sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.sortKey < rhs.sortKey
        }.prefix(count).map { $0 }
    }

    private var sortKey: String {
        switch subject {
        case .program(let name): "0\(name)"
        case .systemProcess(let name): "1\(name)"
        case .otherAccounts: "2"
        }
    }
}

/// Ein Messpunkt des Wachbuchs (Spec 2026-11-08 §5.1), in der Regel alle 10 s. `time` ist das Ende des gemessenen
/// Abschnitts; Raten gelten für den Abschnitt davor.
public struct WatchbookPoint: Hashable, Sendable {
    /// Üblicher Abstand der Punkte; so weit reicht ein Punkt ohne Vorgänger zurück.
    public static let interval: TimeInterval = 10
    /// Größter Abstand, über den ein Punkt bis zu seinem Vorgänger reicht (Timer-Toleranz); ein größerer ist eine
    /// Lücke.
    static let maximumCoverage: TimeInterval = 15

    public let time: Date
    public var values: WatchbookValues
    public var cpuConsumers: [WatchbookConsumer]
    public var memoryConsumers: [WatchbookConsumer]

    public init(time: Date, values: WatchbookValues, cpuConsumers: [WatchbookConsumer],
                memoryConsumers: [WatchbookConsumer]) {
        self.time = time
        self.values = values
        self.cpuConsumers = cpuConsumers
        self.memoryConsumers = memoryConsumers
    }

    /// Aus einem Takt (Task-Manager oder Wachbuch-Takt). Nicht Gemessenes bleibt leer: Summen nur über gemessene Werte,
    /// ohne Laufwerke, Schnittstellen oder Kerne der Art gar keine. Netz wie die Kacheln des Leistung-Tabs ohne
    /// Loopback und ungenutzte Schnittstellen (`PerformancePresentation.visibleInterfaces`).
    /// - Parameters:
    ///   - thermalState: `ProcessInfo.thermalState`, `nil`, wenn nicht gelesen.
    ///   - power: Leistungsaufnahme gesamt und je Block, nur wenn die Sensoren des Helpers ohnehin laufen.
    public init(time: Date, snapshot: TaskManagerSnapshot, currentUID: UInt32,
                thermalState: ProcessInfo.ThermalState?, power: WatchbookPower?) {
        var values = WatchbookValues()
        values[.cpuTotal] = snapshot.cpu?.total
        Self.writeCoreAverages(snapshot.cpu?.cores ?? [], into: &values)
        if let memory = snapshot.memory {
            // Nicht `.map(Double.init)`: Das wählt `Double(bitPattern:)` (siehe `TaskManagerAccumulator`).
            values[.memoryUsed] = memory.usedBytes.map { Double($0) }
            values[.memoryCompressed] = memory.components.map { Double($0.compressedBytes) }
            values[.swapUsed] = memory.swapUsedBytes.map { Double($0) }
            values[.memoryPressure] = memory.pressure.map(Self.level)
        }
        values[.diskRead] = Self.sum(snapshot.drives.map(\.readPerSecond))
        values[.diskWrite] = Self.sum(snapshot.drives.map(\.writePerSecond))
        let interfaces = PerformancePresentation.visibleInterfaces(snapshot.interfaces)
        values[.networkReceived] = Self.sum(interfaces.map(\.receivedPerSecond))
        values[.networkSent] = Self.sum(interfaces.map(\.sentPerSecond))
        values[.gpu] = snapshot.gpu?.utilization
        values[.thermalState] = thermalState.flatMap(Self.level)
        values[.batteryCharge] = snapshot.battery?.charge
        values[.externalPower] = snapshot.battery.map { $0.source == .externalPower ? 1 : 0 }
        power?.write(into: &values)
        let consumers = WatchbookConsumer.largest(snapshot.processes, currentUID: currentUID)
        self.init(time: time, values: values, cpuConsumers: consumers.cpu, memoryConsumers: consumers.memory)
    }

    private static func sum(_ values: [Double?]) -> Double? {
        let measured = values.compactMap { $0 }
        return measured.isEmpty ? nil : measured.reduce(0, +)
    }

    /// Mittlere Last je Kernklasse mit eigener Messgröße (`WatchbookMetric(averageOf:)`), in einem Durchgang; Kerne
    /// ohne Messwert zählen nicht mit.
    private static func writeCoreAverages(_ cores: [CoreLoad], into values: inout WatchbookValues) {
        var totals: [WatchbookMetric: (sum: Double, count: Int)] = [:]
        for core in cores {
            guard let load = core.load, let metric = WatchbookMetric(averageOf: core.kind) else { continue }
            totals[metric, default: (0, 0)].sum += load
            totals[metric, default: (0, 0)].count += 1
        }
        for (metric, total) in totals { values[metric] = total.sum / Double(total.count) }
    }

    private static func level(_ pressure: MemoryStatus.Pressure) -> Double {
        switch pressure {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    /// `nil` für einen künftigen, hier unbekannten Zustand.
    private static func level(_ state: ProcessInfo.ThermalState) -> Double? {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: nil
        }
    }
}
