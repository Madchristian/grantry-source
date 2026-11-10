import Foundation
import Testing
@testable import ManagerKit

/// Abnahmekriterium 2 von #401: synthetischer Baum mit 100 000 Dateien. Die Grenzen sind großzügig (#214); die Werte
/// stehen in der Testausgabe („Belegung: …“), belegt mit `swift test -c release --filter OccupancyPerformance`.
@Suite(.serialized) struct OccupancyPerformanceTests {
    /// 20 × 25 × 10 Blattordner mit je 20 Dateien: Jede Datei landet in einer Liste der größten Dateien – der
    /// ungünstigste Fall für den Speicher.
    static func syntheticTree() -> FakeOccupancyFileSystem {
        let fileSystem = FakeOccupancyFileSystem()
        var index = 0
        for top in 0..<20 {
            for middle in 0..<25 {
                for leaf in 0..<10 {
                    let folder = "Projekt-\(top)/Modul-\(middle)-Quellen/Paket-\(leaf)-Ressourcen"
                    for file in 0..<20 {
                        index += 1
                        fileSystem.addFile("\(folder)/Datei-\(file)-\(index)-beispiel.dat", bytes: Int64(4_096 * (1 + index % 7)))
                    }
                }
            }
        }
        return fileSystem
    }

    @Test func scansOneHundredThousandFilesWithinBudget() async throws {
        let fileSystem = Self.syntheticTree()
        let scanner = OccupancyScanner.testing(fileSystem)
        let start = ContinuousClock.now
        let tree = try await scanner.scan(fileSystem.rootPath)
        let elapsed = ContinuousClock.now - start

        #expect(tree.root.fileCount == 100_000)
        #expect(tree.folderCount == 1 + 20 + 500 + 5_000)
        let memory = tree.estimatedMemory
        let bytesPerFile = Double(memory) / 100_000
        print("Belegung: 100 000 Dateien in \(tree.folderCount) Ordnern: \(elapsed), Speicher geschätzt \(memory / 1_000) kB (\(Int(bytesPerFile)) Byte je Datei)")
        // Spec § 4.4: höchstens 150 MB je 1 Mio. Dateien.
        #expect(bytesPerFile <= 150)
        #if DEBUG
        #expect(elapsed < .seconds(120))
        #else
        #expect(elapsed < .seconds(20))
        #endif
    }

    /// Erneuter Scan ohne Änderungen: nichts lesen, nur das Ergebnis neu zusammensetzen.
    @Test func rescanWithoutChangesIsCheap() async throws {
        let fileSystem = Self.syntheticTree()
        let scanner = OccupancyScanner.testing(fileSystem)
        let first = try await scanner.scan(fileSystem.rootPath)
        fileSystem.resetReads()
        let start = ContinuousClock.now
        let second = try await scanner.scan(fileSystem.rootPath, reusing: first)
        let elapsed = ContinuousClock.now - start
        print("Belegung: erneuter Scan ohne Änderungen: \(elapsed)")
        #expect(fileSystem.reads.isEmpty)
        #expect(second.root.allocatedBytes == first.root.allocatedBytes)
        #expect(elapsed < .seconds(30))
    }
}
