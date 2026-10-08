/// Pfade so zerlegt, wie der Kernel sie liest: nach dem Byte `/` in UTF-8. Swift-`Character`s taugen dafür nicht – ein
/// kombinierendes Zeichen nach `/` (`"/\u{301}"`) bildet mit dem Trenner ein einziges Zeichen, `split(separator: "/")`
/// und `hasPrefix(".")` sähen ihn dann nicht.
enum RawPath {
    private static let separator = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")

    /// Bestandteile eines absoluten Pfads; `nil`, wenn er relativ ist, keinen Bestandteil hat oder einer leer, `.` oder
    /// `..` ist (auch `//` und ein abschließender `/`).
    static func components(of path: String) -> [String]? {
        guard path.utf8.first == separator else { return nil }
        let parts = path.utf8.dropFirst().split(separator: separator, omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0.elementsEqual([dot]) || $0.elementsEqual([dot, dot]) })
        else { return nil }
        return parts.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Absoluter Pfad aus Bestandteilen (Umkehrung von `components(of:)`); ohne Bestandteile `/`.
    static func path(of components: some Collection<String>) -> String {
        "/" + components.joined(separator: "/")
    }

    /// `/` und jeder Präfix-Pfad aus `components` (`[/, /a, /a/b]` für `[a, b]`).
    static func prefixes(of components: [String]) -> [String] {
        (0...components.count).map { path(of: components.prefix($0)) }
    }

    /// Versteckt im Finder: Der Name beginnt mit dem Byte `.`.
    static func isHidden(_ name: String) -> Bool {
        name.utf8.first == dot
    }

    /// Endung ohne Rücksicht auf Groß-/Kleinschreibung, byteweise (`Foo.APP`).
    static func hasExtension(_ name: String, _ pathExtension: String) -> Bool {
        name.lowercased().utf8.reversed().starts(with: ("." + pathExtension).utf8.reversed())
    }
}
