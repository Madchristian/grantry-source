// Deutsche Texte und Farben für Signatur, Vorhandensein und Berechtigungszustand in Listen und Detailansichten.

extension SigningInfo {
    /// Art der Signatur, bei Developer ID ergänzt um den Notarisierungsstatus.
    public var displayName: String {
        switch kind {
        case .apple: "Apple"
        case .appStore: "App Store"
        case .developerID: isNotarized ? "Developer ID, notarisiert" : "Developer ID, nicht notarisiert"
        case .development: "Entwicklerzertifikat (lokaler Build)"
        case .adHoc: "Ad-hoc-signiert"
        case .unsigned: "Nicht signiert"
        case .unknown: "Unbekannt"
        }
    }

    /// Kurzform für schmale Spalten („Developer ID“, „Ad hoc“); Notarisierung und Team zeigt die Farbe bzw. `displayName`.
    public var shortName: String {
        switch kind {
        case .apple: "Apple"
        case .appStore: "App Store"
        case .developerID: "Developer ID"
        case .development: "Entwickler"
        case .adHoc: "Ad hoc"
        case .unsigned: "Unsigniert"
        case .unknown: "Unbekannt"
        }
    }

    /// Grün für Apple, App Store und notarisierte Developer-ID; Rot ohne Signatur; sonst Orange bzw. neutral.
    public var tone: PresentationTone {
        switch kind {
        case .apple, .appStore: .positive
        case .developerID: isNotarized ? .positive : .warning
        case .development, .adHoc: .warning
        case .unsigned: .critical
        case .unknown: .neutral
        }
    }
}

extension Presence {
    public var displayName: String {
        switch self {
        case .present: "Vorhanden"
        case .missing: "Nicht mehr vorhanden"
        case .probablyMissing: "Vermutlich entfernt"
        case .unknown: "Nicht feststellbar"
        }
    }
}

extension AuthValue {
    /// Grün bei erteiltem, Orange bei eingeschränktem Zugriff; verweigert und unbekannt neutral.
    public var tone: PresentationTone {
        switch self {
        case .allowed: .positive
        case .limited: .warning
        case .denied, .unknown: .neutral
        }
    }
}

extension TCCScope {
    /// „Benutzer“ bzw. „System“ (wie `ScopeFilter`).
    public var displayName: String {
        switch self {
        case .user: "Benutzer"
        case .system: "System"
        }
    }
}
