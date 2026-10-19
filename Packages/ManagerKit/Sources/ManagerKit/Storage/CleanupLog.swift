import Foundation

/// Eine Zeile des Protokolls.
public struct CleanupLogEntry: Hashable, Sendable, Codable {
    public let date: Date
    public let outcome: StorageCleanOutcome

    public init(date: Date, outcome: StorageCleanOutcome) {
        self.date = date
        self.outcome = outcome
    }
}

/// Ergebnisprotokoll des Speicher-Aufräumens als JSONL (eine Zeile je Ausgang), auf die neuesten `maximumEntries`
/// begrenzt. Beschädigte Zeilen werden beim Lesen übersprungen und beim nächsten Schreiben verworfen.
///
/// Die Datei nennt Pfade entfernter Benutzerdaten und ist daher privat wie die Belege (#141): Sie entsteht im privaten
/// Ordner (`PrivateDirectory`, `0700`) als vertrauliche Datei mit `0600` (`PrivateFile.writeAtomically`); eine ältere
/// mit weiteren Rechten ersetzt das nächste Schreiben.
public struct CleanupLog: Sendable {
    public static let defaultMaximumEntries = 500

    public let url: URL
    let maximumEntries: Int

    public init(url: URL, maximumEntries: Int = defaultMaximumEntries) {
        self.url = url
        self.maximumEntries = maximumEntries
    }

    public func read() -> [CleanupLogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(CleanupLogEntry.self, from: Data($0)) }
    }

    public func append(_ outcomes: [StorageCleanOutcome], at date: Date) throws {
        let entries = (read() + outcomes.map { CleanupLogEntry(date: date, outcome: $0) }).suffix(maximumEntries)
        let encoder = JSONEncoder()
        var bytes: [UInt8] = []
        for entry in entries {
            bytes.append(contentsOf: try encoder.encode(entry))
            bytes.append(UInt8(ascii: "\n"))
        }
        let directory = try PrivateDirectory(at: url.deletingLastPathComponent())
        try PrivateFile.writeAtomically(bytes, named: url.lastPathComponent, in: directory.bound)
    }
}
