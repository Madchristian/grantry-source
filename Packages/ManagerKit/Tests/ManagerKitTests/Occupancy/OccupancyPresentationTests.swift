import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Ansicht „Belegung“ (TM-15.4, #403): Zustandszeile, Belegungsband, Datenträger, Ordnerleiter und Detail aus Baum,
/// Volumes und Hinweisen – vor dem Scan, während, fertig und mit nicht erfassten Orten.
@Suite struct OccupancyPresentationTests {
    static let gigabyte: Int64 = 1_000_000_000
    static let home = "/fake/home"
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 21))!

    static func size(_ bytes: Int64) -> String { AppTexts.formattedSize(bytes) }

    /// Startvolume mit 1 000 GB, 250 GB frei, 30 GB bereinigbar; System-Volumes 20 GB.
    static func inventory(complete: Bool = true, external: Bool = false) -> VolumeInventory {
        let system = APFSVolume(id: "disk3s1", name: "Macintosh HD", role: .system, usedBytes: 12 * gigabyte,
                                isEncrypted: true, isFileVaultEnabled: true, isLocked: false, mountPoint: "/")
        let data = APFSVolume(id: "disk3s5", name: "Data", role: .data, usedBytes: 700 * gigabyte, isEncrypted: true,
                              isFileVaultEnabled: true, isLocked: false, mountPoint: "/System/Volumes/Data")
        let vm = APFSVolume(id: "disk3s6", name: "VM", role: .vm, usedBytes: 8 * gigabyte, isEncrypted: false,
                            isFileVaultEnabled: false, isLocked: false, mountPoint: "/System/Volumes/VM")
        let container = APFSContainer(id: "disk3", capacityBytes: 1_000 * gigabyte, freeBytes: 250 * gigabyte,
                                      physicalStores: ["disk0s2"], volumes: [system, data, vm],
                                      usage: VolumeUsage(totalBytes: 1_000 * gigabyte, availableBytes: 250 * gigabyte,
                                                         importantUsageAvailableBytes: 280 * gigabyte))
        let builtIn = StorageDevice(id: "disk0", name: "APPLE SSD", busProtocol: "Apple Fabric", isInternal: true,
                                    isSolidState: true, sizeBytes: 1_000 * gigabyte, smartStatus: .verified,
                                    containers: [container])
        var devices = [builtIn]
        if external {
            let archive = APFSVolume(id: "disk5s1", name: "Archiv", role: nil, usedBytes: 900 * gigabyte, isEncrypted: false,
                                     isFileVaultEnabled: false, isLocked: false, mountPoint: "/Volumes/Archiv")
            devices.append(StorageDevice(
                id: "disk4", name: "T7", busProtocol: "USB", isInternal: false, isSolidState: true,
                sizeBytes: 2_000 * gigabyte, smartStatus: .notSupported,
                containers: [APFSContainer(id: "disk5", capacityBytes: 2_000 * gigabyte, freeBytes: 1_100 * gigabyte,
                                           physicalStores: ["disk4s2"], volumes: [archive],
                                           usage: VolumeUsage(totalBytes: 2_000 * gigabyte,
                                                              availableBytes: 1_100 * gigabyte))]))
        }
        let snapshots = LocalSnapshotSummary(snapshotDates: ["2026-11-06-120000", "2026-11-08-090000"],
                                             timeZone: TimeZone(identifier: "UTC")!)
        return VolumeInventory(devices: devices, localSnapshots: snapshots, isComplete: complete)
    }

    /// Caches räumt auf und lässt `keep` aus, `Homebrew` darin ist eine eigene Kategorie.
    static func hints() -> OccupancyHints {
        func category(_ id: String, _ title: String, risk: StorageRisk = .low, roots: [String]) -> StorageCategory {
            StorageCategory(id: id, title: title, summary: "Zusammenfassung.", risk: risk, roots: roots)
        }
        let caches = PathCategoryProvider(category: category("caches", "Caches", roots: [home + "/Library/Caches"]),
                                          excludedNames: ["keep", "Homebrew"], measurer: FixedSizeMeasurer())
        let homebrew = PathCategoryProvider(category: category("homebrew", "Homebrew aufräumen", risk: .medium,
                                                               roots: [home + "/Library/Caches/Homebrew"]),
                                            measurer: FixedSizeMeasurer())
        return OccupancyHints(providers: [caches, homebrew], timeMachineCandidates: [
            TimeMachineCandidate(title: "Caches", path: home + "/Library/Caches", risk: .low, categoryID: "caches"),
        ])
    }

    static func fileSystem() -> FakeOccupancyFileSystem {
        let fileSystem = FakeOccupancyFileSystem(rootPath: home)
        fileSystem.addFile("Library/Caches/app/a", bytes: 10 * gigabyte)
        fileSystem.addFile("Library/Caches/keep/b", bytes: 2 * gigabyte)
        fileSystem.addFile("Library/Caches/Homebrew/c", bytes: 3 * gigabyte)
        fileSystem.addFile("Library/Prefs/p", bytes: 1 * gigabyte)
        fileSystem.addFile("Movies/m", bytes: 100 * gigabyte)
        fileSystem.addFile("loose", bytes: 1 * gigabyte)
        fileSystem.addFolder("Documents")
        fileSystem.addFile("Documents/d", bytes: 5 * gigabyte)
        return fileSystem
    }

    static func scanned(_ fileSystem: FakeOccupancyFileSystem = fileSystem(), excluded: Set<String> = [],
                        trail: [String] = []) async throws -> OccupancyState {
        let tree = try await OccupancyScanner.testing(fileSystem, excluded: excluded).scan(fileSystem.rootPath)
        let hints = hints()
        var state = OccupancyState(home: home)
        state.phase = .done
        state.inventory = inventory()
        state.tree = tree
        state.hints = hints
        state.cleanable = hints.cleanable(in: tree)
        state.scannedAt = now.addingTimeInterval(-60)
        state.scanDuration = .seconds(58)
        var path = fileSystem.rootPath
        for name in trail {
            path += "/" + name
            state.trail.append(try #require(tree.folder(atPath: path)).id)
        }
        return state
    }

    static func present(_ state: OccupancyState, findings: [SystemFinding] = []) -> OccupancyPresentation {
        OccupancyPresentation(state, findings: findings, now: now, calendar: calendar)
    }

    static func rows(_ presentation: OccupancyPresentation) throws -> [OccupancyPresentation.Row] {
        guard case .rows(let rows, _) = presentation.ladder.state else {
            Issue.record("keine Zeilen")
            return []
        }
        return rows
    }

    // MARK: Vor dem Scan und währenddessen

    @Test func beforeTheScanTheBandSplitsOnlySystemAndData() throws {
        var state = OccupancyState(home: Self.home)
        state.inventory = Self.inventory()
        let presentation = Self.present(state)

        #expect(presentation.verdict == "\(Self.size(250 * Self.gigabyte)) frei von \(Self.size(1_000 * Self.gigabyte))")
        #expect(presentation.items.map(\.text) == ["Noch nicht gescannt"])
        #expect(presentation.facts == "macOS kann \(Self.size(30 * Self.gigabyte)) zusätzlich freigeben")
        #expect(!presentation.finding)
        let volume = try #require(presentation.volumes.first)
        #expect(volume.title == "Macintosh HD")
        #expect(volume.detail == "APFS · intern · verschlüsselt")
        #expect(volume.value == "75 % belegt")
        #expect(volume.parts.map(\.id) == ["system", "data", "purgeable"])
        #expect(volume.parts.map(\.level) == [0, 1, 4])
        // Belegt 750 GB: System 20, bereinigbar 30, Daten 700.
        #expect(volume.parts.map(\.value) == [20, 700, 30].map { Self.size($0 * Self.gigabyte) })
        #expect(volume.free == Self.size(250 * Self.gigabyte))
        guard case .placeholder(let title, _, _) = presentation.ladder.state else {
            Issue.record("Leerzustand erwartet")
            return
        }
        #expect(title == "Noch nicht gescannt")
        #expect(presentation.detail == nil)
        #expect(presentation.bar.scanTitle == "Scannen")
        #expect(presentation.bar.canScan)
    }

    @Test func whileScanningTheProgressShowsInLadderAndBar() {
        var state = OccupancyState(home: Self.home)
        state.phase = .scanning
        state.progress = OccupancyProgress(folders: 21_870, files: 182_340, allocatedBytes: 96 * Self.gigabyte)
        let presentation = Self.present(state)

        #expect(presentation.items.map(\.text) == ["Scan läuft"])
        #expect(presentation.items.first?.tone == .info)
        #expect(presentation.bar.isScanning)
        #expect(!presentation.bar.canScan)
        #expect(presentation.bar.status == "\(182_340.formatted()) Dateien · \(Self.size(96 * Self.gigabyte)) gelesen")
        guard case .placeholder(let title, let description, _) = presentation.ladder.state else {
            Issue.record("Fortschritt erwartet")
            return
        }
        #expect(title == "Scan läuft")
        #expect(description.hasPrefix("\(182_340.formatted()) Dateien in \(21_870.formatted()) Ordnern"))
    }

    @Test func aFailedScanSaysWhy() {
        var state = OccupancyState(home: Self.home)
        state.phase = .failed("Der Ordner ist nicht verfügbar.")
        let presentation = Self.present(state)
        guard case .placeholder(let title, let description, _) = presentation.ladder.state else {
            Issue.record("Leerzustand erwartet")
            return
        }
        #expect(title == "Scan nicht möglich")
        #expect(description == "Der Ordner ist nicht verfügbar.")
        #expect(presentation.bar.status == "Der Ordner ist nicht verfügbar.")
    }

    // MARK: Fertig

    @Test func afterAHomeScanTheBandShowsHomeCleanableAndRest() async throws {
        let presentation = Self.present(try await Self.scanned())

        // Benutzerordner 122 GB, davon aufräumbar 13 GB (app 10 + Homebrew 3); Rest 750 − 122 − 30.
        #expect(presentation.items.map(\.text) == ["\(Self.size(13 * Self.gigabyte)) über Speicher aufräumbar"])
        #expect(presentation.facts.hasSuffix(" · gescannt heute 20:59"))
        let volume = try #require(presentation.volumes.first)
        #expect(volume.parts.map(\.id) == ["rest", "home", "cleanable", "purgeable"])
        #expect(volume.parts.map(\.title) == ["System und weitere", "Benutzerordner", "über Speicher aufräumbar",
                                              "bereinigbar"])
        #expect(volume.parts.map(\.value) == [598, 109, 13, 30].map { Self.size($0 * Self.gigabyte) })
        #expect(volume.parts.map(\.level) == [0, 2, 3, 4])
        #expect(presentation.bar.status == "Gescannt heute 20:59 in 58 s")
        #expect(presentation.bar.scanTitle == "Erneut scannen")
    }

    @Test func ladderListsSubfoldersBySizeWithFilesAndShares() async throws {
        let presentation = Self.present(try await Self.scanned())
        let rows = try Self.rows(presentation)

        #expect(rows.map(\.name) == ["Movies", "Library", "Documents", "Dateien direkt in Benutzerordner"])
        #expect(rows.map(\.kind) == [.folder, .folder, .folder, .files])
        #expect(rows[0].value == Self.size(100 * Self.gigabyte))
        #expect(abs((rows[0].fraction ?? 0) - 100.0 / 122) < 0.001)
        #expect(rows[0].isDescendable == false)
        #expect(rows[1].isDescendable)
        #expect(rows[0].accessibilityLabel == "Movies, \(Self.size(100 * Self.gigabyte)), 82 % von Benutzerordner")
        #expect(presentation.ladder.steps.map(\.title) == ["Benutzerordner"])
        #expect(presentation.ladder.value == Self.size(122 * Self.gigabyte))
        #expect(presentation.ladder.detail == "Benutzerordner · 7 Dateien")
    }

    /// Kategorie-Chip nur, wenn sie von der des aktuellen Ordners abweicht; bewusst ausgelassene Einträge „bleibt“.
    @Test func categoryChipsShowOnlyWhereTheCategoryChanges() async throws {
        let library = try Self.rows(Self.present(try await Self.scanned(trail: ["Library"])))
        #expect(library.first { $0.name == "Caches" }?.chip?.text == "Caches")
        #expect(library.first { $0.name == "Caches" }?.chip?.tone == .info)
        #expect(library.first { $0.name == "Prefs" }?.chip == nil)

        let caches = Self.present(try await Self.scanned(trail: ["Library", "Caches"]))
        let rows = try Self.rows(caches)
        #expect(rows.first { $0.name == "app" }?.chip == nil)
        #expect(rows.first { $0.name == "Homebrew" }?.chip?.text == "Homebrew aufräumen")
        #expect(rows.first { $0.name == "keep" }?.chip?.text == "bleibt")
        #expect(caches.ladder.steps.map(\.title) == ["Benutzerordner", "Library", "Caches"])
        #expect(caches.ladder.steps.map(\.depth) == [0, 1, 2])
    }

    @Test func detailShowsTheCurrentFolderWithCategoryCleanableAndTimeMachine() async throws {
        var state = try await Self.scanned(trail: ["Library", "Caches"])
        var detail = try #require(Self.present(state).detail)
        #expect(detail.title == "Caches")
        #expect(detail.detail == "Ordner · 94 % von Library")
        #expect(detail.displayPath == "~/Library/Caches")
        #expect(detail.path == Self.home + "/Library/Caches")
        #expect(detail.fields.map(\.title) == ["Dateien", "Unterordner", "Letzte Änderung", "davon aufräumbar"])
        #expect(detail.fields.last?.value == Self.size(13 * Self.gigabyte))
        #expect(detail.hints.map(\.title) == ["Kategorie", "Time Machine"])
        #expect(detail.hints[0].status.text == "Caches")
        #expect(detail.hints[0].text.hasPrefix("Risiko gering · über Speicher aufräumbar."))
        #expect(detail.hints[1].status.text == "wird geprüft …")
        #expect(detail.categoryID == "caches")
        #expect(detail.cleanupTitle == "In Speicher aufräumen")

        state.timeMachine[Self.home + "/Library/Caches"] = TimeMachineFolderStatus(state: .included, excludedFolder: nil)
        detail = try #require(Self.present(state).detail)
        #expect(detail.hints[1].status.text == "wird gesichert")
        #expect(detail.hints[1].text == "Vorschlag: aus Time Machine ausnehmen (Caches, Risiko gering).")
    }

    @Test func aChosenLeafAndTheFilesRowShowInTheDetail() async throws {
        var state = try await Self.scanned()
        let tree = try #require(state.tree)
        state.selection = try #require(tree.folder(atPath: Self.home + "/Movies")).id
        var presentation = Self.present(state)
        #expect(presentation.detail?.title == "Movies")
        guard case .rows(_, let selection) = presentation.ladder.state else { return }
        #expect(selection == state.selection)

        state.selection = OccupancyPresentation.filesRowID
        presentation = Self.present(state)
        #expect(presentation.detail?.title == "Dateien")
        #expect(presentation.detail?.detail == "direkt in Benutzerordner")
        #expect(presentation.detail?.largestFiles == [OccupancyPresentation.Fact(title: "loose", value: Self.size(Self.gigabyte))])
        #expect(presentation.detail?.categoryID == nil)
    }

    // MARK: Nicht erfasst, Netzlaufwerk, viele Ordner

    @Test func protectedPlacesLeftOutAreMarkedAsNotCaptured() async throws {
        var state = try await Self.scanned(excluded: [Self.home + "/Documents"])
        state.isFullDiskAccessMissing = true
        state.excludedPlaces = 1
        let presentation = Self.present(state)
        let rows = try Self.rows(presentation)
        let documents = try #require(rows.first { $0.name == "Documents" })

        #expect(documents.value == "–")
        #expect(documents.fraction == nil)
        #expect(documents.chip?.text == "nicht erfasst")
        #expect(documents.isMuted)
        #expect(!documents.isDescendable)
        #expect(presentation.ladder.value == "≥ \(Self.size(117 * Self.gigabyte))")
        #expect(presentation.ladder.offersFullDiskAccess)
        #expect(presentation.ladder.notes.first?.hasPrefix("Ohne Festplattenvollzugriff liest Grantry 1 geschützten Ort") == true)
        #expect(presentation.items.map(\.text).contains("1 Ort nicht erfasst"))
        #expect(presentation.volumes.first?.parts.map(\.title).contains("Benutzerordner (erfasst)") == true)

        var chosen = state
        chosen.selection = documents.id
        let detail = try #require(Self.present(chosen).detail)
        #expect(detail.value == "–")
        #expect(detail.hints.map(\.title) == ["Erfassung"])
        #expect(detail.hints[0].text == "Ohne Festplattenvollzugriff liest Grantry diesen Ort nicht, damit macOS nicht nachfragt.")
    }

    @Test func networkMountsAreLeftOutWithANote() async throws {
        let fileSystem = Self.fileSystem()
        fileSystem.addMountPoint("NAS", isLocal: false)
        fileSystem.addMountPoint("Stick", isLocal: true)
        let presentation = Self.present(try await Self.scanned(fileSystem))
        let rows = try Self.rows(presentation)

        #expect(rows.first { $0.name == "NAS" }?.chip?.text == "Netzlaufwerk, ausgelassen")
        #expect(rows.first { $0.name == "NAS" }?.kind == .network)
        #expect(rows.first { $0.name == "Stick" }?.chip?.text == "anderes Volume")
        #expect(presentation.ladder.notes.contains("Netzlaufwerke liest Grantry nicht; sie bleiben ausgelassen."))
    }

    /// Codex-Review TM-15.6 (#405): Ein ausgelassenes Volume ist nicht gemessen – im Detail nie „0“, keine Time-Machine-
    /// Prüfung, kein Weg nach Speicher, dafür der Grund der Auslassung.
    @Test func chosenLeftOutVolumesShowUnknownSizeAndTheReason() async throws {
        let fileSystem = Self.fileSystem()
        fileSystem.addMountPoint("NAS", isLocal: false)
        fileSystem.addMountPoint("Stick", isLocal: true)
        let state = try await Self.scanned(fileSystem)
        let tree = try #require(state.tree)
        for (name, chip, text) in [
            ("NAS", "Netzlaufwerk, ausgelassen", "Netzlaufwerke liest Grantry nicht; die Größe ist unbekannt."),
            ("Stick", "anderes Volume", "Hier ist ein anderes Volume eingehängt. Der Scan bleibt auf einem Volume; die Größe ist unbekannt."),
        ] {
            var chosen = state
            chosen.selection = try #require(tree.folder(atPath: Self.home + "/" + name)).id
            let detail = try #require(Self.present(chosen).detail)
            #expect(detail.title == name)
            #expect(detail.value == "–")
            #expect(detail.detail == "Ordner · ausgelassen")
            #expect(detail.fields.map(\.value) == ["–", "–", "–"])
            #expect(detail.hints.map(\.title) == ["Erfassung"])
            #expect(detail.hints.first?.status.text == chip)
            #expect(detail.hints.first?.text == text)
            #expect(detail.categoryID == nil)
            #expect(detail.cleanupTitle == nil)
        }
    }

    @Test func manySubfoldersAreSummarizedBeyondTheRowLimit() async throws {
        let fileSystem = FakeOccupancyFileSystem(rootPath: Self.home)
        for index in 0..<(OccupancyPresentation.maximumRows + 5) {
            fileSystem.addFile("f\(index)/x", bytes: Int64(1_000 + index))
        }
        let rows = try Self.rows(Self.present(try await Self.scanned(fileSystem)))

        #expect(rows.count == OccupancyPresentation.maximumRows + 1)
        #expect(rows.last?.kind == .more)
        #expect(rows.last?.name == "5 weitere Ordner")
        #expect(rows.last?.id == OccupancyPresentation.moreRowID)
    }

    // MARK: Volumes und Datenträger

    @Test func devicesShowSmartConnectionContainersAndSnapshots() {
        var state = OccupancyState(home: Self.home)
        state.inventory = Self.inventory(complete: false, external: true)
        let presentation = Self.present(state)

        #expect(presentation.devices.detail == "1 intern · 1 extern")
        #expect(presentation.devices.devices.map(\.smart.text) == ["SMART verifiziert", "SMART nicht unterstützt"])
        #expect(presentation.devices.devices.map(\.smart.tone) == [.positive, .neutral])
        #expect(presentation.devices.devices[0].detail == "Apple Fabric · SSD · \(Self.size(1_000 * Self.gigabyte))")
        #expect(presentation.devices.devices[0].facts == [
            .init(title: "Container", value: "disk3, 3 Volumes"), .init(title: "Lokale Snapshots", value: "2, ältester 06.11."),
        ])
        #expect(presentation.devices.devices[1].facts == [.init(title: "Container", value: "disk5, 1 Volume")])
        #expect(presentation.devices.note != nil)
        #expect(presentation.volumes.map(\.title) == ["Macintosh HD", "Archiv"])
        #expect(presentation.volumes[1].detail == "APFS · USB · nicht verschlüsselt")
        #expect(presentation.volumes[1].parts.map(\.id) == ["data"])
    }

    @Test func failingSmartIsCritical() {
        var inventory = Self.inventory()
        let device = inventory.devices[0]
        inventory = VolumeInventory(devices: [StorageDevice(id: device.id, name: device.name, smartStatus: .failing,
                                                            containers: device.containers)],
                                    localSnapshots: nil, isComplete: true)
        var state = OccupancyState(home: Self.home)
        state.inventory = inventory
        let presentation = Self.present(state)
        #expect(presentation.devices.devices.first?.smart == .init(text: "SMART Fehler", tone: .critical))
        #expect(presentation.devices.devices.first?.facts.last == .init(title: "Lokale Snapshots", value: "unbekannt"))
    }

    /// Wie die Zustandszeile der übrigen Tabs (#462): laufende Datenträger-Befunde aus `FindingRules` setzen den
    /// Befund-Punkt; beendete und Befunde ohne Bezug zu Datenträgern nicht.
    @Test func ongoingStorageFindingsMarkTheStatusLine() throws {
        var inventory = Self.inventory()
        let device = inventory.devices[0]
        inventory = VolumeInventory(devices: [StorageDevice(id: device.id, name: device.name, smartStatus: .failing,
                                                            containers: device.containers)],
                                    localSnapshots: nil, isComplete: true)
        var state = OccupancyState(home: Self.home)
        state.inventory = inventory
        let storage = FindingRules.storageFindings(in: inventory, at: Self.now)
        let smart = try #require(storage.first { $0.kind == .smartFailure })
        let load = SystemFinding(kind: .systemLoad, tone: .finding, reason: "Last", start: Self.now, end: nil,
                                 evidence: .init(limit: 0, peak: 1, mean: 1), subject: nil)
        let ended = SystemFinding(kind: smart.kind, tone: smart.tone, reason: smart.reason, start: smart.start,
                                  end: Self.now, evidence: smart.evidence, subject: smart.subject)

        #expect(Self.present(state, findings: storage).finding)
        #expect(!Self.present(state, findings: [load, ended]).finding)
        #expect(!Self.present(state).finding)
    }

    @Test func aWholeVolumeScanSplitsSystemAppsAndUsers() async throws {
        let fileSystem = FakeOccupancyFileSystem(rootPath: "/System/Volumes/Data")
        fileSystem.addFile("Applications/X.app/x", bytes: 40 * Self.gigabyte)
        fileSystem.addFile("Users/me/m", bytes: 300 * Self.gigabyte)
        fileSystem.addFile("Library/l", bytes: 10 * Self.gigabyte)
        var state = try await Self.scanned(fileSystem)
        state.scope = .volume
        let presentation = Self.present(state)
        let volume = try #require(presentation.volumes.first)

        #expect(volume.parts.map(\.id) == ["system", "apps", "users", "cleanable", "purgeable"])
        #expect(volume.parts.map(\.value) == [380, 40, 300, 0, 30].map { Self.size($0 * Self.gigabyte) })
        #expect(presentation.ladder.steps.first?.title == "Macintosh HD")
        #expect(presentation.ladder.detail.hasPrefix("Ganzer Datenträger"))
    }

    @Test func momentsReadAsTodayYesterdayOrDate() {
        let texts = OccupancyTexts(now: Self.now, calendar: Self.calendar)
        #expect(texts.moment(Self.now.addingTimeInterval(-3_600)) == "heute 20:00")
        #expect(texts.moment(Self.now.addingTimeInterval(-86_400)) == "gestern 21:00")
        #expect(texts.moment(Self.now.addingTimeInterval(-3 * 86_400)) == "05.11. 21:00")
        #expect(OccupancyTexts.duration(.seconds(58)) == "58 s")
        #expect(OccupancyTexts.duration(.seconds(192)) == "3 min 12 s")
        #expect(OccupancyTexts.percent(0.004) == "< 1 %")
    }
}
