import Foundation
import Testing
@testable import ManagerKit

/// Datenträger-Befunde (TM-15.5, Spec §5.4): Volume über 90 % belegt, SMART-Fehler, lokale Snapshots älter als
/// 7 Tage – Zustände aus dem Volume-Inventar, keine Messreihe.
@Suite struct StorageRuleTests {
    private typealias F = FindingFixtures
    private static let gigabyte: Int64 = 1_000_000_000
    private static let day: TimeInterval = 86_400

    private static func volume(_ id: String, _ name: String, role: APFSVolumeRole?, mountPoint: String?) -> APFSVolume {
        APFSVolume(id: id, name: name, role: role, usedBytes: 0, isEncrypted: true, isFileVaultEnabled: false,
                   isLocked: false, mountPoint: mountPoint)
    }

    /// Startcontainer mit System- und Datenvolume; `available` ist frei für wichtige Nutzung laut Dateisystem.
    private static func startContainer(freeGB: Int64, importantGB: Int64? = nil, measured: Bool = true)
        -> APFSContainer {
        APFSContainer(id: "disk3", capacityBytes: 1_000 * gigabyte, freeBytes: freeGB * gigabyte,
                      physicalStores: ["disk0s2"],
                      volumes: [volume("disk3s1", "Macintosh HD", role: .system, mountPoint: "/"),
                                volume("disk3s5", "Macintosh HD - Daten", role: .data, mountPoint: "/System/Volumes/Data"),
                                volume("disk3s6", "VM", role: .vm, mountPoint: "/System/Volumes/VM")],
                      usage: measured ? VolumeUsage(totalBytes: 1_000 * gigabyte, availableBytes: freeGB * gigabyte,
                                                    importantUsageAvailableBytes: importantGB.map { $0 * gigabyte })
                          : nil)
    }

    private static func device(_ id: String = "disk0", name: String? = "APPLE SSD AP1024Z",
                               smart: SMARTStatus = .verified, containers: [APFSContainer]) -> StorageDevice {
        StorageDevice(id: id, name: name, busProtocol: "Apple Fabric", isInternal: true, isSolidState: true,
                      sizeBytes: 1_000 * gigabyte, smartStatus: smart, containers: containers)
    }

    private static func snapshots(oldestDaysAgo: Double?, count: Int = 3) -> LocalSnapshotSummary {
        LocalSnapshotSummary(count: count, oldest: oldestDaysAgo.map { F.start.addingTimeInterval(-$0 * day) },
                             newest: F.start.addingTimeInterval(-3_600))
    }

    private static func inventory(_ devices: [StorageDevice], snapshots: LocalSnapshotSummary? = nil,
                                  isComplete: Bool = true) -> VolumeInventory {
        VolumeInventory(devices: devices, localSnapshots: snapshots, isComplete: isComplete)
    }

    private func findings(_ inventory: VolumeInventory, at time: Date = F.start,
                          continuing previous: [SystemFinding] = []) -> [SystemFinding] {
        FindingRules.storageFindings(in: inventory, at: time, continuing: previous)
    }

    // MARK: Volume fast voll

    @Test func volumeAboveNinetyPercentIsAFinding() throws {
        let result = findings(Self.inventory([Self.device(containers: [Self.startContainer(freeGB: 60,
                                                                                           importantGB: 60)])]))
        let finding = try #require(result.first)
        #expect(result.count == 1)
        #expect(finding.kind == .volumeFull)
        #expect(finding.tone == .finding)
        #expect(finding.subject == .volume(name: "Macintosh HD"))
        #expect(finding.start == F.start)
        #expect(finding.isOngoing)
        #expect(finding.evidence == .init(limit: 0.9, peak: 0.94, mean: 0.94))
        #expect(finding.reason == "„Macintosh HD“ ist zu mehr als 90 % belegt.")
        #expect(finding.watchbookEvent.type == "storage.volume")
        #expect(finding.watchbookEvent.subject == nil)
    }

