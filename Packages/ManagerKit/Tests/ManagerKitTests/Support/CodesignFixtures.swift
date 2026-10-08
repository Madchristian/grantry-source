import Foundation

/// Ruft `/usr/bin/codesign` synchron auf – zum Erzeugen von Signatur-Fixtures und als unabhängige Referenz
/// für die Ergebnisse von `SecuritySigningInspector`.
enum Codesign {
    struct Failure: Error {
        let arguments: [String]
        let output: String
    }

    /// Kleines, universelles Apple-Binary als Rohmaterial für Fixtures.
    static let sourceBinary = URL(fileURLWithPath: "/usr/bin/true")

    /// Führt `codesign` mit `arguments` aus; liefert stdout und stderr gemeinsam, wirft bei Exit-Code ungleich 0.
    @discardableResult
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(arguments: arguments, output: output) }
        return output
    }

    /// Kopiert `sourceBinary` nach `directory/name` und entfernt die Signatur vollständig.
    static func unsignedBinary(in directory: URL, named name: String = "unsigned") throws -> URL {
        let binary = directory.appending(path: name)
        try FileManager.default.copyItem(at: sourceBinary, to: binary)
        try run(["--remove-signature", binary.path])
        return binary
    }

    /// Kopiert `sourceBinary` nach `directory/name` und signiert es ad hoc (`codesign -s -`).
    static func adHocBinary(in directory: URL, named name: String = "adhoc") throws -> URL {
        let binary = try unsignedBinary(in: directory, named: name)
        try run(["--force", "--sign", "-", binary.path])
        return binary
    }

    /// Legt ein minimales App-Bundle `directory/name.app` mit unsigniertem Hauptprogramm und den Dateien
    /// `resources` (Name → Inhalt) in `Contents/Resources` an. Mit `adHoc` wird das Bundle anschließend ad hoc
    /// signiert; die Ressourcen sind dann versiegelt.
    static func bundle(
        in directory: URL, named name: String, adHoc: Bool, resources: [String: String] = [:]
    ) throws -> URL {
        let bundle = directory.appending(path: "\(name).app")
        let executables = bundle.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        _ = try unsignedBinary(in: executables, named: name)
        if !resources.isEmpty {
            let folder = bundle.appending(path: "Contents/Resources")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, content) in resources {
                try Data(content.utf8).write(to: folder.appending(path: file))
            }
        }
        let plist: [String: Any] = [
            "CFBundleExecutable": name,
            "CFBundleIdentifier": "de.cstrube.Grantry.tests.\(name)",
            "CFBundlePackageType": "APPL",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: bundle.appending(path: "Contents/Info.plist"))
        if adHoc {
            try run(["--force", "--sign", "-", bundle.path])
        }
        return bundle
    }

    /// Ad-hoc signiertes Bundle, dessen versiegelte Ressource danach überschrieben wurde – wie eine App, die in ihr
    /// eigenes Bundle schreibt, oder eine manipulierte App.
    static func tamperedBundle(in directory: URL, named name: String) throws -> URL {
        let bundle = try Self.bundle(in: directory, named: name, adHoc: true, resources: ["config.txt": "original"])
        try Data("verändert".utf8).write(to: bundle.appending(path: "Contents/Resources/config.txt"))
        return bundle
    }
}

/// Referenz-Apps aus `/Applications`, über `codesign -dvv` klassifiziert. `nil`, wenn keine passende App installiert ist –
/// abhängige Tests werden dann übersprungen.
enum InstalledApps {
    struct App: Sendable {
        let path: String
        let teamID: String?
        /// Oberste `Authority`-Zeile von `codesign -dvv` (Name des Blattzertifikats).
        var authority: String? = nil

        /// Ein angeheftetes Notarisierungsticket liegt als `Contents/CodeResources` neben `Info.plist`.
        var hasStapledTicket: Bool {
            FileManager.default.fileExists(atPath: path + "/Contents/CodeResources")
        }
    }

    static let developerID = first(withAuthorityPrefix: "Developer ID Application:")
    static let appStore = first(withAuthorityPrefix: "Apple Mac OS Application Signing")
    /// Lokaler Entwickler-Build, z. B. ein Debug-Build von Grantry.
    static let development = first(withAuthorityPrefix: "Apple Development:")
    /// iOS-/iPadOS-App aus dem App Store, auf Apple Silicon als Wrapper-Bundle installiert.
    static let iOSAppStore = first(withAuthorityPrefix: "Apple iPhone OS Application Signing", containing: "Wrapper")

    /// Erste App (alphabetisch), deren oberste `Authority`-Zeile mit `prefix` beginnt; mit `subpath` werden nur
    /// Bundles betrachtet, die diesen Unterpfad enthalten.
    private static func first(withAuthorityPrefix prefix: String, containing subpath: String? = nil) -> App? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        for name in names.sorted() where name.hasSuffix(".app") {
            let path = "/Applications/\(name)"
            if let subpath, !FileManager.default.fileExists(atPath: "\(path)/\(subpath)") { continue }
            guard let fields = try? fields(of: Codesign.run(["-dvv", path])),
                  fields["Authority"]?.hasPrefix(prefix) == true else { continue }
            let teamID = fields["TeamIdentifier"].flatMap { $0 == "not set" ? nil : $0 }
            return App(path: path, teamID: teamID, authority: fields["Authority"])
        }
        return nil
    }

    /// Zerlegt `Schlüssel=Wert`-Zeilen; bei mehrfachen Schlüsseln (z. B. `Authority`) zählt die erste Zeile.
    private static func fields(of description: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in description.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            if fields[key] == nil {
                fields[key] = String(line[line.index(after: separator)...])
            }
        }
        return fields
    }
}
