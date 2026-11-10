import Foundation

// MARK: - Erweiterungen (TM-13.3)

extension ChangeDescription {
    static func describe(_ kind: ChangeEvent.Kind, record: ExtensionRecord, previous: ExtensionRecord?) -> Self {
        let subject = subjectText(of: record)
        switch kind {
        case .added:
            let details = [record.versionText.map { "Version \($0)" }, record.state.displayName].compactMap(\.self)
            return Self(title: "Neue Erweiterung", body: "\(subject): \(details.joined(separator: ", ")).")
        case .removed:
            return Self(title: "Erweiterung entfernt", body: "\(subject).")
        case .modified:
            let texts = previous.map { extensionChangeTexts(from: $0, to: record) } ?? []
            let detail = texts.isEmpty ? "geändert" : texts.joined(separator: ", ")
            return Self(title: extensionTitle(from: previous, to: record), body: "\(subject): \(detail).")
        }
    }

    /// „Name (Art)“, mit zugeordneter App ergänzt um „von App“.
    private static func subjectText(of record: ExtensionRecord) -> String {
        let base = "\(record.name ?? record.bundleID) (\(record.kind.displayName))"
        guard let app = record.owner?.appName else { return base }
        return "\(base) von \(app)"
    }

    /// Eine neue Version geht vor, dann ein Zustandswechsel mit eigenem Titel, sonst die Signatur.
    private static func extensionTitle(from previous: ExtensionRecord?, to record: ExtensionRecord) -> String {
        guard let previous else { return "Erweiterung geändert" }
        if previous.versionText != record.versionText { return "Erweiterung aktualisiert" }
        if previous.state != record.state { return record.state.changeTitle }
        return "Signatur einer Erweiterung geändert"
    }

    /// Die gemeldeten Unterschiede in fester Reihenfolge (wie `ExtensionRecord.hasSignificantChanges`).
    private static func extensionChangeTexts(from old: ExtensionRecord, to new: ExtensionRecord) -> [String] {
        var texts: [String] = []
        if old.versionText != new.versionText {
            texts.append("Version \(old.versionText ?? "unbekannt") → \(new.versionText ?? "unbekannt")")
        }
        if old.state != new.state {
            texts.append("\(old.state.displayName) → \(new.state.displayName)")
        }
        if new.signingDiffers(from: old), let before = old.signing?.kind, let after = new.signing?.kind {
            texts.append("Signatur \(before.shortName) → \(after.shortName)")
        }
        if new.teamDiffers(from: old), let before = old.teamID, let after = new.teamID {
            texts.append("Team-ID \(before) → \(after)")
        }
        return texts
    }
}

extension ChangeSubject {
    var extensionRecord: ExtensionRecord? {
        if case .extensionRecord(let record) = self { record } else { nil }
    }
}

extension ExtensionRecord {
    /// „6.2.1“, mit abweichendem Build „6.2.1 (6224)“; `nil` ohne Version.
    public var versionText: String? {
        guard let version else { return nil }
        guard let buildVersion, buildVersion != version else { return version }
        return "\(version) (\(buildVersion))"
    }
}

extension ExtensionKind {
    /// Deutscher Name der Art.
    public var displayName: String {
        switch self {
        case .kernelExtension: "Kernel-Erweiterung"
        case .driver: "Treiber"
        case .network: "Netzwerkerweiterung"
        case .endpointSecurity: "Endpoint Security"
        case .camera: "Kameraerweiterung"
        case .otherSystemExtension: "Systemerweiterung"
        case .audioPlugin: "Audio-Plug-in"
        case .videoPlugin: "Video-Plug-in"
        }
    }
}

extension ExtensionLayer {
    /// Deutscher Name der Rechte-Schicht (Spec § 4.1).
    public var displayName: String {
        switch self {
        case .kernel: "Im Kern"
        case .systemExtension: "Systemerweiterung mit Sonderrechten"
        case .driver: "Treiber"
        case .servicePlugin: "Plug-in in einem Systemdienst"
        }
    }
}

extension ExtensionGroup {
    /// Deutscher Name der Liste (Einschränkungen der Quelle).
    public var displayName: String {
        switch self {
        case .systemExtensions: "Systemerweiterungen"
        case .kernelExtensions: "Kernel-Erweiterungen"
        case .servicePlugins: "Plug-ins in Systemdiensten"
        }
    }
}

extension ExtensionState {
    /// Deutscher Zustandsname für Kurztexte und Listen.
    public var displayName: String {
        switch self {
        case .enabled: "aktiv"
        case .disabled: "deaktiviert"
        case .waitingForUser: "wartet auf Freigabe"
        case .removalPending: "wird beim Neustart entfernt"
        case .loaded: "geladen"
        case .notLoaded: "nicht geladen"
        case .installed: "installiert"
        case .unknown(let text): "unbekannt (\(text))"
        }
    }

    /// Titel der Meldung, wenn eine Erweiterung in diesen Zustand wechselt.
    var changeTitle: String {
        switch self {
        case .enabled: "Erweiterung aktiviert"
        case .disabled: "Erweiterung deaktiviert"
        case .waitingForUser: "Erweiterung wartet auf Freigabe"
        case .removalPending: "Erweiterung wird beim Neustart entfernt"
        case .loaded: "Kernel-Erweiterung geladen"
        case .notLoaded: "Kernel-Erweiterung nicht mehr geladen"
        case .installed, .unknown: "Zustand einer Erweiterung geändert"
        }
    }
}
