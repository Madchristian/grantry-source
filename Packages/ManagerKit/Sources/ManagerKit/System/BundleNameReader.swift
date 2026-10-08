import Foundation
import GrantryShared

/// Anzeigename eines App-Bundles.
public protocol AppNameReading: Sendable {
    /// Name des Bundles unter `path`; `info` ist der Inhalt der `Info.plist`, aus der Grantry liest (bei iOS-Apps im
    /// Wrapper die des inneren Bundles).
    func name(ofBundleAt path: String, info: [String: Any]) -> String
}

/// Anzeigename aus den Bundle-Dateien – ohne Launch Services (Review H2).
///
/// `FileManager.displayName` ließ Launch Services das Bundle registrieren; der `lsd` des Nutzers öffnete dabei
/// `Info.plist` und Hauptprogramm und hing an einer FIFO dauerhaft (samt jeder weiteren Registrierung). Grantry liest
/// den Namen daher selbst, nur aus regulären Dateien und mit Größenlimit (`FileType.contentsOfRegularFile`):
///
/// 1. `CFBundleDisplayName`, dann `CFBundleName` – jeweils zuerst lokalisiert, dann aus `info`,
/// 2. sonst der Dateiname ohne `.app`.
///
/// Lokalisiert wird aus `Resources/InfoPlist.loctable` (Sprache → Schlüssel → Text) oder
/// `Resources/<Sprache>.lproj/InfoPlist.strings` (Binär-, XML- oder Text-Format, UTF-8 oder UTF-16) in der Reihenfolge
/// der bevorzugten Sprachen, dann `CFBundleDevelopmentRegion`, dann Englisch. Der Finder zeigt bei Apps ohne
/// `LSHasLocalizedDisplayName` den Dateinamen; Grantry bevorzugt bewusst den Namen aus dem Bundle (wie bisher, wenn
/// der Finder-Name dem Dateinamen glich).
///
/// Jeder Name – auch der Dateiname – wird bereinigt (`sanitized`, Review N1): Ein Bundle kann sonst mit Bidi-Overrides
/// oder Steuerzeichen einen fremden Namen vortäuschen oder die Anzeige sprengen. Bleibt nichts übrig, gilt der nächste
/// Name der Reihenfolge.
public struct BundleNameReader: AppNameReading {
    /// Höchstgröße einer gelesenen Lokalisierungstabelle – echte sind wenige KB groß.
    static let maximumTableLength = 1 << 20
    /// Höchstlänge eines Anzeigenamens in Zeichen (samt „…“ nach dem Kürzen).
    static let maximumNameLength = 128
    /// Name, wenn auch der Dateiname nach dem Bereinigen leer ist.
    static let unnamed = "Unbenannte App"
    private static let keys = ["CFBundleDisplayName", "CFBundleName"]
    /// Alte `.lproj`-Namen (`German.lproj`) älterer Apps.
    private static let legacyLanguageNames = [
        "en": "English", "de": "German", "fr": "French", "ja": "Japanese", "es": "Spanish", "it": "Italian", "nl": "Dutch",
    ]

    private let preferredLanguages: @Sendable () -> [String]

    public init() {
        self.init(preferredLanguages: { Locale.preferredLanguages })
    }

    /// - Parameter preferredLanguages: bevorzugte Sprachen (BCP 47, z. B. `de-DE`), Standard `Locale.preferredLanguages`.
    init(preferredLanguages: @escaping @Sendable () -> [String]) {
        self.preferredLanguages = preferredLanguages
    }

    public func name(ofBundleAt path: String, info: [String: Any]) -> String {
        let source = WrapperLayout(path: path)?.innerBundle ?? path
        let localized = localizedInfo(inResources: BundleLayout(path: source).resourcesDirectory, info: info)
        for key in Self.keys {
            if let name = Self.displayName(localized[key]) ?? Self.displayName(info[key]) { return name }
        }
        return Self.fallbackName(of: path)
    }

    /// Lokalisierte `Info.plist`-Werte der ersten passenden Sprache; leer ohne Lokalisierung.
    private func localizedInfo(inResources resources: String, info: [String: Any]) -> [String: Any] {
        let table = Self.dictionary(atPath: resources + "/InfoPlist.loctable")
        for language in Self.candidates(for: preferredLanguages() + [info["CFBundleDevelopmentRegion"] as? String, "en"]) {
            if let strings = table?[language] as? [String: Any] { return strings }
            if let strings = Self.dictionary(atPath: "\(resources)/\(language).lproj/InfoPlist.strings") { return strings }
        }
        return [:]
    }

    /// `.lproj`-Namen zu `languages` in Vorzugsreihenfolge, ohne Doppelte: `zh-Hans-CN` → `zh-Hans-CN`, `zh_Hans_CN`,
    /// `zh-Hans`, `zh_Hans`, `zh`; dazu alte Namen wie `German`. Namen mit `/` oder `.` entfallen.
    static func candidates(for languages: [String?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ name: String) {
            guard !name.isEmpty, !name.contains("/"), !name.contains("."), seen.insert(name).inserted else { return }
            result.append(name)
        }
        for language in languages.compactMap(\.self) {
            var parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            while !parts.isEmpty {
                add(parts.joined(separator: "-"))
                add(parts.joined(separator: "_"))
                if parts.count == 1, let legacy = legacyLanguageNames[parts[0].lowercased()] { add(legacy) }
                parts.removeLast()
            }
        }
        return result
    }

    /// Wörterbuch aus der regulären Datei `path` (Property List in jedem Format oder Strings-Datei); `nil`, wenn sie
    /// fehlt, keine reguläre Datei, zu groß oder kein Wörterbuch ist.
    static func dictionary(atPath path: String) -> [String: Any]? {
        guard let data = FileType.contentsOfRegularFile(atPath: path, maximumLength: maximumTableLength + 1),
              data.count <= maximumTableLength else { return nil }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { return plist }
        // Strings-Datei („key" = "value";) ist ein OpenStep-Wörterbuch ohne Klammern.
        guard let text = text(of: data),
              let braced = try? PropertyListSerialization.propertyList(from: Data("{\n\(text)\n}".utf8), format: nil)
        else { return nil }
        return braced as? [String: Any]
    }

    /// Text in UTF-16 (mit BOM) oder UTF-8.
    private static func text(of data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8)
    }

    /// Bereinigter Name ohne `.app`-Endung; `nil`, wenn `value` kein Text ist oder nichts übrig bleibt.
    private static func displayName(_ value: Any?) -> String? {
        (value as? String).map { removingAppExtension(sanitized($0)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Bereinigter Dateiname ohne `.app`-Endung; „Unbenannte App“, wenn nichts übrig bleibt.
    static func fallbackName(of path: String) -> String {
        displayName(URL(fileURLWithPath: path).lastPathComponent) ?? unnamed
    }

    /// `name` als eine Zeile ohne Steuer- und Formatzeichen (`DisplayText.singleLine`), höchstens
    /// `maximumNameLength` Zeichen (gekürzt mit „…“).
    static func sanitized(_ name: String) -> String {
        let cleaned = DisplayText.singleLine(name)
        guard cleaned.count > maximumNameLength else { return cleaned }
        return cleaned.prefix(maximumNameLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Entfernt eine `.app`-Endung.
    static func removingAppExtension(_ name: String) -> String {
        name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
