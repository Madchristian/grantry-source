import Foundation
import Testing
import TestSupport
@testable import ManagerKit

/// Papierkorb für Plug-ins in Systemdiensten (TM-13.5, #391): nur direkte Einträge der Plug-in-Ordner, derselbe Eintrag
/// wie beim Bestätigen, nie Apple, nie Kernel- oder Systemerweiterungen; über den Finder (hier `RecordingTrash`).
@Suite struct ServicePluginRemoverTests {
    private struct Fixture {
        let hal: URL
        let remover: ServicePluginRemover
        let trash: RecordingTrash
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        try await ScratchDirectory.withCanonical(prefix: "plugin-remover") { scratch in
            let hal = scratch.appending(path: "Library/Audio/Plug-Ins/HAL")
            try FileManager.default.createDirectory(at: hal, withIntermediateDirectories: true)
            let bin = scratch.appending(path: "Trash")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let trash = RecordingTrash(destination: bin)
            let remover = ServicePluginRemover(pathGuard: ServicePluginPathGuard(directories: [hal.path]), trash: trash)
            try await body(Fixture(hal: hal, remover: remover, trash: trash))
        }
    }

    private func bundle(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
        return url
    }

    private func plugin(_ url: URL, bundleID: String = "com.vendor.audio",
                        signing: SigningInfo = SigningInfo(kind: .developerID, teamID: "TEAMPLUG01")) -> ExtensionRecord {
        TestData.extensionRecord(bundleID, kind: .audioPlugin, teamID: signing.teamID, state: .installed,
                                 signing: signing, path: url.path)
    }

    private func request(_ remover: ServicePluginRemover, _ record: ExtensionRecord) throws -> ServicePluginTrashRequest {
        guard case .ready(let request) = remover.prepare(record) else {
            Issue.record("nicht bereit: \(remover.prepare(record))")
            throw CancellationError()
        }
        return request
    }

    @Test func movesAThirdPartyPluginToTheTrash() async throws {
        try await withFixture { fixture in
            let url = try bundle("Vendor.driver", in: fixture.hal)
            let request = try request(fixture.remover, plugin(url))
            #expect(await fixture.remover.moveToTrash(request) == .trashed)
            #expect(fixture.trash.movedPaths == [url.path])
        }
    }

    @Test func refusesKernelAndSystemExtensionsAndAppleCode() async throws {
        try await withFixture { fixture in
            let url = try bundle("Vendor.driver", in: fixture.hal)
            let kext = TestData.extensionRecord(kind: .kernelExtension, signing: SigningInfo(kind: .developerID), path: url.path)
            let system = TestData.extensionRecord(kind: .network, path: url.path)
            let apple = plugin(url, signing: SigningInfo(kind: .apple))
            let appleID = plugin(url, bundleID: "com.apple.audio.Vendor")
            #expect(fixture.remover.prepare(kext) == .blocked("Nur Plug-ins in Systemdiensten"))
            #expect(fixture.remover.prepare(system) == .blocked("Nur Plug-ins in Systemdiensten"))
            #expect(fixture.remover.prepare(apple) == .blocked("Plug-in von Apple"))
            #expect(fixture.remover.prepare(appleID) == .blocked("Plug-in von Apple"))
            #expect(fixture.trash.movedPaths.isEmpty)
        }
    }

    @Test func refusesEntriesOutsideOrBelowThePluginFolder() async throws {
        try await withFixture { fixture in
            let nested = try bundle("Outer.driver/Contents/Inner.driver", in: fixture.hal)
            let outside = try bundle("Vendor.driver", in: fixture.hal.deletingLastPathComponent())
            #expect(fixture.remover.prepare(plugin(nested)) == .blocked("Außerhalb der Plug-in-Ordner"))
            #expect(fixture.remover.prepare(plugin(outside)) == .blocked("Außerhalb der Plug-in-Ordner"))
            #expect(fixture.remover.prepare(plugin(fixture.hal)) == .blocked("Kein Plug-in-Bundle"))
        }
    }

    @Test func refusesSymlinksHiddenAndForeignNames() async throws {
        try await withFixture { fixture in
            let target = try bundle("Real.driver", in: fixture.hal.deletingLastPathComponent())
            let link = fixture.hal.appending(path: "Link.driver")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let hidden = try bundle(".Hidden.driver", in: fixture.hal)
            let other = try bundle("Notes.txt", in: fixture.hal)
            #expect(fixture.remover.prepare(plugin(link)) == .blocked("Symbolischer Link"))
            #expect(fixture.remover.prepare(plugin(hidden)) == .blocked("Versteckter Eintrag"))
            #expect(fixture.remover.prepare(plugin(other)) == .blocked("Kein Plug-in-Bundle"))
        }
    }

    @Test func refusesForeignWritablePluginFolder() async throws {
        try await withFixture { fixture in
            let url = try bundle("Vendor.driver", in: fixture.hal)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.hal.path)
            #expect(fixture.remover.prepare(plugin(url)) == .blocked("Ordner fremd beschreibbar"))
        }
    }

    /// Ersetzt zwischen Bestätigung und Papierkorb: Der Finder bekommt den Ersatz nicht.
    @Test func refusesAReplacedEntryAfterConfirmation() async throws {
        try await withFixture { fixture in
            let url = try bundle("Vendor.driver", in: fixture.hal)
            let request = try request(fixture.remover, plugin(url))
            try FileManager.default.removeItem(at: url)
            _ = try bundle("Vendor.driver", in: fixture.hal)
            #expect(await fixture.remover.moveToTrash(request) == .notTrashed("Geändert seit der Bestätigung"))
            #expect(fixture.trash.movedPaths.isEmpty)
        }
    }

    /// Ohne Automation-Freigabe für den Finder geht nichts an ihn.
    @Test func stopsWithoutFinderPermission() async throws {
        try await withFixture { fixture in
            let url = try bundle("Vendor.driver", in: fixture.hal)
            let request = try request(fixture.remover, plugin(url))
            let denied = ServicePluginRemover(pathGuard: ServicePluginPathGuard(directories: [fixture.hal.path]),
                                              trash: UnavailableTrash())
            #expect(await denied.moveToTrash(request) == .notTrashed(UnavailableTrash.reason))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func reportsWhatTheFinderLeftBehind() async throws {
        try await withFixture { fixture in
            let url = try bundle("Vendor.driver", in: fixture.hal)
            let request = try request(fixture.remover, plugin(url))
            fixture.trash.force(.outcome(.remaining("Abgebrochen")), for: url.path)
            #expect(await fixture.remover.moveToTrash(request) == .notTrashed("Abgebrochen"))
        }
    }
}
