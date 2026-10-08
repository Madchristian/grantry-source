import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct FullDiskAccessProbeTests {
    @Test func unopenableDatabaseMeansNoAccess() async throws {
        try await ScratchDirectory.with(prefix: "fda") { directory in
            let probe = FullDiskAccessProbe(databasePath: directory.appending(path: "fehlt/TCC.db").path)
            #expect(await probe.hasFullDiskAccess() == false)
        }
    }

    @Test func readableDatabaseMeansAccess() async throws {
        try await SQLiteFixture.withDatabase([SQLiteFixture.currentAccessSchema]) { path in
            #expect(await FullDiskAccessProbe(databasePath: path).hasFullDiskAccess())
        }
    }

    /// Geöffnet, aber mit unerwartetem Schema: Der Zugriff selbst ist gewährt.
    @Test func openableDatabaseWithUnexpectedSchemaMeansAccess() async throws {
        try await SQLiteFixture.withDatabase(["CREATE TABLE other (x INTEGER);"]) { path in
            #expect(await FullDiskAccessProbe(databasePath: path).hasFullDiskAccess())
        }
    }

    @Test func defaultsToSystemDatabaseAndOpensAllFilesSettings() {
        #expect(FullDiskAccessProbe().databasePath == TCCDatabaseLocation.system.path)
        #expect(
            FullDiskAccessProbe.settingsURL?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }
}
