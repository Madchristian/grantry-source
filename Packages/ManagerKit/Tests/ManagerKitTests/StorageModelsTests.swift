import Foundation
import Testing
@testable import ManagerKit

@Suite struct StorageModelsTests {
    private static let category = StorageCategory(id: "derivedData", title: "Xcode DerivedData", summary: "",
                                                  risk: .low, roots: ["/x"])

    private func item(_ size: FileSize) -> StorageItem {
        StorageItem(id: UUID().uuidString, title: "a", path: nil, size: size, removal: .delete, isPreselected: true)
    }

    @Test func totalCountsKnownBytesAndMarksGaps() {
        let report = StorageCategoryReport(category: Self.category, status: .available,
                                           items: [item(.bytes(1_000)), item(.bytes(500)), item(.unknown)])
        #expect(report.size.known == 1_500)
        #expect(report.size.unknown == 1)
        #expect(report.size.text.hasPrefix("mindestens"))
    }

    @Test func itemSizeText() {
        #expect(item(.unreadable).sizeText == "Größe nicht lesbar")
        #expect(item(.unknown).sizeText == "Größe unbekannt")
    }

    @Test func commandLineJoinsExecutableAndArguments() {
        #expect(CommandSpec(executable: "/opt/homebrew/bin/uv", arguments: ["cache", "prune"]).commandLine
                == "/opt/homebrew/bin/uv cache prune")
    }

    @Test func outcomeRoundTripsThroughJSON() throws {
        let outcome = StorageCleanOutcome(categoryID: "uv", target: "uv cache prune", method: .command,
                                          freedBytes: 42, result: .failed("Exit 1"))
        let decoded = try JSONDecoder().decode(StorageCleanOutcome.self, from: JSONEncoder().encode(outcome))
        #expect(decoded == outcome)
    }
}