    /// Grenzwert: genau 90 % ist noch kein Befund.
    @Test func exactlyNinetyPercentIsNoFinding() {
        #expect(findings(Self.inventory([Self.device(containers: [Self.startContainer(freeGB: 100,
                                                                                       importantGB: 100)])])).isEmpty)
        #expect(findings(Self.inventory([Self.device(containers: [Self.startContainer(freeGB: 99,
                                                                                       importantGB: 99)])])).count == 1)
    }

    /// Was macOS bei Bedarf selbst freigibt (lokale Snapshots, Caches), zählt als frei.
    @Test func purgeableSpaceCountsAsFree() {
        let container = Self.startContainer(freeGB: 40, importantGB: 140)
        #expect(findings(Self.inventory([Self.device(containers: [container])])).isEmpty)
    }

    /// Ohne Dateisystem-Messung zählt der freie Platz laut `diskutil`.
    @Test func withoutFileSystemMeasurementDiskutilDecides() {
        let container = Self.startContainer(freeGB: 50, measured: false)
        #expect(findings(Self.inventory([Self.device(containers: [container])])).map(\.kind) == [.volumeFull])
    }

    /// Hilfscontainer (Wiederherstellung, iSCPreboot mit xART und Hardware) und nicht eingehängte Container sind kein
    /// Platz des Benutzers.
    @Test func auxiliaryAndUnmountedContainersAreIgnored() {
        let recovery = APFSContainer(id: "disk2", capacityBytes: 5 * Self.gigabyte, freeBytes: 0,
                                     physicalStores: ["disk0s3"],
                                     volumes: [Self.volume("disk2s1", "Recovery", role: .recovery, mountPoint: nil)])
        let isc = APFSContainer(id: "disk1", capacityBytes: Self.gigabyte / 2, freeBytes: 1,
                                physicalStores: ["disk0s1"],
                                volumes: [Self.volume("disk1s1", "iSCPreboot", role: .preboot,
                                                      mountPoint: "/System/Volumes/iSCPreboot"),
                                          Self.volume("disk1s2", "xART", role: .other("xART"),
                                                      mountPoint: "/System/Volumes/xarts")])
        let unmounted = APFSContainer(id: "disk5", capacityBytes: Self.gigabyte, freeBytes: 0,
                                      physicalStores: ["disk4s2"],
                                      volumes: [Self.volume("disk5s1", "Archiv", role: nil, mountPoint: nil)])
        let result = findings(Self.inventory([Self.device(containers: [recovery, isc, unmounted])]))
        #expect(result.isEmpty)
    }

    /// Externes Volume ohne Rolle: Bezug ist sein Name, eine Zeile mit Längengrenze (Spec §4.5).
    @Test func externalVolumeIsNamedSafely() throws {
        let name = "Backup\nzweite Zeile " + String(repeating: "x", count: 200)
        let external = APFSContainer(id: "disk5", capacityBytes: 100 * Self.gigabyte, freeBytes: Self.gigabyte,
                                     physicalStores: ["disk4s2"],
                                     volumes: [Self.volume("disk5s1", name, role: nil, mountPoint: "/Volumes/Backup")])
        let finding = try #require(findings(Self.inventory([Self.device("disk4", smart: .notSupported,
                                                                        containers: [external])])).first)
        guard case .volume(let subject) = finding.subject else {
            Issue.record("Bezug fehlt")
            return
        }
        #expect(!subject.contains("\n"))
        #expect(subject.count <= SystemFinding.maximumNameLength)
        #expect(!finding.reason.contains("\n"))
    }

    // MARK: SMART

    @Test func smartFailureIsCritical() throws {
        let result = findings(Self.inventory([Self.device(smart: .failing,
                                                          containers: [Self.startContainer(freeGB: 500)])]))
        let finding = try #require(result.first)
        #expect(result.count == 1)
        #expect(finding.kind == .smartFailure)
        #expect(finding.tone == .critical)
        #expect(finding.subject == .volume(name: "APPLE SSD AP1024Z"))
        #expect(finding.reason == "Der Datenträger „APPLE SSD AP1024Z“ meldet einen SMART-Fehler – Daten sichern.")
    }

    /// „Nicht unterstützt“ (externe Gehäuse) und „unbekannt“ sind kein Befund – aber auch keine Entwarnung.
    @Test func unsupportedOrUnknownSmartIsNoFinding() {
        for status in [SMARTStatus.verified, .notSupported, .unknown] {
            #expect(findings(Self.inventory([Self.device(smart: status, containers: [])])).isEmpty)
        }
    }

    /// Ohne Modellnamen heißt der Datenträger nach seiner Gerätekennung.
    @Test func unnamedDeviceUsesItsIdentifier() {
        let result = findings(Self.inventory([Self.device("disk4", name: nil, smart: .failing, containers: [])]))
        #expect(result.first?.subject == .volume(name: "disk4"))
    }

    // MARK: Lokale Snapshots

    @Test func snapshotsOlderThanSevenDaysAreAFinding() throws {
        let result = findings(Self.inventory([], snapshots: Self.snapshots(oldestDaysAgo: 9)))
        let finding = try #require(result.first)
        #expect(finding.kind == .staleSnapshots)
        #expect(finding.tone == .finding)
        #expect(finding.evidence.limit == 7 * Self.day)
        #expect(finding.evidence.peak == 9 * Self.day)
        #expect(finding.reason == "Ein lokaler Time-Machine-Snapshot ist älter als 7 Tage und belegt weiter Platz.")
    }

    /// Bezug ist das Startvolume, wenn es im Inventar steht.
    @Test func snapshotFindingNamesTheStartupVolume() {
        let result = findings(Self.inventory([Self.device(containers: [Self.startContainer(freeGB: 500)])],
                                             snapshots: Self.snapshots(oldestDaysAgo: 8)))
        #expect(result.map(\.subject) == [.volume(name: "Macintosh HD")])
    }

    /// Grenzwert: genau 7 Tage ist noch kein Befund; ohne lesbares Datum auch nicht.
    @Test func sevenDaysOrUnknownDatesAreNoFinding() {
        #expect(findings(Self.inventory([], snapshots: Self.snapshots(oldestDaysAgo: 7))).isEmpty)
        #expect(findings(Self.inventory([], snapshots: Self.snapshots(oldestDaysAgo: nil))).isEmpty)
        #expect(findings(Self.inventory([], snapshots: Self.snapshots(oldestDaysAgo: 2))).isEmpty)
        #expect(findings(Self.inventory([], snapshots: nil)).isEmpty)
    }

    // MARK: Fortsetzung über Prüfungen

    /// Ein Befund, der bei der nächsten Prüfung noch gilt, behält Beginn und ID – im Wachbuch ein Eintrag.
    @Test func continuingFindingKeepsItsStart() throws {
        let inventory = Self.inventory([Self.device(smart: .failing, containers: [Self.startContainer(freeGB: 50)])],
                                       snapshots: Self.snapshots(oldestDaysAgo: 9))
        let first = findings(inventory)
        let later = findings(inventory, at: F.time(900), continuing: first)
        #expect(later.count == 3)
        #expect(Set(later.map(\.id)) == Set(first.map(\.id)))
        #expect(later.allSatisfy { $0.start == F.start && $0.isOngoing })
    }

    /// Gilt die Bedingung nicht mehr, ist der Befund vorbei; ein späterer beginnt neu.
    @Test func resolvedFindingDisappears() {
        let full = findings(Self.inventory([Self.device(containers: [Self.startContainer(freeGB: 50)])]))
        let freed = findings(Self.inventory([Self.device(containers: [Self.startContainer(freeGB: 300)])]),
                             at: F.time(900), continuing: full)
        #expect(freed.isEmpty)
    }

    /// Unvollständiges Inventar heißt unbekannt, nicht unauffällig: Was nicht erneut bestätigt werden konnte, läuft
    /// weiter, bis eine vollständige Prüfung es widerlegt.
    @Test func incompleteInventoryKeepsPreviousFindings() {
        let complete = Self.inventory([Self.device(smart: .failing, containers: [Self.startContainer(freeGB: 50)])],
                                      snapshots: Self.snapshots(oldestDaysAgo: 9))
        let previous = findings(complete)
        let failed = Self.inventory([Self.device(smart: .unknown, containers: [])], snapshots: nil, isComplete: false)
        let result = findings(failed, at: F.time(900), continuing: previous)
        #expect(Set(result.map(\.id)) == Set(previous.map(\.id)))
        // Beendete Befunde setzen nichts fort.
        let ended = previous.map {
            SystemFinding(kind: $0.kind, tone: $0.tone, reason: $0.reason, start: $0.start, end: F.time(10),
                          evidence: $0.evidence, subject: $0.subject)
        }
        #expect(findings(failed, at: F.time(900), continuing: ended).isEmpty)
    }

    /// Andere Befunde (Takt, Verlauf) setzen keine Datenträger-Befunde fort und werden nicht übernommen.
    @Test func onlyStorageFindingsAreContinued() {
        let load = SystemFinding(kind: .systemLoad, tone: .finding, reason: "x", start: F.start, end: nil,
                                 evidence: .init(limit: 0.8, peak: 1, mean: 1), subject: nil)
        #expect(findings(Self.inventory([], isComplete: false), continuing: [load]).isEmpty)
    }

    /// Die Schwellen stehen an einer Stelle.
    @Test func thresholdsComeFromTheSettings() {
        var thresholds = FindingThresholds.standard
        thresholds.volumeFull.limit = 0.95
        thresholds.staleSnapshots.limit = 10 * Self.day
        let inventory = Self.inventory([Self.device(containers: [Self.startContainer(freeGB: 60)])],
                                       snapshots: Self.snapshots(oldestDaysAgo: 9))
        #expect(FindingRules.storageFindings(in: inventory, at: F.start, thresholds: thresholds).isEmpty)
        #expect(FindingRules.reason(for: .volumeFull, tone: .finding, subject: .volume(name: "A"),
                                    thresholds: thresholds) == "„A“ ist zu mehr als 95 % belegt.")
    }

    // MARK: Wachbuch

    /// Für das Wachbuch: neue Befunde beginnen, fortgesetzte bleiben stumm, widerlegte enden zum Zeitpunkt der Prüfung.
    @Test func changesForTheWatchbook() {
        let inventory = Self.inventory([Self.device(smart: .failing, containers: [Self.startContainer(freeGB: 50)])])
        let first = findings(inventory)
        #expect(FindingRules.storageChanges(from: [], to: first, at: F.start) == first)
        let later = findings(inventory, at: F.time(900), continuing: first)
        #expect(FindingRules.storageChanges(from: first, to: later, at: F.time(900)).isEmpty)
        let smartOnly = later.filter { $0.kind == .smartFailure }
        let ended = FindingRules.storageChanges(from: later, to: smartOnly, at: F.time(1_800))
        #expect(ended.map(\.kind) == [.volumeFull])
        #expect(ended.first?.end == F.time(1_800))
        #expect(ended.first?.id == later.first { $0.kind == .volumeFull }?.id)
    }

    @Test func storageKindsAreMarked() {
        #expect(SystemFinding.Kind.allCases.filter(\.isStorage) == [.volumeFull, .smartFailure, .staleSnapshots])
    }
}
