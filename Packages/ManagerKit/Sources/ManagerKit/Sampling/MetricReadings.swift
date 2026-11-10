/// Rohzähler eines Prozesses (kumulativ seit Prozessstart). Name ohne Argumente wie `ProcessEntry.label`; die
/// Befehlszeile gelangt nie hierher. Zähler sind `nil`, wenn nicht lesbar – bei Prozessen anderer Benutzer liefert macOS
/// ohne Root keine (Spec §5).
public struct ProcessCounters: Hashable, Sendable {
    public let key: ProcessKey
    public let parentPID: Int32
    public let uid: UInt32
    public let name: String
    /// CPU-Zeit (Benutzer + System) in Nanosekunden.
    public let cpuTimeNanoseconds: UInt64?
    public let diskBytesRead: UInt64?
    public let diskBytesWritten: UInt64?
    /// Physischer Speicher (`ri_phys_footprint`).
    public let memoryBytes: UInt64?
    public let threadCount: Int?
    /// Programmpfad, nur bei eigenen Prozessen (App-Zuordnung, `ProcessGrouper`).
    public let executablePath: String?
    /// Verbrauchte Energie seit Prozessstart in Nanojoule (`ri_energy_nj`); nur eigene Prozesse auf Apple Silicon.
    public let energyNanojoules: UInt64?

    public init(key: ProcessKey, parentPID: Int32, uid: UInt32, name: String, cpuTimeNanoseconds: UInt64?,
                diskBytesRead: UInt64?, diskBytesWritten: UInt64?, memoryBytes: UInt64?, threadCount: Int?,
                executablePath: String? = nil, energyNanojoules: UInt64? = nil) {
        self.key = key
        self.parentPID = parentPID
        self.uid = uid
        self.name = name
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.memoryBytes = memoryBytes
        self.threadCount = threadCount
        self.executablePath = executablePath
        self.energyNanojoules = energyNanojoules
    }
}

/// Kerntyp auf Apple Silicon (`hw.perflevel*`); `unknown` bei Intel oder nicht lesbar.
public enum CoreKind: Hashable, Sendable {
    case performance, efficiency, unknown
}

/// Kumulative Ticks eines Kerns seit Systemstart (`host_processor_info`); `busy` = Benutzer + System + nice, `system`
/// davon der Systemanteil (Übersicht der Menüleiste, #495).
public struct CoreTicks: Hashable, Sendable {
    public let kind: CoreKind
    public let busy: UInt64
    public let idle: UInt64
    public let system: UInt64

    public init(kind: CoreKind, busy: UInt64, idle: UInt64, system: UInt64 = 0) {
        self.kind = kind
        self.busy = busy
        self.idle = idle
        self.system = system
    }
}

public struct CPULoadReading: Hashable, Sendable {
    public let cores: [CoreTicks]

    public init(cores: [CoreTicks]) { self.cores = cores }
}

/// Kumulative Zähler eines Laufwerks (`IOBlockStorageDriver` → `Statistics`). Vorgänge und Bearbeitungszeit sind `nil`,
/// wenn der Treiber sie nicht liefert.
public struct DriveCounters: Hashable, Sendable {
    /// Stabil über Messungen, z. B. BSD-Name „disk0“.
    public let id: String
    public let name: String
    public let bytesRead: UInt64
    public let bytesWritten: UInt64
    /// Lese- und Schreibvorgänge zusammen.
    public let operations: UInt64?
    /// Bearbeitungszeit aller Vorgänge in Nanosekunden („Total Time“ Lesen + Schreiben).
    public let busyNanoseconds: UInt64?

    public init(id: String, name: String, bytesRead: UInt64, bytesWritten: UInt64, operations: UInt64? = nil,
                busyNanoseconds: UInt64? = nil) {
        self.id = id
        self.name = name
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.operations = operations
        self.busyNanoseconds = busyNanoseconds
    }
}

