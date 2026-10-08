import Foundation
import Testing
import TestSupport
@testable import ManagerKit

@Suite struct ReceiptStoreTests {
    private let receipt = RemovalReceipt(
        label: "com.vendor.agent", backupPath: "/backups/1/LaunchAgents/com.vendor.agent.plist",
        isPrivileged: false, wasEnabled: true, wasLoaded: true
    )

    @Test func missingFileMeansNoReceipts() async throws {
        try await ScratchDirectory.withCanonical(prefix: "receipts") { directory in
            let receipts = try await ReceiptStore(url: directory.appending(path: "none/Receipts.json")).receipts()
            #expect(receipts.isEmpty)
        }
    }

    @Test func receiptsSurviveANewStoreInstance() async throws {
        try await ScratchDirectory.withCanonical(prefix: "receipts") { directory in
            let url = directory.appending(path: "Grantry/Receipts.json")
            let eventID = UUID()
            let older = try await ReceiptStore(url: url).add(receipt, label: "Agent", removedAt: TestData.date)
            let newer = try await ReceiptStore(url: url)
                .add(receipt, label: "Agent 2", removedAt: TestData.date.addingTimeInterval(60), for: eventID)

            let reloaded = try await ReceiptStore(url: url).receipts()
            #expect(reloaded == [newer, older])
            #expect(newer.eventID == eventID && newer.receipt == receipt && newer.label == "Agent 2")
            #expect(older.eventID == nil)
        }
    }

    @Test func removeDeletesOnlyThatEntryAndPersists() async throws {
        try await ScratchDirectory.withCanonical(prefix: "receipts") { directory in
            let url = directory.appending(path: "Receipts.json")
            let store = ReceiptStore(url: url)
            let first = try await store.add(receipt, label: "A", removedAt: TestData.date)
            let second = try await store.add(receipt, label: "B", removedAt: TestData.date)

            try await store.remove(id: first.id)

            #expect(try await store.entry(id: first.id) == nil)
            #expect(try await store.entry(id: second.id) == second)
            #expect(try await ReceiptStore(url: url).receipts() == [second])
        }
    }

    @Test func corruptFileIsReportedAndNotOverwritten() async throws {
        try await ScratchDirectory.withCanonical(prefix: "receipts") { directory in
            let url = directory.appending(path: "Receipts.json")
            try Data("kaputt".utf8).write(to: url)
            let store = ReceiptStore(url: url)

            await #expect(throws: ReceiptStoreError.self) { try await store.receipts() }
            await #expect(throws: ReceiptStoreError.self) { try await store.remove(id: UUID()) }
            #expect(try Data(contentsOf: url) == Data("kaputt".utf8))
        }
    }

    /// Ein neuer Beleg geht nicht verloren: Die unlesbare Datei wird unverändert beiseitegelegt, der Beleg in einer
    /// neuen Datei gespeichert.
    @Test func addSetsAnUnreadableFileAsideAndKeepsTheNewReceipt() async throws {
        try await ScratchDirectory.withCanonical(prefix: "receipts") { directory in
            let url = directory.appending(path: "Receipts.json")
            try Data("kaputt".utf8).write(to: url)

            let entry = try await ReceiptStore(url: url).add(receipt, label: "A", removedAt: TestData.date)

            #expect(try await ReceiptStore(url: url).receipts() == [entry])
            let setAside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("Receipts.unreadable-") && $0.hasSuffix(".json") }
            #expect(setAside.count == 1)
            let preserved = try setAside.first.map { try Data(contentsOf: directory.appending(path: $0)) }
            #expect(preserved == Data("kaputt".utf8))
        }
    }

    @Test func defaultLocationIsInApplicationSupport() {
        #expect(ReceiptStore.defaultURL.path.hasSuffix("Library/Application Support/Grantry/Receipts.json"))
    }
}
