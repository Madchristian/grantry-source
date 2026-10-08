/// Form von Kennungen in Eintragsnamen der Reste-Orte, für die Suche nach Resten gelöschter Apps (Plan-Abweichung 8).
enum BundleIDShape {
    /// Kennungen von Apple ohne `com.apple.`-Präfix (Kurzbefehle, Developer-App, Systemkomponenten), klein. Bewusst weit:
    /// Sie zählen als Präfix und hinter einem ersten Bestandteil (`group.is.workflow.my.app`).
    static let appleNamespaces = [
        "is.workflow.", "developer.apple.", "org.swift.", "org.cups.", "org.llvm.", "org.webkit.", "edu.mit.kerberos",
    ]

    /// Kennungen von Bibliotheken und Laufzeitumgebungen, die viele Apps einbetten (Sparkle, Electron, Bild-Caches, Analyse-
    /// und Absturz-SDKs, Python), klein: Ihre Einträge können zu einer installierten App gehören, obwohl Launch Services
    /// die Kennung nicht kennt.
    static let sharedLibraryNamespaces = [
        "org.sparkle-project.", "com.electron.", "com.github.electron", "com.squirrel.", "com.breakpad.", "org.chromium.",
        "com.onevcat.", "com.segment.", "io.sentry.", "com.crashlytics.", "com.google.firebase", "com.bugsnag.",
        "org.python.", "org.nodejs.", "org.mozilla.", "com.oracle.java", "net.java.",
    ]

    /// Ob ein Name wie eine Bundle-ID aussieht: mindestens drei nicht leere Bestandteile aus ASCII-Buchstaben, -Ziffern,
    /// `-` und `_`, der erste 2–10 Zeichen aus Kleinbuchstaben oder Ziffern (`com`, `ai`, `io`, `recipes`). Nur solche
    /// Kennungen gehen an Launch Services und Spotlight.
    static func isPlausible(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let first = parts.first, (2...10).contains(first.count),
              first.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Apple-Kennung, ohne Groß-/Kleinschreibung: `com.apple.…` (auch hinter dem ersten Bestandteil, `group.com.apple.…`,
    /// `<TEAM>.com.apple.…`), ein Bestandteil `apple` oder ein Namensraum aus `appleNamespaces`. Im Zweifel Apple.
    static func isApple(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        if AppleEntryName.identifier(in: lowered) != nil { return true }
        if lowered.split(separator: ".").contains("apple") { return true }
        return appleNamespaces.contains { lowered.hasPrefix($0) || lowered.contains("." + $0) }
    }

    /// Kennung einer eingebetteten Bibliothek (`sharedLibraryNamespaces`), ohne Groß-/Kleinschreibung.
    static func isSharedLibrary(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        return sharedLibraryNamespaces.contains { lowered.hasPrefix($0) }
    }
}
