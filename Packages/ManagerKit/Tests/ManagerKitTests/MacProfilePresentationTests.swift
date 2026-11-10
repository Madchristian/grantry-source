import Foundation
import Synchronization
import Testing
@testable import ManagerKit

/// Steckbrief-Panel und Sprungzeilen (TM-16.3, #408): Texte aus `MacProfile`, Datenträger, Akku und Netz, das Ein- und
/// Ausblenden der Seriennummer mit Testdaten und der Zwischenspeicher der Datenträger.
@Suite struct MacProfilePresentationTests {
    static let boot = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static let profile = MacProfile(
        name: "MacBook Pro (14-inch, Nov 2024)", modelIdentifier: "Mac16,6", chip: "Apple M4 Max",
        memoryBytes: 64 * 1_073_741_824, firmware: "13822.41.1",
        system: MacProfile.OperatingSystem(name: "macOS", version: "27.2", build: "26B123", securityResponse: "(a)"),
        bootTime: boot
    )

    // MARK: Steckbrief

    @Test func headShowsNameAndModel() {
        #expect(MacProfilePresentation.name(of: Self.profile) == "MacBook Pro (14-inch, Nov 2024)")
        #expect(MacProfilePresentation.detail(of: Self.profile) == "Mac16,6")
    }

    /// Ohne Marketingname steht die Modellkennung groß, ohne beides „Dieser Mac“; das Detail wiederholt sie nicht.
    @Test func headFallsBackToModelThenGenericName() {
        let model = MacProfile(modelIdentifier: "iMac20,1")
        #expect(MacProfilePresentation.name(of: model) == "iMac20,1")
        #expect(MacProfilePresentation.detail(of: model) == "")
        #expect(MacProfilePresentation.name(of: MacProfile()) == "Dieser Mac")
        #expect(MacProfilePresentation.detail(of: MacProfile()) == "")
    }

