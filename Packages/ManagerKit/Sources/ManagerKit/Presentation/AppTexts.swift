// Deutsche Texte zu installierten Apps: Herkunft, Architektur, Kurzname der Signaturart, Größe und „zuletzt benutzt“.

import Foundation

public enum AppTexts {
    /// Dateigröße wie im Finder („1,2 GB“).
    public static func formattedSize(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// „Zuletzt benutzt heute/gestern/vor N Tagen“ (Kalendertage); ohne Datum „Zuletzt benutzt: unbekannt“.
    public static func lastUsed(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "Zuletzt benutzt: unbekannt" }
        return "Zuletzt benutzt " + lastUsedValue(date, now: now, calendar: calendar)
    }

    /// „heute“, „gestern“, „vor 3 Tagen“ – Wert hinter der Beschriftung „Zuletzt benutzt“.
    static func lastUsedValue(_ date: Date, now: Date, calendar: Calendar) -> String {
        SecurityCheckPresentation.dayText(CalendarDays.since(date, now: now, calendar: calendar), .ago)
    }
}

extension AppOrigin {
    /// „App Store“, „Homebrew“, „Apple“, „Web-App“, „Direkt“, „Nicht prüfbar“.
    public var displayName: String {
        switch self {
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        case .apple: "Apple"
        case .webApp: "Web-App"
        case .direct: "Direkt"
        case .unverified: "Nicht prüfbar"
        }
    }
}

extension WebAppBrowser {
    public var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .edge: "Edge"
        case .brave: "Brave"
        }
    }
}

extension AppArchitecture {
    public var displayName: String {
        switch self {
        case .appleSilicon: "Apple Silicon"
        case .intel: "Intel"
        case .universal: "Universal"
        case .unknown: "Unbekannt"
        }
    }
}

extension SigningInfo.Kind {
    /// Kurzname der Signaturart ohne Notarisierung (Änderungstexte).
    public var shortName: String {
        switch self {
        case .apple: "Apple"
        case .appStore: "App Store"
        case .developerID: "Developer ID"
        case .development: "Entwicklerzertifikat"
        case .adHoc: "ad hoc"
        case .unsigned: "keine"
        case .unknown: "unbekannt"
        }
    }
}

extension InstalledApp {
    /// „Homebrew (Cask darktable)“, „Web-App (Safari)“, „Direkt – Google LLC“, sonst `origin.displayName`.
    public var originDetail: String {
        switch origin {
        case .homebrew(let cask): "Homebrew (Cask \(cask))"
        case .webApp(let browser): "\(origin.displayName) (\(browser.displayName))"
        case .direct: signing.developerName.map { "Direkt – \($0)" } ?? origin.displayName
        case .appStore, .apple, .unverified: origin.displayName
        }
    }

    /// „Zoom 6.0 (600)“ bzw. nur der Name.
    var nameWithVersion: String {
        [name, versionText].compactMap(\.self).joined(separator: " ")
    }
}

extension InstalledApp {
    /// Hinweis, wenn die gezeigte Signatur nicht aus einer Prüfung dieses Scans stammt (Review M2): „Signatur nicht
    /// geprüft seit 3 Tagen“, „Signatur nach Änderung nicht prüfbar“; `nil`, wenn sie aktuell geprüft ist.
    /// - Parameter calendar: Kalender für die Tagesangabe (`CalendarDays`).
    public func signingStatusNote(now: Date, calendar: Calendar = .current) -> String? {
        switch signingLimitation {
        case nil: nil
        case .notChecked?: "Signatur nicht geprüft (Zeitüberschreitung)"
        case .carriedForward(let verifiedAt)?:
            "Signatur nicht geprüft " + SecurityCheckPresentation.dayText(
                CalendarDays.since(verifiedAt, now: now, calendar: calendar), .since
            )
        case .changedSinceCheck?: "Signatur nach Änderung nicht prüfbar"
        }
    }
}
