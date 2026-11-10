import Foundation
import GrantryShared

/// Fehler beim Lesen von System- und Kernel-Erweiterungen.
public enum ExtensionReadError: LocalizedError, Equatable {
    /// Der Befehl lieferte eine Ausgabe in unbekanntem Format. Als leere Liste gewertet, würde sie jede bekannte
    /// Erweiterung scheinbar entfernen.
    case unparseableOutput(command: String)
    /// Der Befehl scheiterte und seine Ausgabe war nicht auswertbar.
    case commandFailed(command: String, exitCode: Int32, detail: String)
    /// Eine Systemschnittstelle lieferte nichts (oder nicht rechtzeitig).
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unparseableOutput(let command): "Erweiterungen nicht lesbar: unerwartetes Ausgabeformat von \(command)"
        case .commandFailed(let command, let exitCode, let detail):
            "\(command) fehlgeschlagen (Exit \(exitCode))" + (detail.isEmpty ? "" : ": \(detail)")
        case .unavailable(let detail): "Erweiterungen nicht lesbar: \(detail)"
        }
    }
}

/// Ein fester, lesender Befehl ohne Root mit Zeit- und Ausgabegrenze. Zuerst zählt `stdout` – manche Werkzeuge melden
/// mit Exit ≠ 0 trotzdem eine lesbare Liste –; erst wenn das Lesen scheitert, entscheidet der Exit-Code über den Fehler.
struct ExtensionCommand: Sendable {
    static let maximumDetailLength = 200

    let executable: String
    let arguments: [String]
    let timeout: Duration
    let outputLimit: Int

    /// Kurzform für Meldungen (`systemextensionsctl list`).
    var displayName: String { ([URL(filePath: executable).lastPathComponent] + arguments).joined(separator: " ") }

    func run<T>(with runner: any CommandRunning, parse: (String) throws -> T) async throws -> T {
        let result = try await runner.run(executable, arguments, timeout: timeout, outputLimit: outputLimit)
        do {
            return try parse(result.stdout)
        } catch {
            guard result.succeeded else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = DisplayText.singleLine(stderr.isEmpty ? result.stdout : stderr, maximumLength: Self.maximumDetailLength)
                throw ExtensionReadError.commandFailed(command: displayName, exitCode: result.exitCode, detail: detail)
            }
            throw ExtensionReadError.unparseableOutput(command: displayName)
        }
    }
}

/// Fremde Texte der Erweiterungen (Namen, Kennungen, Versionen) einzeilig und mit Längengrenze (`DisplayText`).
enum ExtensionText {
    static let maximumNameLength = 120
    static let maximumIdentifierLength = 255
    static let maximumVersionLength = 64

    static func name(_ text: String) -> String { DisplayText.singleLine(text, maximumLength: maximumNameLength) }
    static func identifier(_ text: String) -> String { DisplayText.singleLine(text, maximumLength: maximumIdentifierLength) }
    static func version(_ text: String) -> String { DisplayText.singleLine(text, maximumLength: maximumVersionLength) }
}

/// Gemeinsame Auslagerung für synchrone Systemabfragen der Erweiterungen (IOKit, Dateisystem, Signatur): eine serielle
/// Queue mit QoS `utility`, je Art ein eigener `BlockingCallGuard`, damit ein hängender Aufruf die andere Art nicht
/// mitblockiert.
enum ExtensionWork {
    static let queue = BlockingWorkQueue(label: "extensions")
    /// `KextManagerCopyLoadedKextInfo` (Mach-Aufruf an den Kern).
    static let kernelGuard = BlockingCallGuard(maximumHanging: 1)
    /// Ordner und Info.plists der installierten Erweiterungen samt Signaturprüfung.
    static let fileSystemGuard = BlockingCallGuard(maximumHanging: 1)
    /// Frist je Auftrag; üblich sind Millisekunden.
    static let timeout: Duration = .seconds(5)
}
