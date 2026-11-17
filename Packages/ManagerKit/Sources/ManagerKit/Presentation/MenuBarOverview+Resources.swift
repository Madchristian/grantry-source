import Foundation

// Kacheln Arbeitsspeicher, Datenträger, Netz, Thermik, Akku, Durchschnittslast und Laufzeit der Übersicht (#495,
// Baukasten Spec 2026-11-09-uebersicht-baukasten § 9: Teil C).

extension MenuBarOverview {
    /// Bestandteil des belegten Speichers als Anteil am physischen Speicher.
    public struct MemoryPart: Equatable, Sendable, Identifiable {
        public let kind: MemoryComponents.Kind
        public let share: Double
        /// Größe des Teils wie in der Aktivitätsanzeige („21,3 GB“) für die Legende.
        public let amount: String

        public var id: MemoryComponents.Kind { kind }
        public var title: String { kind.title }

        /// Name in der Legende einer schmalen Kachel (2 × 1), in der die ausgeschriebenen Namen nicht nebeneinander passen.
        public var shortTitle: String {
            switch kind {
            case .app: "App"
            case .wired: "Zug."
            case .compressed: "Kompr."
            case .cached: "Cache"
            }
        }
    }

    public struct Memory: Equatable, Sendable {
        public let usedShare: Double?
        public let value: String
        public let detail: String
        public let parts: [MemoryPart]
        public let pressure: MemoryStatus.Pressure?
        public let pressureText: String
        public let swap: String

        /// Wert der Kachel für VoiceOver: belegter Anteil und Druck; ohne Messung „nicht gemessen“, nie 0.
        public var spokenValue: String {
            guard usedShare != nil else { return "nicht gemessen" }
            return pressure == nil ? value : "\(value), Druck \(pressureText)"
        }
    }

    public struct Disk: Equatable, Sendable {
        /// Erstes Laufwerk wie im Popover „Auslastung“; `nil` ohne gemessenes Laufwerk.
        public let driveID: String?
        public let usedShare: Double?
        /// Freier Platz des Startvolumes („412 GB“) und seine Größe („1 TB“); `nil` ohne Volume.
        public let freeAmount: String?
        public let capacity: String?
        public let read: String
        public let write: String

        /// Satz für Karte und Kopf breiter Kacheln: „412 GB frei von 1 TB“.
        public var free: String? {
            guard let freeAmount, let capacity else { return nil }
            return "\(freeAmount) frei von \(capacity)"
        }

        /// Wert der Kachel für VoiceOver: freier Platz, mit Laufwerk dazu Lesen und Schreiben.
        public var spokenValue: String {
            let rates = driveID.map { _ in "Lesen \(read), Schreiben \(write)" }
            return [free, rates].compactMap(\.self).joined(separator: ", ")
        }
    }

    public struct Network: Equatable, Sendable {
        public let interfaceName: String
        public let title: String
        public let received: String
        public let sent: String

        /// Titel für VoiceOver wie `PerformanceTile.spokenTitle`: Anzeigename samt BSD-Namen („USB LAN en8“), den die
        /// Kachel nicht zeigt; die Gegenprobe der Default-Route (`interface.popover`, plausibility.py) liest ihn.
        public var spokenTitle: String { title == interfaceName ? title : "\(title) \(interfaceName)" }
        public var spokenValue: String { "\(spokenTitle), empfangen \(received), gesendet \(sent)" }
    }

    public struct Thermal: Equatable, Sendable {
        public let state: ProcessInfo.ThermalState
        public let value: String
        public let tone: PresentationTone
        /// Füllstand je Stufe wie im Chip-Tab.
        public let level: Double?
        public let lowPowerMode: String
        /// Kurzform für 1 × 1: „Sparmodus aus“.
        public let lowPowerModeShort: String

        public var spokenValue: String { "\(value), \(lowPowerMode)" }

        /// Zustand ohne Zusatz für 1 × 1: „Hoch“ statt „Hoch – Leistung gedrosselt“.
        public var shortValue: String { state == .serious ? "Hoch" : value }

        /// Zeile unter der Spur in 2 × 1: was „Hoch“ in 1 × 1 weglässt, dazu der Energiesparmodus.
        public var detail: String { state == .serious ? "Leistung gedrosselt · \(lowPowerModeShort)" : lowPowerMode }
    }

    public struct Battery: Equatable, Sendable {
        public let charge: Double?
        public let value: String
        public let state: String
        public let isCharging: Bool

        public var spokenValue: String { "\(value), \(state)" }
    }

    /// Durchschnittslast über 1, 5 und 15 Minuten, je mit zwei Nachkommastellen.
    public struct LoadAverageFigures: Equatable, Sendable {
        public let one: String
        public let five: String
        public let fifteen: String

        public var spokenValue: String { "1 Minute \(one), 5 Minuten \(five), 15 Minuten \(fifteen)" }
    }

    /// Laufzeit auf Minuten genau: Zwischen zwei Takten derselben Minute bleibt der Wert gleich und die Kachel wertet
    /// nicht neu aus.
    public struct UptimeFigures: Equatable, Sendable {
        let days: Int
        let hours: Int
        let minutes: Int

