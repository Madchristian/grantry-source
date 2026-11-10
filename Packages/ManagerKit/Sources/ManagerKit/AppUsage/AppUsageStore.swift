import Foundation
import GrantryShared

/// Warum `AppUsageStore.load()` keinen Verlauf liefert, obwohl eine Datei da ist (#353).
public enum AppUsageLoadProblem: LocalizedError, Equatable, Sendable {
    /// Die Datei war nicht lesbar und liegt jetzt unter `name` im selben Ordner; der Verlauf beginnt neu.
    case setAside(name: String)
    /// Die Datei war nicht lesbar und ließ sich nicht beiseitelegen; sie darf nicht überschrieben werden.
    case unreadable(reason: String)

    public var errorDescription: String? {
        switch self {
        case .setAside(let name):
            "Die bisherige Verlaufsdatei war nicht lesbar und wurde als „\(name)“ beiseitegelegt. Der Verlauf beginnt neu."
        case .unreadable(let reason):
            "Die Verlaufsdatei ist nicht lesbar (\(reason)) und ließ sich nicht beiseitelegen. Der Verlauf wird erst "
                + "nach „Verlauf löschen“ wieder gespeichert."
        }
    }

    /// Ob weiteres Speichern die vorgefundene Datei ersetzen würde.
    public var blocksWriting: Bool {
        if case .unreadable = self { true } else { false }
    }
}

/// Datei des App-Verlaufs im privaten Ordner der App – wie `CleanupLog`: Ordner `0700` (`PrivateDirectory`), Datei
/// `0600`, atomar ersetzt (`PrivateFile.writeAtomically`). Inhalt: nur Summen je App bzw. eigenem Programm und Stunde,
/// nie Befehlszeilen.
///
/// Eine unlesbare Fassung (beschädigt, unbekannte Version, keine Leserechte) wird nicht still ersetzt (#353): `load()`
/// benennt sie in `<Name>.unreadable-<Zeitpunkt>.json` um und meldet das. Solche Fassungen fallen wie der Verlauf nach
/// 30 Tagen weg (`save()`) und mit „Verlauf löschen“ (`remove()`).
///
/// Das atomare Schreiben legt kurz eine versteckte Nachbardatei an (`.<Name>.<UUID>`). Bricht die App dabei ab, bliebe
/// sie mit einer Kopie der Daten zurück; `save()` und `remove()` räumen solche Reste ab.
public struct AppUsageStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Nur eine Existenzprüfung, ohne die Datei zu lesen (für die Aufbewahrungsprüfung ohne Verlauf).
    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Der gespeicherte Verlauf; ohne Datei ein leerer.
    /// - Throws: nur `AppUsageLoadProblem`, wenn die Datei nicht lesbar war – der Verlauf beginnt dann leer.
    public func load() throws -> AppUsageHistory {
        do {
            return try AppUsageHistory.decode(Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return AppUsageHistory()
        } catch {
            throw setAside(unreadableBecause: error)
        }
    }

    public func save(_ history: AppUsageHistory) throws {
        let directory = try PrivateDirectory(at: url.deletingLastPathComponent())
        try? removeLeftovers()
        try? removeSetAsideCopies(modifiedBefore: Date().addingTimeInterval(-AppUsageHistory.retention))
        try PrivateFile.writeAtomically(Array(try history.encoded()), named: url.lastPathComponent, in: directory.bound)
    }

    /// „Verlauf löschen“: Datei und Reste unterbrochener Schreibvorgänge; eine fehlende Datei ist kein Fehler.
    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Nichts zu löschen; Reste können trotzdem da sein.
        }
        try removeLeftovers()
        try removeSetAsideCopies(modifiedBefore: .distantFuture)
    }

    private var setAsidePrefix: String {
        "\(url.deletingPathExtension().lastPathComponent).unreadable-"
    }

    /// Benennt die unlesbare Datei um, ohne eine vorhandene zu ersetzen (`moveItem` schlägt dann fehl).
    private func setAside(unreadableBecause error: any Error) -> AppUsageLoadProblem {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).dateSeparator(.omitted))
        let name = "\(setAsidePrefix)\(stamp).\(url.pathExtension)"
        do {
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appending(path: name))
            return .setAside(name: name)
        } catch {
            return .unreadable(reason: error.readableDescription)
        }
    }

    /// Entfernt beiseitegelegte Fassungen, die zuletzt vor `date` geändert wurden.
    private func removeSetAsideCopies(modifiedBefore date: Date) throws {
        let folder = url.deletingLastPathComponent()
        for name in try entries(of: folder) where name.hasPrefix(setAsidePrefix) {
            let copy = folder.appending(path: name)
            let modified = try? FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date
            if modified.map({ $0 < date }) ?? true {
                try FileManager.default.removeItem(at: copy)
            }
        }
    }

    /// Namen im Ordner; ein fehlender Ordner hat keine.
    private func entries(of folder: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
    }

    /// Entfernt versteckte Zwischendateien des atomaren Schreibens (nur mit dem Namensmuster dieser Datei).
    private func removeLeftovers() throws {
        let folder = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent)."
        for name in try entries(of: folder) where name.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}
