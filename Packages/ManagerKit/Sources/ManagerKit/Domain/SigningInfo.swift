/// Ergebnis der Code-Signatur-Prüfung eines Programms oder App-Bundles.
public struct SigningInfo: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// `development`: Entwicklerzertifikat („Apple Development“/„Mac Developer“) – ein lokaler Build, der nur auf
        /// registrierten Geräten des Teams läuft und nie notarisiert wird.
        case apple, appStore, developerID, development, adHoc, unsigned, unknown
    }

    public var kind: Kind
    public var teamID: String?
    public var isNotarized: Bool
    /// Name des Entwicklers aus dem Blattzertifikat (nur Developer ID und Entwicklerzertifikat), sonst `nil`. Ältere
    /// Snapshots haben ihn nicht (synthetisiertes `Codable` liest fehlende Optionals als `nil`).
    public var developerName: String?

    public init(kind: Kind, teamID: String? = nil, isNotarized: Bool = false, developerName: String? = nil) {
        self.kind = kind
        self.teamID = teamID
        self.isNotarized = isNotarized
        self.developerName = developerName
    }

    public static let unknown = SigningInfo(kind: .unknown)

    public var isAppleSigned: Bool { kind == .apple }
}

extension SigningInfo {
    /// „Developer ID Application: Google LLC (EQHXZ8M8AV)“ → „Google LLC“: Text nach dem ersten „: “, ohne die
    /// abschließende Klammer – aber nur, wenn sie die Team-ID enthält („Foo (Bar)“ bleibt); leer → `nil`.
    static func developerName(fromCertificateSummary summary: String, teamID: String?) -> String? {
        var name = Substring(summary)
        if let colon = name.range(of: ": ") { name = name[colon.upperBound...] }
        if let teamID, name.hasSuffix(" (\(teamID))") { name = name.dropLast(teamID.count + 3) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