        init(seconds: TimeInterval) {
            let total = max(0, Int(seconds.isFinite ? seconds : 0)) / 60
            days = total / 1_440
            hours = total / 60 % 24
            minutes = total % 60
        }

        /// Für 1 × 1: „3 T 4 h“, unter einem Tag „4 h 17 min“, unter einer Stunde „17 min“.
        public var short: String {
            if days > 0 { return "\(days) T \(hours) h" }
            return detailed
        }

        /// Für 2 × 1: „3 T 4 h 17 min“.
        public var detailed: String {
            if days > 0 { return "\(days) T \(hours) h \(minutes) min" }
            if hours > 0 { return "\(hours) h \(minutes) min" }
            return "\(minutes) min"
        }

        public var spokenValue: String {
            let units = [(days, "Tag", "Tage"), (hours, "Stunde", "Stunden"), (minutes, "Minute", "Minuten")]
            let first = days > 0 ? 0 : hours > 0 ? 1 : 2
            return units[first...].map { count, one, many in "\(count) \(count == 1 ? one : many)" }
                .joined(separator: ", ")
        }
    }

    /// Werte der Kacheln Durchschnittslast und Laufzeit des Baukastens.
    public struct Summary: Equatable, Sendable {
        public let loadFigures: LoadAverageFigures?
        public let uptimeFigures: UptimeFigures?
    }
}

extension MenuBarOverviewPresentation {
    // MARK: - Arbeitsspeicher

    static func memory(_ memory: MemoryStatus) -> MenuBarOverview.Memory {
        let used = PerformancePresentation.usedShare(of: memory)
        let physical = Double(memory.physicalBytes)
        let parts: [MenuBarOverview.MemoryPart] = memory.components.map { components in
            [MemoryComponents.Kind.app, .wired, .compressed].map { kind in
                let bytes = components[kind]
                return MenuBarOverview.MemoryPart(kind: kind, share: physical > 0 ? Double(bytes) / physical : 0,
                                                  amount: self.bytes(bytes))
            }
        } ?? []
        return MenuBarOverview.Memory(
            usedShare: used, value: percent(used), detail: PerformancePresentation.memoryUsage(memory), parts: parts,
            pressure: memory.pressure,
            pressureText: memory.pressure.map(ProcessCleanupPresentation.pressureText) ?? missing,
            swap: PerformancePresentation.swapText(memory)
        )
    }

    /// Größe mit drei Stellen für schmale Kacheln: „413 GB“, „2,46 GB“ (nicht adaptiv, anders als `AppTexts`).
    static func tileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Datenträger und Netz

    static func disk(_ drive: DriveThroughput?, volume: VolumeUsage?) -> MenuBarOverview.Disk? {
        guard drive != nil || volume != nil else { return nil }
        let usedShare = volume.map { Double($0.usedBytes) / Double($0.totalBytes) }
        return MenuBarOverview.Disk(
            driveID: drive?.id, usedShare: usedShare, freeAmount: volume.map { tileSize($0.availableBytes) },
            capacity: volume.map { tileSize($0.totalBytes) },
            read: rate(drive?.readPerSecond), write: rate(drive?.writePerSecond)
        )
    }

    static func network(_ interface: InterfaceThroughput) -> MenuBarOverview.Network {
        MenuBarOverview.Network(interfaceName: interface.name, title: interface.displayName ?? interface.name,
                                received: rate(interface.receivedPerSecond), sent: rate(interface.sentPerSecond))
    }

    // MARK: - Thermik, Akku, Zusammenfassung

    static func thermal(_ condition: ThermalCondition) -> MenuBarOverview.Thermal {
        let detail = TaskManagerMenuBarPresentation.thermalDetail(condition)
        return MenuBarOverview.Thermal(
            state: condition.state, value: PerformancePresentation.thermalText(condition.state),
            tone: detail.items.first?.tone ?? .neutral, level: ChipPresentation.thermalLevel(condition.state),
            lowPowerMode: condition.isLowPowerModeEnabled ? "Energiesparmodus an" : "Energiesparmodus aus",
            lowPowerModeShort: condition.isLowPowerModeEnabled ? "Sparmodus an" : "Sparmodus aus"
        )
    }

    static func battery(_ battery: BatteryReading) -> MenuBarOverview.Battery {
        MenuBarOverview.Battery(charge: battery.charge, value: EnergyPresentation.chargeText(battery),
                                state: EnergyPresentation.stateText(battery), isCharging: battery.isCharging)
    }

    static func summary(_ context: MenuBarOverviewContext) -> MenuBarOverview.Summary? {
        guard context.loadAverage != nil || context.uptime != nil else { return nil }
        let number = { (value: Double) in
            value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "de_DE")))
        }
        let load = context.loadAverage.map {
            MenuBarOverview.LoadAverageFigures(one: number($0.one), five: number($0.five), fifteen: number($0.fifteen))
        }
        return MenuBarOverview.Summary(loadFigures: load,
                                       uptimeFigures: context.uptime.map(MenuBarOverview.UptimeFigures.init(seconds:)))
    }
}
