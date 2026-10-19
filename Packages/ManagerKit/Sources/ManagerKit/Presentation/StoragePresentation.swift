import Foundation

/// Texte des Segments „Speicher“: Status, Risiko, Löschweg, Sammeldialog (Spec Speicher §2.3) und Ergebnis (§2.5).
public enum StoragePresentation {
    public static func statusText(_ status: StorageCategoryStatus) -> String? {
        switch status {
        case .available: nil
        case .notInstalled: "Nicht installiert"
        case .needsFullDiskAccess: "Festplattenvollzugriff nötig"
        case .failed(let reason): "Fehler: \(reason)"
        }
    }

    public static func riskText(_ risk: StorageRisk) -> String {
        switch risk {
        case .low: "Risiko gering"
        case .medium: "Risiko mittel"
        case .reportOnly: "Nur Bericht"
        }
    }

    public static func methodText(_ removal: RemovalMethod) -> String {
        switch removal {
        case .trash: "in den Papierkorb"
        case .delete: "endgültig löschen"
        case .command(let spec): "Befehl: \(spec.commandLine)"
        case .none: "nur Bericht"
        }
    }

    /// Gewählte Einträge je Kategorie (nur wählbare).
    public static func selectedItems(in reports: [StorageCategoryReport],
                                     selection: Set<String>) -> [(StorageCategoryReport, [StorageItem])] {
        reports.compactMap { report in
            let items = report.items.filter { $0.isSelectable && selection.contains($0.id) }
            return items.isEmpty ? nil : (report, items)
        }
    }

    /// Ein Sammeldialog: je Kategorie Löschweg und Größe (bei Befehlen mit der Beschreibung der Kategorie), darunter
    /// die Summe im Bestätigungsknopf.
    public static func confirmation(reports: [StorageCategoryReport], selection: Set<String>) -> ActionConfirmation {
        let groups = selectedItems(in: reports, selection: selection)
        let items = groups.flatMap(\.1)
        let lines = groups.map { report, items in
            let methods = Set(items.map { methodText($0.removal) }).sorted().joined(separator: ", ")
            let hasCommand = items.contains(where: isCommand)
            let isStock = items.contains { isCommand($0) && !$0.commandRemovesItem }
            var line = "\(report.category.title): \(methods) – \(sizeText(of: items, isStock: isStock))"
            if hasCommand, !report.category.summary.isEmpty { line += "\n\(report.category.summary)" }
            return line
        }
        let hasCommand = items.contains(where: isCommand)
        let hasDelete = items.contains { $0.removal == .delete }
        return ActionConfirmation(
            title: items.count == 1 ? "1 Eintrag aufräumen?" : "\(items.count) Einträge aufräumen?",
            message: lines.joined(separator: "\n"),
            note: irreversibilityNote(hasCommand: hasCommand, hasDelete: hasDelete),
            confirmTitle: confirmTitle(for: items),
            isDestructive: true
        )
    }

    private static func irreversibilityNote(hasCommand: Bool, hasDelete: Bool) -> String? {
        switch (hasCommand, hasDelete) {
        case (true, true): "Befehle und endgültiges Löschen lassen sich nicht rückgängig machen."
        case (true, false): "Befehle lassen sich nicht rückgängig machen."
        case (false, true): "Endgültig gelöschte Einträge lassen sich nicht wiederherstellen."
        case (false, false): nil
        }
    }

    /// Größe einer Kategorie im Dialog. Bei Befehlen ist es der gemessene Bestand, nicht das Ergebnis: Ein Befehl wie
    /// `uv cache prune` räumt nur Ungenutztes weg (nicht bei `StorageItem.commandRemovesItem`, etwa einer
    /// Simulator-Laufzeit). Ohne bekannte Größe der übliche Text („Größe unbekannt“).
    private static func sizeText(of items: [StorageItem], isStock: Bool) -> String {
        let size = RemovalSize(sizes: items.map(\.size))
        guard isStock, size.known > 0 else { return size.text }
        return "Bestand \(size.text) (freigegeben wird nur Ungenutztes)"
    }

    /// Je Teil „1,2 GB freigeben“ (nur endgültig Gelöschtes) und „1,2 GB in den Papierkorb legen“ (der Papierkorb gibt
    /// erst beim Leeren Platz frei); bei gemischter Auswahl beide, durch Komma getrennt. Befehle zählen nie mit: ihre
    /// Größe ist der Bestand, nicht das, was der Befehl freigibt. Je „mindestens …“ bei unvollständiger Größe; ein Teil
    /// ohne bekannte Größe entfällt. Ist keine Größe bekannt: „In den Papierkorb legen“ (nur Papierkorb) bzw.
    /// „Aufräumen“.
    private static func confirmTitle(for items: [StorageItem]) -> String {
        let deleted = items.filter { $0.removal == .delete }
        let trashed = items.filter(isTrash)
        let parts = [sizeLabel(deleted.map(\.size), action: "freigeben"),
                     sizeLabel(trashed.map(\.size), action: "in den Papierkorb legen")].compactMap(\.self)
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        return !trashed.isEmpty && trashed.count == items.count ? "In den Papierkorb legen" : "Aufräumen"
    }

    /// `nil`, wenn keine Größe bekannt ist.
    private static func sizeLabel(_ sizes: [FileSize], action: String) -> String? {
        let size = RemovalSize(sizes: sizes)
        guard size.known > 0 else { return nil }
        let isComplete = size.unreadable == 0 && size.unknown == 0
        return (isComplete ? "" : "mindestens ") + "\(AppTexts.formattedSize(size.known)) \(action)"
    }

    private static func isTrash(_ item: StorageItem) -> Bool { item.removal == .trash }

