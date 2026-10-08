import CoreServices
import Foundation
import Synchronization
import Testing
import TestSupport
@testable import ManagerKit

/// Finder-Attrappe: fragt die Dateiliste wie der echte Sender erst im Sendeblock ab (davor `beforeSending`), „löscht“
/// die ersten `removing` Dateien, indem sie das Objekt am Pfad – wie der Finder per Umbenennen – in den
/// Scratch-Papierkorb `.Trash` verschiebt (`deletingImmediately`: entfernt es stattdessen endgültig; unmittelbar davor
/// `beforeResolving`), ruft danach `afterDeleting` und meldet `status` (0 = Erfolg).
private final class FakeFinder: FinderEventSending {
    private let permission: OSStatus
    private let status: Int?
    private let removing: Int
    private let deletingImmediately: Bool
    private let trash: URL
    private let beforeSending: @Sendable () -> Void
    private let beforeResolving: @Sendable () -> Void
    private let afterDeleting: @Sendable () -> Void
    private let sent = Mutex<[[URL]]>([])

    init(
        permission: OSStatus = OSStatus(noErr), status: Int? = nil, removing: Int = .max, deletingImmediately: Bool = false,
        trash: URL, beforeSending: @escaping @Sendable () -> Void = {}, beforeResolving: @escaping @Sendable () -> Void = {},
        afterDeleting: @escaping @Sendable () -> Void = {}
    ) {
        self.permission = permission
        self.status = status
        self.removing = removing
        self.deletingImmediately = deletingImmediately
        self.trash = trash
        self.beforeSending = beforeSending
        self.beforeResolving = beforeResolving
        self.afterDeleting = afterDeleting
    }

    var sentEvents: [[URL]] { sent.withLock { $0 } }

    func permissionStatus() async -> OSStatus { permission }

    func delete(timeout: TimeInterval, urls makeURLs: @escaping @Sendable () -> [URL]) async -> Int? {
        beforeSending()
        let urls = makeURLs()
        guard !urls.isEmpty else { return nil }
        sent.withLock { $0.append(urls) }
        beforeResolving()
        for url in urls.prefix(removing) {
            if deletingImmediately {
                try? FileManager.default.removeItem(at: url)
            } else {
                try? FileManager.default.moveItem(at: url, to: trash.appending(path: UUID().uuidString))
            }
        }
        afterDeleting()
        return status
    }
}

