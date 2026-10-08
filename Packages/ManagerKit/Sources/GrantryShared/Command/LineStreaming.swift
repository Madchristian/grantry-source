import Foundation

/// Langlebiger Befehl, dessen stdout zeilenweise verarbeitet wird (`nettop -L 0`), in Tests ersetzbar. Neben
/// `CommandRunning`, das auf das Ende wartet und die ganze Ausgabe liefert.
public protocol LineStreaming: Sendable {
    /// Startet `executable` und ruft `onLine` für jede Zeile von stdout (ohne Zeilenende) in Reihenfolge auf, bis der
    /// Prozess endet; liefert dann seinen Exit-Status.
    ///
    /// Wirft `onLine` oder wird der Task abgebrochen, wird der Prozess beendet (SIGTERM, nach der Gnadenfrist SIGKILL)
    /// und erst nach seinem Ende der Fehler bzw. `CancellationError` geworfen – es bleibt kein Prozess zurück.
    /// Startet er nicht, wirft der Aufruf `CommandError.launchFailed`.
    func run(_ executable: String, _ arguments: [String], onLine: @Sendable (String) throws -> Void) async throws -> Int32
}

/// Zerlegt Byteblöcke in Zeilen (`\n`); unvollständige Zeilen warten auf den nächsten Block. Eine Zeile über
/// `maximumLineLength` Bytes wird genau dort abgeschnitten und weitergegeben, der Rest bildet die nächste Zeile – so füllt
/// eine Ausgabe ohne Zeilenende den Speicher nicht.
struct LineSplitter {
    static let maximumLineLength = 1 << 20

    private var buffer = Data()

    /// Liefert alle in `chunk` abgeschlossenen Zeilen. Der Puffer wird einmal je Block gekürzt, nicht je Zeile.
    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        var start = buffer.startIndex
        while start < buffer.endIndex {
            // Bis einschließlich Position `limit` suchen: Eine Zeile mit genau `maximumLineLength` Bytes bleibt ganz.
            let limit = start + Self.maximumLineLength
            if let newline = buffer[start..<min(buffer.endIndex, limit + 1)].firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[start..<newline], as: UTF8.self))
                start = newline + 1
            } else if buffer.endIndex > limit {
                lines.append(String(decoding: buffer[start..<limit], as: UTF8.self))
                start = limit
            } else {
                break
            }
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        return lines
    }

    /// Rest ohne abschließendes Zeilenende, falls vorhanden.
    mutating func finish() -> String? {
        defer { buffer.removeAll() }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}