    private static func isCommand(_ item: StorageItem) -> Bool {
        if case .command = item.removal { true } else { false }
    }

    /// „1,2 GB freigegeben, 300 MB in den Papierkorb gelegt (frei nach dem Leeren), 1 übersprungen, 2 fehlgeschlagen“.
    /// Papierkorb-Einträge zählen nicht als freigegeben: der Platz wird erst beim Leeren frei. Ohne bekannte Größe
    /// (Docker, `simctl`, unlesbare Größen) steht keine Zahl („3 aufgeräumt, freigegebene Größe unbekannt“), bei
    /// teilweise bekannter Größe „mindestens …“.
    public static func summary(_ outcomes: [StorageCleanOutcome]) -> String {
        let removed = outcomes.filter { $0.result == .removed }
        let skipped = outcomes.count { if case .skipped = $0.result { true } else { false } }
        let failed = outcomes.count { if case .failed = $0.result { true } else { false } }
        var parts: [String] = []
        let freed = removed.filter { $0.method != .trash }
        let trashed = removed.filter { $0.method == .trash }
        if !freed.isEmpty { parts.append(freedText(freed)) }
        if !trashed.isEmpty { parts.append(trashedText(trashed)) }
        if parts.isEmpty { parts.append("Nichts aufgeräumt") }
        if skipped > 0 { parts.append("\(skipped) übersprungen") }
        if failed > 0 { parts.append("\(failed) fehlgeschlagen") }
        return parts.joined(separator: ", ")
    }

    /// Ausgang eines Eintrags: „aufgeräumt – 1,2 GB“ (Größe nur, wenn bekannt), „übersprungen: <Grund>“,
    /// „fehlgeschlagen: <Grund>“ (Spec Speicher §2.5).
    public static func resultText(_ outcome: StorageCleanOutcome) -> String {
        switch outcome.result {
        case .removed: outcome.freedBytes.map { "aufgeräumt – \(AppTexts.formattedSize($0))" } ?? "aufgeräumt"
        case .skipped(let reason): "übersprungen: \(reason)"
        case .failed(let reason): "fehlgeschlagen: \(reason)"
        }
    }

    /// Nicht erfasste Orte aller Kategorien (`StorageCategoryReport.uncoveredPaths`), ohne Doppelte.
    public static func uncoveredPaths(_ reports: [StorageCategoryReport]) -> [String] {
        var seen = Set<String>()
        return reports.flatMap(\.uncoveredPaths).filter { seen.insert($0).inserted }
    }

    /// „Nicht erfassbar: 3 Ordner – ohne Leserecht fehlen ihre Größen in den Summen.“ (#226); `nil` ohne solche.
    public static func coverageNote(_ reports: [StorageCategoryReport]) -> String? {
        let count = uncoveredPaths(reports).count
        guard count > 0 else { return nil }
        return "Nicht erfassbar: \(count == 1 ? "1 Ordner" : "\(count) Ordner") – ohne Leserecht fehlen ihre Größen in den Summen."
    }

    /// „Keiner Kategorie zugeordnet: 733 GB von 853 GB belegt – Apps, Dokumente, System sowie lokale Snapshots,
    /// Spotlight-Index und Dateiversionen (.DocumentRevisions-V100).“ (#226). Fehlen Größen oder ganze Kategorien
    /// (Fehler, kein Lesezugriff), „höchstens …“; `nil`, wenn die Kategorien mehr zählen als belegt ist.
    public static func unassignedNote(_ reports: [StorageCategoryReport], volume: VolumeUsage) -> String? {
        let size = RemovalSize(sizes: reports.flatMap { $0.items.map(\.size) })
        let unassigned = volume.usedBytes - size.known
        guard unassigned > 0 else { return nil }
        let hasGaps = reports.contains { report in
            switch report.status {
            case .failed, .needsFullDiskAccess: true
            case .available, .notInstalled: false
            }
        }
        let isComplete = size.unreadable == 0 && size.unknown == 0 && uncoveredPaths(reports).isEmpty && !hasGaps
        return "Keiner Kategorie zugeordnet: \(isComplete ? "" : "höchstens ")\(AppTexts.formattedSize(unassigned)) von "
            + "\(AppTexts.formattedSize(volume.usedBytes)) belegt – Apps, Dokumente, System sowie lokale Snapshots, "
            + "Spotlight-Index und Dateiversionen (.DocumentRevisions-V100)."
    }

    /// Weg eines Ausgangs, z. B. „Papierkorb“.
    public static func methodText(_ method: StorageCleanOutcome.Method) -> String {
        switch method {
        case .trash: "Papierkorb"
        case .delete: "endgültig gelöscht"
        case .command: "Befehl"
        case .signal: "Prozess beendet"
        case .none: "nur Bericht"
        }
    }

    private static func freedText(_ outcomes: [StorageCleanOutcome]) -> String {
        let size = removedSize(outcomes)
        guard size.known > 0 || size.unknown == 0 else {
            return "\(outcomes.count) aufgeräumt, freigegebene Größe unbekannt"
        }
        return "\(size.text) freigegeben"
    }

    private static func trashedText(_ outcomes: [StorageCleanOutcome]) -> String {
        let size = removedSize(outcomes)
        guard size.known > 0 || size.unknown == 0 else { return "\(outcomes.count) in den Papierkorb gelegt (Größe unbekannt)" }
        return "\(size.text) in den Papierkorb gelegt (frei nach dem Leeren)"
    }

    /// Entfernte Größe; ein Ausgang ohne `freedBytes` zählt als unbekannt.
    private static func removedSize(_ outcomes: [StorageCleanOutcome]) -> RemovalSize {
        RemovalSize(sizes: outcomes.map { $0.freedBytes.map(FileSize.bytes) ?? .unknown })
    }
}