/// Kumulative Bytes einer Netzwerkschnittstelle (`NET_RT_IFLIST2`, 64 Bit) mit Anzeigename und Adressen.
public struct InterfaceCounters: Hashable, Sendable {
    public let name: String
    public let bytesReceived: UInt64
    public let bytesSent: UInt64
    /// Name aus den Systemeinstellungen („WLAN“); `nil` etwa bei VPN-Tunneln.
    public let displayName: String?
    /// Numerische IPv4- und IPv6-Adressen.
    public let addresses: [String]
    /// Schnittstelle der Default-Route (`State:/Network/Global/IPv4` bzw. `IPv6` → `PrimaryInterface`).
    public let isPrimary: Bool

    public init(name: String, bytesReceived: UInt64, bytesSent: UInt64, displayName: String? = nil,
                addresses: [String] = [], isPrimary: Bool = false) {
        self.name = name
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.displayName = displayName
        self.addresses = addresses
        self.isPrimary = isPrimary
    }
}

/// Momentwerte der GPU (`IOAccelerator` → `PerformanceStatistics`); `nil`, wenn der Treiber sie nicht liefert.
public struct GPULoadReading: Hashable, Sendable {
    /// 0…1.
    public let utilization: Double?
    public let usedMemoryBytes: UInt64?

    public init(utilization: Double?, usedMemoryBytes: UInt64?) {
        self.utilization = utilization
        self.usedMemoryBytes = usedMemoryBytes
    }
}

/// Stromquelle laut `IOPSCopyPowerSourcesInfo`.
public enum PowerSourceState: Hashable, Sendable {
    case battery, externalPower
}

/// Zustand des Akkus wie in den Systemeinstellungen.
public enum BatteryCondition: Hashable, Sendable {
    case normal, serviceRecommended
}

/// Momentwerte des eingebauten Akkus (`IOPSCopyPowerSourcesInfo`, IORegistry `AppleSmartBattery`); ein Feld ist `nil`,
/// wenn macOS es nicht liefert. Leistungen in Milliwatt.
public struct BatteryReading: Hashable, Sendable {
    /// Ladestand 0…1.
    public let charge: Double?
    public let source: PowerSourceState
    public let isCharging: Bool
    public let isCharged: Bool
    /// Restlaufzeit bzw. Zeit bis voll in Minuten; `nil`, solange macOS rechnet oder es nicht zutrifft.
    public let minutesToEmpty: Int?
    public let minutesToFull: Int?
    public let cycleCount: Int?
    public let designCycleCount: Int?
    /// Volle Ladekapazität im Verhältnis zur Nennkapazität („Maximale Kapazität“), 0…1.
    public let maximumCapacity: Double?
    public let condition: BatteryCondition?
    /// Leistung am Akku: positiv beim Laden, negativ beim Entladen.
    public let batteryMilliwatts: Double?
    /// Leistungsaufnahme des ganzen Macs (`PowerTelemetryData` → `SystemLoad`).
    public let systemMilliwatts: Double?
    /// Angeschlossenes Netzteil; `nil` im Akkubetrieb oder wenn macOS keine Angaben liefert.
    public let adapter: PowerAdapterReading?

    public init(charge: Double?, source: PowerSourceState, isCharging: Bool = false, isCharged: Bool = false,
                minutesToEmpty: Int? = nil, minutesToFull: Int? = nil, cycleCount: Int? = nil,
                designCycleCount: Int? = nil, maximumCapacity: Double? = nil, condition: BatteryCondition? = nil,
                batteryMilliwatts: Double? = nil, systemMilliwatts: Double? = nil,
                adapter: PowerAdapterReading? = nil) {
        self.charge = charge
        self.source = source
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.maximumCapacity = maximumCapacity
        self.condition = condition
        self.batteryMilliwatts = batteryMilliwatts
        self.systemMilliwatts = systemMilliwatts
        self.adapter = adapter
    }
}

/// Netzteil am Mac (`IOPSCopyExternalPowerAdapterDetails`): Nennleistung und Beschreibung, wie macOS sie meldet.
public struct PowerAdapterReading: Hashable, Sendable {
    /// Nennleistung in Watt.
    public let watts: Int?
    /// Beschreibung des Netzteils (etwa „pd charger“), als eine kurze Zeile.
    public let name: String?

    public init(watts: Int?, name: String?) {
        self.watts = watts
        self.name = name
    }
}
