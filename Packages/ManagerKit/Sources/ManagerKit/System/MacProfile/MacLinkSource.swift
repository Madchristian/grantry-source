import Foundation

/// Daten der Sprungzeilen unter dem Steckbrief (TM-16.3, #408): Datenträger aus `VolumeInventorySource`, Akku und aktive
/// Netzschnittstelle als Momentwert. Nur auf Abruf beim Öffnen, kein Takt (Spec § 4.4). Das Inventar startet `diskutil`
/// und `tmutil` und gilt deshalb `inventoryLifetime` lang; Akku und Netz sind billig und werden jedes Mal gelesen – auf
/// einer eigenen Queue mit QoS `utility`.
public actor MacLinkSource {
    /// Für die App: ein Zwischenspeicher je Start.
    public static let shared = MacLinkSource()

    static let inventoryLifetime: TimeInterval = 600

    private let inventory: @Sendable () async -> VolumeInventory
    private let battery: any MetricSource<BatteryReading>
    private let interfaces: any MetricSource<[InterfaceCounters]>
    private let now: @Sendable () -> Date
    private let workQueue = BlockingWorkQueue(label: "mac-links")
    private var cache = ExpiringTaskCache<Int, VolumeInventory>(lifetime: { _ in MacLinkSource.inventoryLifetime })

    public init() {
        let volumes = VolumeInventorySource()
        self.init(inventory: { await volumes.inventory() }, battery: BatterySampler(),
                  interfaces: InterfaceThroughputSampler(), now: { .now })
    }

    init(inventory: @escaping @Sendable () async -> VolumeInventory, battery: any MetricSource<BatteryReading>,
         interfaces: any MetricSource<[InterfaceCounters]>, now: @escaping @Sendable () -> Date) {
        self.inventory = inventory
        self.battery = battery
        self.interfaces = interfaces
        self.now = now
    }

    public func links() async -> [MacLink] {
        let task = cache.task(for: 0, now: now(), compute: inventory)
        let readings = await workQueue.run { [battery, interfaces] in
            (try? battery.read(), try? interfaces.read())
        }
        let storage = await task.value
        cache.finish(0, task: task, value: storage, now: now())
        return MacProfilePresentation.links(storage: storage, battery: readings.0, interfaces: readings.1)
    }
}