    @Test func fieldsInSpecOrder() {
        let fields = MacProfilePresentation.fields(of: Self.profile, at: Self.boot.addingTimeInterval(97_200 + 75))
        #expect(fields.map(\.title) == ["Chip", "Speicher", "macOS", "Firmware", "Laufzeit"])
        #expect(fields.map(\.value) == ["Apple M4 Max", ProcessCleanupPresentation.memoryText(64 * 1_073_741_824),
                                        "27.2 (a) (26B123)", "13822.41.1", "1:03:01:15"])
    }

    /// Fehlende Werte erscheinen als „–“ (Spec § 4.6).
    @Test func missingFieldsShowDash() {
        let fields = MacProfilePresentation.fields(of: MacProfile(), at: Self.boot)
        #expect(fields.count == 5)
        #expect(fields.allSatisfy { $0.value == PerformancePresentation.missing })
    }

    @Test func systemTextKeepsProductName() {
        #expect(Self.profile.systemText == "macOS 27.2 (a) (26B123)")
        #expect(Self.profile.systemVersionText == "27.2 (a) (26B123)")
    }

    // MARK: Seriennummer

    /// Einblenden mit Testdaten: verdeckt → liest → Klartext; Ausblenden verwirft ihn, erneutes Einblenden liest neu.
    @Test func revealAndHideSerialNumber() throws {
        var reveal = SerialNumberReveal()
        #expect(reveal.text == MacSerialNumber.hiddenText)
        #expect(!reveal.isRevealed)
        var reads = reveal.toggle()
        #expect(reads)
        #expect(reveal.isLoading)
        #expect(reveal.text == MacSerialNumber.hiddenText)
        reveal.finish(try #require(MacSerialNumber("C02TESTDATA1")))
        #expect(reveal.isRevealed)
        #expect(!reveal.isLoading)
        #expect(reveal.text == "C02TESTDATA1")
        reads = reveal.toggle()
        #expect(!reads)
        #expect(reveal.text == MacSerialNumber.hiddenText)
        #expect(!reveal.isRevealed)
        reads = reveal.toggle()
        #expect(reads)
    }

    @Test func unreadableSerialNumberShowsDash() {
        var reveal = SerialNumberReveal()
        _ = reveal.toggle()
        reveal.finish(nil)
        #expect(reveal.isRevealed)
        #expect(reveal.text == PerformancePresentation.missing)
    }

    /// Ein Ergebnis nach dem Ausblenden (Klick während des Lesens) bleibt verdeckt.
    @Test func lateResultAfterHidingStaysHidden() throws {
        var reveal = SerialNumberReveal()
        _ = reveal.toggle()
        let reads = reveal.toggle()
        #expect(!reads)
        reveal.finish(try #require(MacSerialNumber("C02TESTDATA1")))
        #expect(!reveal.isRevealed)
        #expect(reveal.text == MacSerialNumber.hiddenText)
    }

    /// Beschreibung und Spiegelung des Zustands verraten die Nummer nicht (Log, Verlauf).
    @Test func revealStateNeverPrintsSerialNumber() throws {
        var reveal = SerialNumberReveal()
        _ = reveal.toggle()
        reveal.finish(try #require(MacSerialNumber("C02TESTDATA1")))
        #expect(!String(describing: reveal).contains("C02TESTDATA1"))
        #expect(!String(reflecting: reveal).contains("C02TESTDATA1"))
        #expect(!"\(reveal)".contains("C02TESTDATA1"))
    }

    // MARK: Sprungzeilen

    static func inventory(smart: SMARTStatus = .verified, usage: VolumeUsage? = VolumeUsage(
        totalBytes: 1_000_000_000_000, availableBytes: 248_000_000_000)) -> VolumeInventory {
        let system = APFSVolume(id: "disk3s1", name: "Macintosh HD", role: .system, usedBytes: 12_000_000_000,
                                isEncrypted: true, isFileVaultEnabled: true, isLocked: false, mountPoint: "/")
        let external = StorageDevice(id: "disk4", name: "USB", isInternal: false, containers: [
            APFSContainer(id: "disk5", capacityBytes: 2, freeBytes: 1, physicalStores: ["disk4s2"], volumes: [],
                          usage: VolumeUsage(totalBytes: 2_000_000_000_000, availableBytes: 1_000_000_000_000)),
        ])
        let builtIn = StorageDevice(id: "disk0", name: "APPLE SSD", isInternal: true, smartStatus: smart, containers: [
            APFSContainer(id: "disk3", capacityBytes: 1, freeBytes: 1, physicalStores: ["disk0s2"], volumes: [system],
                          usage: usage),
        ])
        return VolumeInventory(devices: [builtIn, external], localSnapshots: nil, isComplete: true)
    }

    @Test func storageLinkShowsStartupContainerAndSmart() throws {
        let link = try #require(MacProfilePresentation.storageLink(Self.inventory()))
        #expect(link.kind == .storage)
        #expect(link.title == "Datenträger")
        #expect(link.summary == "\(AppTexts.formattedSize(248_000_000_000)) frei von "
            + AppTexts.formattedSize(1_000_000_000_000))
        #expect(link.status == MacLink.Status(text: "SMART verifiziert", tone: .positive))
        let failing = try #require(MacProfilePresentation.storageLink(Self.inventory(smart: .failing)))
        #expect(failing.status == MacLink.Status(text: "SMART Fehler", tone: .critical))
    }

    /// „aus TM-15.1, sonst ausgeblendet“: ohne Inventar oder ohne gemessenen Platz keine Zeile.
    @Test func storageLinkHiddenWithoutData() {
        #expect(MacProfilePresentation.storageLink(nil) == nil)
        #expect(MacProfilePresentation.storageLink(Self.inventory(usage: nil)) == nil)
        #expect(MacProfilePresentation.storageLink(VolumeInventory(devices: [], localSnapshots: nil,
                                                                   isComplete: false)) == nil)
    }

    @Test func batteryLinkShowsChargeStateAndCondition() throws {
        let battery = BatteryReading(charge: 0.82, source: .externalPower, condition: .normal)
        let link = try #require(MacProfilePresentation.batteryLink(battery))
        #expect(link.kind == .battery)
        #expect(link.summary == "82 % · Netzteil")
        #expect(link.status == MacLink.Status(text: "Zustand normal", tone: .positive))
        #expect(link.symbol == "battery.75percent")
        let service = try #require(MacProfilePresentation.batteryLink(
            BatteryReading(charge: 0.46, source: .externalPower, isCharging: true, condition: .serviceRecommended)))
        #expect(service.summary == "46 % · Lädt")
        #expect(service.status == MacLink.Status(text: "Service empfohlen", tone: .warning))
        #expect(service.symbol == "battery.100percent.bolt")
        #expect(MacProfilePresentation.batteryLink(BatteryReading(charge: nil, source: .battery))?.status == nil)
    }

    @Test func batteryLinkHiddenWithoutBattery() {
        #expect(MacProfilePresentation.batteryLink(nil) == nil)
    }

    @Test func networkLinkShowsPrimaryInterfaceWithRoutableAddress() throws {
        let interfaces = [
            InterfaceCounters(name: "en1", bytesReceived: 0, bytesSent: 0, displayName: "Thunderbolt-Bridge"),
            InterfaceCounters(name: "en0", bytesReceived: 0, bytesSent: 0, displayName: "WLAN",
                              addresses: ["fe80::1", "192.168.178.24", "2001:db8::5"], isPrimary: true),
        ]
        let link = try #require(MacProfilePresentation.networkLink(interfaces))
        #expect(link.kind == .network)
        #expect(link.summary == "WLAN (en0) · 192.168.178.24")
        #expect(link.status == nil)
        let tunnel = [InterfaceCounters(name: "utun4", bytesReceived: 0, bytesSent: 0, isPrimary: true)]
        #expect(MacProfilePresentation.networkLink(tunnel)?.summary == "utun4")
    }

    @Test func networkLinkWithoutPrimaryIsOffline() {
        let offline = MacProfilePresentation.networkLink([])
        #expect(offline?.summary == "Keine aktive Verbindung")
        #expect(offline?.status == MacLink.Status(text: "Offline", tone: .neutral))
        #expect(MacProfilePresentation.networkLink(nil) == nil)
    }

    /// Fremde Texte (Volume- und Schnittstellennamen) bleiben eine Zeile mit Längengrenze.
    @Test func networkNameIsSingleLine() throws {
        let interfaces = [InterfaceCounters(name: "en0", bytesReceived: 0, bytesSent: 0,
                                            displayName: "WLAN\nzweite Zeile" + String(repeating: "x", count: 300),
                                            isPrimary: true)]
        let summary = try #require(MacProfilePresentation.networkLink(interfaces)?.summary)
        #expect(!summary.contains("\n"))
        #expect(summary.count <= MacProfile.maximumTextLength + 10)
    }

    @Test func linksInFixedOrder() {
        let links = MacProfilePresentation.links(
            storage: Self.inventory(), battery: BatteryReading(charge: 1, source: .externalPower, isCharged: true),
            interfaces: [])
        #expect(links.map(\.kind) == [.storage, .battery, .network])
        #expect(links.map(\.id) == ["storage", "battery", "network"])
    }

    // MARK: Quelle

    /// Datenträger nur einmal je 10 Minuten (diskutil, tmutil); Akku und Netz bei jedem Öffnen frisch.
    @Test func sourceCachesInventoryForTenMinutes() async {
        let calls = Mutex((inventory: 0, battery: 0, interfaces: 0))
        let clock = Mutex(Self.boot)
        let source = MacLinkSource(
            inventory: {
                calls.withLock { $0.inventory += 1 }
                return Self.inventory()
            },
            battery: FakeSource { calls.withLock { $0.battery += 1 }; return BatteryReading(charge: 0.5, source: .battery) },
            interfaces: FakeSource { calls.withLock { $0.interfaces += 1 }; return [] },
            now: { clock.withLock { $0 } }
        )
        #expect(await source.links().map(\.kind) == [.storage, .battery, .network])
        _ = await source.links()
        #expect(calls.withLock { $0.inventory } == 1)
        #expect(calls.withLock { $0.battery } == 2)
        #expect(calls.withLock { $0.interfaces } == 2)
        clock.withLock { $0 = $0.addingTimeInterval(MacLinkSource.inventoryLifetime + 1) }
        _ = await source.links()
        #expect(calls.withLock { $0.inventory } == 2)
    }

    /// Ohne Akku (Fehler der Quelle) und ohne Netz-Lesung fehlen die Zeilen.
    @Test func sourceHidesFailingReadings() async {
        let source = MacLinkSource(
            inventory: { VolumeInventory(devices: [], localSnapshots: nil, isComplete: false) },
            battery: FakeSource<BatteryReading> { throw BatterySampler.NotAvailable() },
            interfaces: FakeSource<[InterfaceCounters]> { throw BatterySampler.NotAvailable() },
            now: { Self.boot }
        )
        #expect(await source.links().isEmpty)
    }
}

private struct FakeSource<Reading: Sendable>: MetricSource {
    let reading: @Sendable () throws -> Reading

    init(_ reading: @escaping @Sendable () throws -> Reading) {
        self.reading = reading
    }

    func read() throws -> Reading { try reading() }
}