/// Scratch-Papierkorb `.Trash` wie der des Finders (`FinderTrash.isInTrashFolder`).
private func makeTrash(in directory: URL) throws -> URL {
    let trash = directory.appending(path: ".Trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    return trash
}

/// Lehnt die Pfade in `refused` ab (Netzlaufwerk), alle übrigen sind lokal.
private struct FakeVolumes: TrashVolumeChecking {
    var refused: Set<String> = []
    func refusalReason(forPath path: String) -> String? {
        refused.contains(path) ? LocalVolumeTrashCheck.networkReason : nil
    }
}

/// Kandidat mit dem Objekt von jetzt (wie aus der Suche).
private func candidate(_ url: URL) -> LeftoverCandidate {
    LeftoverCandidate(path: url.path, kind: .caches, confidence: .safe, identity: FileIdentity.of(url.path))
}

/// Letzte Prüfung wie der `RemovalGuard` vor dem Papierkorb: noch dasselbe Objekt.
private let sameObject: @Sendable (LeftoverCandidate) -> RemovalVerdict = { candidate in
    FileIdentity.of(candidate.path) == candidate.identity ? .allowed : .blocked("Eintrag wurde ersetzt")
}

/// Ort nicht ermittelbar (z. B. kein Suchrecht auf einem Ordner des Pfads).
private struct UnknownLocation: FileLocating {
    func locate(_ identity: FileIdentity) -> FileLocation { .unknown }
}

/// Meldet für jedes Objekt denselben Ort (z. B. den Papierkorb eines externen Volumes).
private struct FixedLocation: FileLocating {
    var location: FileLocation
    func locate(_ identity: FileIdentity) -> FileLocation { location }
}

private func finderTrash(
    _ finder: FakeFinder, volumes: FakeVolumes = FakeVolumes(), locator: any FileLocating = FSGetPathLocator()
) -> FinderTrash {
    FinderTrash(sender: finder, volumes: volumes, locator: locator)
}

@Suite struct FinderTrashTests {
    @Test func eventTargetsFinderDeleteWithAllFiles() {
        let urls = [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b c")]
        let event = FinderDeleteEvent.make(urls: urls)
        #expect(event.eventClass == AEEventClass(kAECoreSuite))
        #expect(event.eventID == AEEventID(kAEDelete))
        let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        #expect(list?.numberOfItems == 2)
        #expect(list?.atIndex(1)?.fileURLValue?.path == "/tmp/a")
        #expect(list?.atIndex(2)?.fileURLValue?.path == "/tmp/b c")
    }

    @Test(arguments: [
        (OSStatus(noErr), TrashPermission.granted),
        (OSStatus(errAEEventNotPermitted), .denied),
        (OSStatus(-600), .unavailable("Der Finder läuft nicht.")),
        (OSStatus(-1), .unavailable("Automation-Freigabe für den Finder nicht prüfbar (Fehler -1).")),
    ])
    func permissionIsMapped(status: OSStatus, expected: TrashPermission) async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            #expect(await finderTrash(FakeFinder(permission: status, trash: directory)).requestPermission() == expected)
        }
    }

    @Test func everyFileIsCheckedAfterTheEvent() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let first = directory.appending(path: "first"), second = directory.appending(path: "second")
            for url in [first, second] { try Data([1]).write(to: url) }
            let finder = FakeFinder(status: -128, removing: 1, trash: trash)
            let report = await finderTrash(finder).moveToTrash([candidate(first), candidate(second)], verifying: sameObject)
            #expect(finder.sentEvents.map { $0.map(\.path) } == [[first.path, second.path]], "ein Apple Event für alle Dateien")
            #expect(report.outcomes == [first.path: .trashed, second.path: .remaining("Abgebrochen (z. B. Passwortabfrage)")])
            #expect(report.failure == "Abgebrochen (z. B. Passwortabfrage)")
        }
    }

    @Test func successLeavesNothingBehind() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file")
            try Data([1]).write(to: file)
            let report = await finderTrash(FakeFinder(trash: trash)).moveToTrash([candidate(file)], verifying: sameObject)
            #expect(report == TrashReport(outcomes: [file.path: .trashed], failure: nil))
        }
    }

    @Test func noPathsSendNoEvent() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let finder = FakeFinder(trash: directory)
            #expect(await finderTrash(finder).moveToTrash([], verifying: sameObject) == TrashReport(outcomes: [:], failure: nil))
            #expect(finder.sentEvents.isEmpty)
        }
    }

    /// Review N2: Die letzte Prüfung läuft im Sendeblock – ein kurz davor ersetzter Eintrag geht nicht an den Finder.
    @Test func lastCheckRunsImmediatelyBeforeSending() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let swapped = directory.appending(path: "swapped"), kept = directory.appending(path: "kept")
            for url in [swapped, kept] { try Data([1]).write(to: url) }
            let candidates = [candidate(swapped), candidate(kept)]
            let finder = FakeFinder(trash: trash, beforeSending: {
                try? FileManager.default.removeItem(at: swapped)
                try? Data([2]).write(to: swapped)
            })
            let report = await finderTrash(finder).moveToTrash(candidates, verifying: sameObject)
            #expect(finder.sentEvents.map { $0.map(\.path) } == [[kept.path]])
            #expect(report.outcomes == [swapped.path: .blocked("Eintrag wurde ersetzt"), kept.path: .trashed])
            #expect(FileManager.default.fileExists(atPath: swapped.path))
        }
    }

    /// Ist am Pfad nach dem Event ein anderes Objekt, liegt das Original im Papierkorb – „neu angelegt“, nicht „noch da“.
    @Test func recreatedEntryIsNotReportedAsRemaining() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file")
            try Data([1]).write(to: file)
            let finder = FakeFinder(trash: trash, afterDeleting: { try? Data([2]).write(to: file) })
            let report = await finderTrash(finder).moveToTrash([candidate(file)], verifying: sameObject)
            #expect(report.outcomes == [file.path: .recreated])
        }
    }

    /// #104: Wird das Original nach der letzten Prüfung verschoben und ein anderes Objekt an seinen Pfad gelegt, legt der
    /// Finder das Ersatzobjekt in den Papierkorb. Der fehlende Pfad gilt dann nicht als „im Papierkorb“ – `fsgetpath`
    /// zeigt das Original anderswo.
    @Test func originalMovedAwayBeforeTheFinderResolvedIsNotReportedAsTrashed() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file"), hideout = directory.appending(path: "hideout")
            try Data([1]).write(to: file)
            // Nach der letzten Prüfung (im Sendeblock), bevor der „Finder“ den Pfad auflöst.
            let finder = FakeFinder(trash: trash, beforeResolving: {
                try? FileManager.default.moveItem(at: file, to: hideout)
                try? Data([2]).write(to: file)
            })
            let report = await finderTrash(finder).moveToTrash([candidate(file)], verifying: sameObject)
            #expect(finder.sentEvents.map { $0.map(\.path) } == [[file.path]], "die Prüfung sah noch das Original")
            let outcome = try #require(report.outcomes[file.path])
            guard case .remaining(let reason) = outcome else {
                Issue.record("erwartet .remaining, erhalten \(outcome)")
                return
            }
            #expect(reason.hasPrefix(FinderTrash.movedAwayPrefix), "\(reason)")
            #expect(reason.contains("hideout"), "\(reason)")
            #expect(FileManager.default.fileExists(atPath: hideout.path), "das Original liegt noch im Versteck")
        }
    }

    /// #104: Ist das Original nach dem Event nirgends mehr (sofort gelöscht statt in den Papierkorb), ist das kein Erfolg.
    @Test func vanishedOriginalIsNotReportedAsTrashed() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file")
            try Data([1]).write(to: file)
            let finder = FakeFinder(deletingImmediately: true, trash: trash)
            let report = await finderTrash(finder).moveToTrash([candidate(file)], verifying: sameObject)
            #expect(report.outcomes == [file.path: .remaining(FinderTrash.vanishedReason)])
        }
    }

    /// #104: Auch „neu angelegt“ setzt voraus, dass das Original im Papierkorb liegt.
    @Test func recreatedRequiresTheOriginalInTheTrash() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file")
            try Data([1]).write(to: file)
            let finder = FakeFinder(deletingImmediately: true, trash: trash, afterDeleting: { try? Data([2]).write(to: file) })
            let report = await finderTrash(finder).moveToTrash([candidate(file)], verifying: sameObject)
            #expect(report.outcomes == [file.path: .remaining(FinderTrash.vanishedReason)])
        }
    }

    /// Ohne ermittelbaren Ort gilt wie bisher der Pfad: weg heißt im Papierkorb.
    @Test func unknownLocationFallsBackToThePathCheck() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file"), hideout = directory.appending(path: "hideout")
            try Data([1]).write(to: file)
            let finder = FakeFinder(trash: trash, beforeResolving: { try? FileManager.default.moveItem(at: file, to: hideout) })
            let report = await finderTrash(finder, locator: UnknownLocation()).moveToTrash([candidate(file)], verifying: sameObject)
            #expect(report.outcomes == [file.path: .trashed])
        }
    }

    /// Ohne gespeicherte Identität (Attrappen-Kandidat) gibt es keinen Nachweis – der Pfad entscheidet.
    @Test func candidateWithoutIdentityIsJudgedByPath() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file")
            try Data([1]).write(to: file)
            let anonymous = LeftoverCandidate(path: file.path, kind: .caches, confidence: .safe)
            let report = await finderTrash(FakeFinder(deletingImmediately: true, trash: trash)).moveToTrash([anonymous]) { _ in .allowed }
            #expect(report.outcomes == [file.path: .trashed])
        }
    }

    /// Reguläre Dateien mit weiteren harten Verknüpfungen gelten auch im Papierkorb nicht als entsorgt – sonst schaltete
    /// ein `link(2)` auf das Original den Nachweis ab.
    @Test func hardLinkedFileIsNotReportedAsTrashed() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file"), link = directory.appending(path: "link")
            try Data([1]).write(to: file)
            try FileManager.default.linkItem(at: file, to: link)
            let identity = try #require(FileIdentity.of(file.path))
            guard case .found(_, hasOtherNames: true) = FSGetPathLocator().locate(identity) else {
                Issue.record("weitere Namen nicht erkannt")
                return
            }
            let report = await finderTrash(FakeFinder(trash: trash)).moveToTrash([candidate(file)], verifying: sameObject)
            // `fsgetpath` nennt einen der beiden Namen: `link` (anderswo) oder den im Papierkorb (weitere Namen).
            let outcome = try #require(report.outcomes[file.path])
            guard case .remaining(let reason) = outcome else {
                Issue.record("erwartet .remaining, erhalten \(outcome)")
                return
            }
            #expect(reason == FinderTrash.hardLinkedReason || reason.hasPrefix(FinderTrash.movedAwayPrefix), "\(reason)")
        }
    }

    @Test func hardLinkedOriginalInTheTrashIsReportedWithReason() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file")
            try Data([1]).write(to: file)
            let inTrash = FixedLocation(location: .found(path: trash.appending(path: "file").path, hasOtherNames: true))
            let report = await finderTrash(FakeFinder(trash: trash), locator: inTrash).moveToTrash([candidate(file)], verifying: sameObject)
            #expect(report.outcomes == [file.path: .remaining(FinderTrash.hardLinkedReason)])
        }
    }

    /// Der Papierkorb eines externen Volumes (`/Volumes/…/.Trashes/<uid>`) zählt als Papierkorb.
    @Test func originalInAnotherVolumesTrashCountsAsTrashed() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file")
            try Data([1]).write(to: file)
            let external = FixedLocation(location: .found(path: "/Volumes/Disk/.Trashes/501/file", hasOtherNames: false))
            let report = await finderTrash(FakeFinder(trash: trash), locator: external).moveToTrash([candidate(file)], verifying: sameObject)
            #expect(report.outcomes == [file.path: .trashed])
        }
    }

    /// Der häufigste Kandidat ist ein Ordner (Container, Caches, App-Bundle): Nachweis per Umbenennen in den Papierkorb.
    @Test func folderCandidateIsProvenInTheTrash() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let folder = directory.appending(path: "Container"), hideout = directory.appending(path: "hideout")
            try FileManager.default.createDirectory(at: folder.appending(path: "Data/Library"), withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appending(path: "Data/Library/file"))
            let trashed = await finderTrash(FakeFinder(trash: trash)).moveToTrash([candidate(folder)], verifying: sameObject)
            #expect(trashed.outcomes == [folder.path: .trashed])

            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let swapped = FakeFinder(trash: trash, beforeResolving: {
                try? FileManager.default.moveItem(at: folder, to: hideout)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            })
            let report = await finderTrash(swapped).moveToTrash([candidate(folder)], verifying: sameObject)
            let outcome = try #require(report.outcomes[folder.path])
            guard case .remaining(let reason) = outcome else {
                Issue.record("erwartet .remaining, erhalten \(outcome)")
                return
            }
            #expect(reason.hasPrefix(FinderTrash.movedAwayPrefix) && reason.contains("hideout"), "\(reason)")
        }
    }

    /// Bei Finder-Fehler und verschobenem Original zählt der Befund zum Original, nicht der Fehlertext des Events.
    @Test func movedAwayOriginalOutranksTheEventFailure() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let file = directory.appending(path: "file"), hideout = directory.appending(path: "hideout")
            try Data([1]).write(to: file)
            let finder = FakeFinder(status: -128, trash: trash, beforeResolving: {
                try? FileManager.default.moveItem(at: file, to: hideout)
                try? Data([2]).write(to: file)
            })
            let report = await finderTrash(finder).moveToTrash([candidate(file)], verifying: sameObject)
            #expect(report.failure == "Abgebrochen (z. B. Passwortabfrage)")
            let outcome = try #require(report.outcomes[file.path])
            guard case .remaining(let reason) = outcome else {
                Issue.record("erwartet .remaining, erhalten \(outcome)")
                return
            }
            #expect(reason.hasPrefix(FinderTrash.movedAwayPrefix), "\(reason)")
        }
    }

    @Test func locatorFollowsRenamesAndReportsGoneObjects() throws {
        try ScratchDirectory.with(prefix: "locate") { directory in
            let file = directory.appending(path: "file"), moved = directory.appending(path: "sub/moved")
            let folder = directory.appending(path: "folder")
            try Data([1]).write(to: file)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fileIdentity = try #require(FileIdentity.of(file.path)), folderIdentity = try #require(FileIdentity.of(folder.path))
            let locator = FSGetPathLocator()
            // `fsgetpath` liefert den kanonischen Pfad (`/private/var/…` statt `/var/…`): Objekt und Name vergleichen.
            func expectFound(_ location: FileLocation, _ identity: FileIdentity, endingIn suffix: String) {
                guard case .found(let path, hasOtherNames: false) = location else {
                    Issue.record("erwartet .found, erhalten \(location)")
                    return
                }
                #expect(FileIdentity.of(path) == identity)
                #expect(path.hasSuffix(suffix), "\(path)")
            }
            expectFound(locator.locate(fileIdentity), fileIdentity, endingIn: "/file")
            expectFound(locator.locate(folderIdentity), folderIdentity, endingIn: "/folder")
            try FileManager.default.moveItem(at: file, to: moved)
            expectFound(locator.locate(fileIdentity), fileIdentity, endingIn: "/sub/moved")
            try FileManager.default.removeItem(at: moved)
            #expect(locator.locate(fileIdentity) == .gone)
            #expect(locator.locate(FileIdentity(device: fileIdentity.device, inode: 0, type: .regularFile)) == .unknown)
        }
    }

    @Test(arguments: [
        ("/Users/x/.Trash/file", true), ("/Volumes/Disk/.Trashes/501/App.app", true), ("/.Trashes/501/x", true),
        ("/Users/x/Library/Caches/.Trash-looking", false), ("/Users/x/Trash/file", false), ("/Library/Caches/x", false),
    ])
    func trashFoldersAreRecognized(path: String, expected: Bool) {
        #expect(FinderTrash.isInTrashFolder(path) == expected)
    }

    /// Verspäteter Finder-Erfolg (#143): Liegt das bestätigte Original inzwischen im Papierkorb, gilt es ohne neuen
    /// Auftrag als entsorgt; ein Ersatzobjekt am Pfad bleibt unangetastet (`.recreated`).
    @Test func originalAlreadyInTheTrashIsSettled() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let gone = directory.appending(path: "gone"), replaced = directory.appending(path: "replaced")
            let open = directory.appending(path: "open")
            for url in [gone, replaced, open] { try Data([1]).write(to: url) }
            let candidates = [gone, replaced, open].map(candidate)
            for url in [gone, replaced] { try FileManager.default.moveItem(at: url, to: trash.appending(path: url.lastPathComponent)) }
            try Data([2]).write(to: replaced)
            let finder = FakeFinder(trash: trash)
            let finderTrash = finderTrash(finder)
            #expect(candidates.map(finderTrash.settledOutcome) == [.trashed, .recreated, nil])
            #expect(finder.sentEvents.isEmpty)
        }
    }

    /// Darf die App den Papierkorb nicht mehr lesen (Festplattenvollzugriff zurückgesetzt – hier: pfadbasierte
    /// Auflösung verweigert), weisen die vorher festgehaltenen Deskriptoren das Original dennoch nach (#143).
    @Test func trackedOriginalIsProvenWithoutReadingTheTrash() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let url = directory.appending(path: "Grantry.plist")
            try Data([1]).write(to: url)
            let original = candidate(url)
            let denied = finderTrash(FakeFinder(trash: trash), locator: UnknownLocation())
            let tracked = FinderTrash(
                sender: FakeFinder(trash: trash), volumes: FakeVolumes(), locator: TrackedFileLocator(fallback: UnknownLocation())
            )
            tracked.track([original])
            let report = await tracked.moveToTrash([original], verifying: sameObject)
            #expect(report.outcomes == [url.path: .trashed])
            #expect(tracked.settledOutcome(of: original) == .trashed)
            #expect(denied.settledOutcome(of: original) == nil, "ohne Deskriptor kein Nachweis")
        }
    }

    /// Nur mit Nachweis: Original anderswo, unauffindbar oder ohne bekannte Identität bleibt offen.
    @Test func settledRequiresProofInTheTrash() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let url = directory.appending(path: "file")
            try Data([1]).write(to: url)
            let original = candidate(url)
            try FileManager.default.moveItem(at: url, to: directory.appending(path: "elsewhere"))
            #expect(finderTrash(FakeFinder(trash: trash)).settledOutcome(of: original) == nil)
            #expect(finderTrash(FakeFinder(trash: trash), locator: UnknownLocation()).settledOutcome(of: original) == nil)
            #expect(finderTrash(FakeFinder(trash: trash), locator: FixedLocation(location: .gone)).settledOutcome(of: original) == nil)
            let withoutIdentity = LeftoverCandidate(path: url.path, kind: .caches, confidence: .safe)
            #expect(finderTrash(FakeFinder(trash: trash)).settledOutcome(of: withoutIdentity) == nil)
        }
    }

    @Test func movedAwayReasonNamesThePath() {
        let reason = FinderTrash.movedAwayReason(NSHomeDirectory() + "/Documents/x")
        #expect(reason == FinderTrash.movedAwayPrefix + "„~/Documents/x“" + FinderTrash.movedAwaySuffix)
    }

    @Test func targetsOnVolumesWithoutTrashAreRefused() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let trash = try makeTrash(in: directory)
            let network = directory.appending(path: "network"), local = directory.appending(path: "local")
            for url in [network, local] { try Data([1]).write(to: url) }
            let finder = FakeFinder(trash: trash)
            let report = await finderTrash(finder, volumes: FakeVolumes(refused: [network.path]))
                .moveToTrash([candidate(network), candidate(local)], verifying: sameObject)
            #expect(finder.sentEvents.map { $0.map(\.path) } == [[local.path]])
            #expect(report.outcomes == [network.path: .blocked(LocalVolumeTrashCheck.networkReason), local.path: .trashed])
        }
    }

    @Test func onlyRefusedTargetsSendNoEvent() async throws {
        try await ScratchDirectory.with(prefix: "trash") { directory in
            let file = directory.appending(path: "file")
            try Data([1]).write(to: file)
            let finder = FakeFinder(trash: directory)
            let report = await finderTrash(finder, volumes: FakeVolumes(refused: [file.path]))
                .moveToTrash([candidate(file)], verifying: sameObject)
            #expect(finder.sentEvents.isEmpty)
            #expect(report == TrashReport(outcomes: [file.path: .blocked(LocalVolumeTrashCheck.networkReason)], failure: nil))
        }
    }

    @Test func localVolumeCheck() throws {
        try ScratchDirectory.with(prefix: "trash") { directory in
            #expect(LocalVolumeTrashCheck().refusalReason(forPath: directory.path) == nil)
            #expect(LocalVolumeTrashCheck().refusalReason(forPath: directory.appending(path: "fehlt").path)
                    == LocalVolumeTrashCheck.uncheckedReason)
        }
        #expect(LocalVolumeTrashCheck.refusalReason(flags: UInt32(MNT_LOCAL)) == nil)
        #expect(LocalVolumeTrashCheck.refusalReason(flags: 0) == LocalVolumeTrashCheck.networkReason)
        #expect(LocalVolumeTrashCheck.refusalReason(flags: UInt32(MNT_LOCAL | MNT_RDONLY)) == LocalVolumeTrashCheck.readOnlyReason)
    }

    @Test(arguments: [(-128, "Abgebrochen (z. B. Passwortabfrage)"), (-1712, "Finder antwortet nicht – Löschen läuft evtl. weiter"),
                      (-1743, "Keine Automation-Freigabe für den Finder"), (-600, "Der Finder läuft nicht."),
                      (-42, "Finder-Fehler -42")])
    func errorCodesHaveGermanTexts(code: Int, text: String) {
        #expect(FinderTrash.message(for: code) == text)
    }

    @Test func unavailableTrashNeverDeletes() async {
        let trash = UnavailableTrash()
        #expect(await trash.requestPermission() == .unavailable(UnavailableTrash.reason))
        let file = LeftoverCandidate(path: "/tmp/x", kind: .caches, confidence: .safe)
        #expect(await trash.moveToTrash([file]) { _ in .allowed }.outcomes == ["/tmp/x": .remaining(UnavailableTrash.reason)])
    }

    @Test func deniedPermissionLinksToAutomationSettings() {
        #expect(TrashPermission.settingsURL
                == URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"))
    }

    @Test func replyErrorNumberCountsAsFailure() {
        let reply = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEAnswer), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        #expect(FinderDeleteEvent.errorCode(in: reply) == nil, "Antwort ohne Fehlernummer = Erfolg")
        reply.setParam(NSAppleEventDescriptor(int32: -128), forKeyword: AEKeyword(keyErrorNumber))
        #expect(FinderDeleteEvent.errorCode(in: reply) == -128)
        reply.setParam(NSAppleEventDescriptor(int32: 0), forKeyword: AEKeyword(keyErrorNumber))
        #expect(FinderDeleteEvent.errorCode(in: reply) == nil)
    }
}
