import Foundation
import GrantryShared
import IOKit.kext

/// Geladene Kernel-Erweiterungen über `KextManagerCopyLoadedKextInfo` (öffentliche IOKit-API, ohne Root). Der Aufruf
/// läuft auf `ExtensionWork.queue` mit Frist (`ExtensionWork.kernelGuard`).
struct KextManagerLoadedProvider: LoadedKernelExtensionProviding {
    private static let infoKeys = ["CFBundleIdentifier", "CFBundleVersion", "OSBundlePath", "OSKernelResource"]

    func loadedExtensions() async throws -> LoadedKernelExtensions {
        let records = await ExtensionWork.queue.run {
            ExtensionWork.kernelGuard.run(timeout: ExtensionWork.timeout) { Self.copyLoadedRecords() } ?? nil
        }
        guard let records else {
            throw ExtensionReadError.unavailable("KextManagerCopyLoadedKextInfo lieferte keine Liste")
        }
        return LoadedKernelExtensions(records: records, source: .kextManager)
    }

    private static func copyLoadedRecords() -> [LoadedKernelExtensionRecord]? {
        guard let info = KextManagerCopyLoadedKextInfo(nil, infoKeys as CFArray)?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return records(from: info)
    }

    /// Je Eintrag mit Bundle-ID ein Datensatz; andere Werte werden übersprungen.
    static func records(from info: [String: Any]) -> [LoadedKernelExtensionRecord] {
        info.values.compactMap { value in
            guard let entry = value as? [String: Any], let bundleID = entry["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else { return nil }
            return LoadedKernelExtensionRecord(
                bundleID: ExtensionText.identifier(bundleID),
                version: (entry["CFBundleVersion"] as? String).map(ExtensionText.version),
                path: entry["OSBundlePath"] as? String,
                isKernelResource: (entry["OSKernelResource"] as? Bool) ?? false
            )
        }
    }
}

/// Rückfall über `kmutil showloaded` (ohne Root), wenn IOKit nichts liefert.
struct KmutilLoadedProvider: LoadedKernelExtensionProviding {
    static let command = ExtensionCommand(
        executable: "/usr/bin/kmutil", arguments: ["showloaded"], timeout: .seconds(10), outputLimit: 4 << 20
    )

    let runner: any CommandRunning

    func loadedExtensions() async throws -> LoadedKernelExtensions {
        try await Self.command.run(with: runner, parse: KmutilShowloadedParser.parse)
    }
}

/// Liest `kmutil showloaded`: Kopf `Index Refs Address Size Wired Name (Version) UUID <Linked Against>`, danach je
/// Erweiterung eine Zeile. Getrennt wird an Leerraum, nicht an Spaltenbreiten; Name ist das Feld vor der ersten
/// Klammer `(Version)`. Ohne Ladeadresse (`0`) ist es ein Bestandteil des Kerns. Einen Pfad nennt `kmutil` nicht.
enum KmutilShowloadedParser {
    /// Ohne Kopfzeile ist das Format unbekannt.
    struct FormatError: Error, Equatable {}

    private static let headerPrefix = "Index "

    static func parse(_ output: String) throws -> LoadedKernelExtensions {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let header = lines.firstIndex(where: { $0.hasPrefix(headerPrefix) }) else { throw FormatError() }
        var records: [LoadedKernelExtensionRecord] = []
        var unreadable = 0
        for line in lines[(header + 1)...] where !line.allSatisfy(\.isWhitespace) {
            if let record = record(in: line) { records.append(record) } else { unreadable += 1 }
        }
        return LoadedKernelExtensions(records: records, source: .kmutil, unreadableLineCount: unreadable)
    }

    private static func record(in line: Substring) -> LoadedKernelExtensionRecord? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4, Int(fields[0]) != nil, Int(fields[1]) != nil,
              let versionIndex = fields.indices.dropFirst(3).first(where: { isParenthesized(fields[$0]) }) else {
            return nil
        }
        let version = fields[versionIndex].dropFirst().dropLast()
        return LoadedKernelExtensionRecord(
            bundleID: ExtensionText.identifier(String(fields[versionIndex - 1])),
            version: ExtensionText.version(String(version)),
            path: nil,
            isKernelResource: fields[2] == "0"
        )
    }

    private static func isParenthesized(_ field: Substring) -> Bool {
        field.count >= 2 && field.hasPrefix("(") && field.hasSuffix(")")
    }
}
