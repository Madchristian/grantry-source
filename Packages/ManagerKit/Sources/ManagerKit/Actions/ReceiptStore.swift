import Foundation
import GrantryShared
import os

/// Ein gespeicherter Wiederherstellungsbeleg.
public struct ReceiptEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let receipt: RemovalReceipt
    /// Anzeigename des entfernten Eintrags.
    public let label: String
    public let removedAt: Date
    /// Zugehöriges Verlaufs-Event, falls bekannt.
    public let eventID: UUID?

    public init(id: UUID, receipt: RemovalReceipt, label: String, removedAt: Date, eventID: UUID?) {
        self.id = id
        self.receipt = receipt
        self.label = label
        self.removedAt = removedAt
        self.eventID = eventID
    }
}

/// Fehler der Beleg-Ablage.
public enum ReceiptStoreError: LocalizedError, Equatable {
    case unreadable(String)
    case unwritable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): "Wiederherstellungsbelege nicht lesbar: \(detail)"
        case .unwritable(let detail): "Wiederherstellungsbeleg nicht gespeichert: \(detail)"
        }
    }
}

/// Wiederherstellungsbelege entfernter Autostart-Einträge als JSON-Datei (Standard:
/// `~/Library/Application Support/Grantry/Receipts.json`), jede Änderung atomar geschrieben.
///
/// Die Datei ist privat (#141): Sie entsteht im privaten Ordner (`PrivateDirectory`, `0700`, symlinkfreier Pfad) als
/// vertrauliche Datei mit `0600` (`PrivateFile.writeAtomically`). Eine von einer älteren Version mit `0644` geschriebene
/// Datei härtet der Start (`StorageLocation.openPrivately`), spätestens das nächste Schreiben ersetzt sie.
///
/// Die Datei wird beim ersten Zugriff gelesen; eine fehlende Datei heißt „keine Belege“. Eine unlesbare Datei wird
/// gemeldet (`ReceiptStoreError.unreadable`) und nie überschrieben, damit keine Belege verloren gehen. Kommt trotzdem
/// ein neuer Beleg (`add`), wird sie unverändert daneben beiseitegelegt (`Receipts.unreadable-<Zeitstempel>.json`)
/// und der Beleg in einer neuen Datei gespeichert – sonst ginge er verloren, und mit ihm die Möglichkeit, den
/// entfernten Eintrag wiederherzustellen. Scheitert das Schreiben, bleibt die Änderung im Speicher erhalten und wird
/// mit dem nächsten erfolgreichen Schreiben gesichert.
public actor ReceiptStore {
    private static let logger = Logger(subsystem: ManagerKit.logSubsystem, category: "receipts")

    private let url: URL
    /// Belege im Speicher; `nil`, bis die Datei gelesen ist.
    private var entries: [ReceiptEntry]?

    public init(url: URL = ReceiptStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        StorageLocation.standard.receiptsURL
    }

    /// Alle Belege, neueste zuerst.
    public func receipts() throws -> [ReceiptEntry] {
        try loaded().sorted { $0.removedAt > $1.removedAt }
    }

    public func entry(id: UUID) throws -> ReceiptEntry? {
        try loaded().first { $0.id == id }
    }

    /// Speichert einen neuen Beleg.
    @discardableResult
    public func add(_ receipt: RemovalReceipt, label: String, removedAt: Date, for eventID: UUID? = nil) throws -> ReceiptEntry {
        let entry = ReceiptEntry(id: UUID(), receipt: receipt, label: label, removedAt: removedAt, eventID: eventID)
        try update(settingAsideUnreadableFile: true) { $0.append(entry) }
        return entry
    }

    /// Entfernt den Beleg mit `id`; ein unbekannter ist kein Fehler.
    public func remove(id: UUID) throws {
        try update { $0.removeAll { $0.id == id } }
    }

    private func loaded() throws -> [ReceiptEntry] {
        if let entries { return entries }
        let loaded: [ReceiptEntry]
        do {
            loaded = try JSONDecoder().decode([ReceiptEntry].self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            loaded = []
        } catch {
            throw ReceiptStoreError.unreadable(error.readableDescription)
        }
        entries = loaded
        return loaded
    }

    /// Wendet `change` an und schreibt das Ergebnis. Mit `settingAsideUnreadableFile` wird eine unlesbare Datei
    /// beiseitegelegt und mit einer leeren Liste begonnen, statt abzubrechen.
    private func update(settingAsideUnreadableFile: Bool = false, _ change: (inout [ReceiptEntry]) -> Void) throws {
        var updated: [ReceiptEntry]
        do {
            updated = try loaded()
        } catch ReceiptStoreError.unreadable(let detail) where settingAsideUnreadableFile {
            try setAsideUnreadableFile(detail: detail)
            updated = []
        }
        change(&updated)
        entries = updated
        do {
            let directory = try PrivateDirectory(at: url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try PrivateFile.writeAtomically(Array(try encoder.encode(updated)), named: url.lastPathComponent, in: directory.bound)
        } catch {
            throw ReceiptStoreError.unwritable(error.readableDescription)
        }
    }

    /// Benennt die unlesbare Datei eindeutig um (`<Name>.unreadable-<Zeitstempel>-<Kennung>.json`); ihr Inhalt
    /// bleibt unverändert erhalten.
    private func setAsideUnreadableFile(detail: String) throws {
        let stamp = Date.now.formatted(.iso8601.dateSeparator(.omitted).timeSeparator(.omitted))
        let name = url.deletingPathExtension().lastPathComponent
        let setAside = url.deletingLastPathComponent()
            .appending(path: "\(name).unreadable-\(stamp)-\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
        do {
            try FileManager.default.moveItem(at: url, to: setAside)
        } catch {
            throw ReceiptStoreError.unwritable("Unlesbare Belegdatei ließ sich nicht beiseitelegen: \(error.readableDescription)")
        }
        Self.logger.error("Unlesbare Belegdatei beiseitegelegt (\(detail, privacy: .public)): \(setAside.path, privacy: .public)")
    }
}
