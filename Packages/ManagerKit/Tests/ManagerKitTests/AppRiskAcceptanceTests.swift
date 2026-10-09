import Foundation
import Testing
import TestSupport
@testable import ManagerKit

struct AppRiskAcceptanceTests {
    @Test func acceptanceSurvivesRestartAndVersionUpdateButCanBeRevoked() throws {
        try ScratchDirectory.withCanonical { directory in
            let url = directory.appending(path: "accepted.json")
            var store = AppRiskAcceptanceStore(url: url)
            var app = TestData.installedApp()
            try store.setAccepted(true, for: app)
            app.shortVersion = "7.0"
            app.buildVersion = "700"
            var restarted = AppRiskAcceptanceStore(url: url)
            #expect(try restarted.acceptedIDs(in: [app]) == [app.id])
            try restarted.setAccepted(false, for: app)
            var afterRevocation = AppRiskAcceptanceStore(url: url)
            #expect(try afterRevocation.acceptedIDs(in: [app]).isEmpty)
        }
    }

    @Test func developerChangePermanentlyRevokesAcceptance() throws {
        var store = AppRiskAcceptanceStore()
        let original = TestData.installedApp()
        try store.setAccepted(true, for: original)
        var changed = original
        changed.signing.teamID = "OTHERTEAM"
        #expect(try store.acceptedIDs(in: [changed]).isEmpty)
        #expect(try store.acceptedIDs(in: [original]).isEmpty)
    }

    @Test func identityAndSignatureChangesDoNotInheritAcceptance() throws {
        let original = TestData.installedApp()
        var variants = [original, original, original]
        variants[0].path = "/Applications/Copy.app"
        variants[1].bundleID = "other.app"
        variants[2].signing = SigningInfo(kind: .unsigned)
        for changed in variants {
            var store = AppRiskAcceptanceStore()
            try store.setAccepted(true, for: original)
            #expect(try store.acceptedIDs(in: [changed]).isEmpty)
        }
    }

    @Test func unsignedAppsCanBeAccepted() throws {
        var store = AppRiskAcceptanceStore()
        let app = TestData.installedApp(signing: SigningInfo(kind: .adHoc))
        try store.setAccepted(true, for: app)
        #expect(try store.acceptedIDs(in: [app]) == [app.id])
    }

    @Test func failedWriteDoesNotAcceptAppInMemory() throws {
        try ScratchDirectory.withCanonical { directory in
            let url = directory.appending(path: "accepted.json")
            var store = AppRiskAcceptanceStore(url: url)
            let app = TestData.installedApp()
            #expect(try !store.isAccepted(app))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try store.setAccepted(true, for: app) }
            #expect(try !store.isAccepted(app))
        }
    }

    @Test func unreadableStorageIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "accepted.json")
        let original = Data("broken".utf8)
        try original.write(to: url)
        var store = AppRiskAcceptanceStore(url: url)
        #expect(throws: (any Error).self) { try store.setAccepted(true, for: TestData.installedApp()) }
        #expect(try Data(contentsOf: url) == original)
    }
}
