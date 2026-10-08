/// Semantische Farbe einer Anzeige; erst die Oberfläche bildet sie auf konkrete Farben ab.
public enum PresentationTone: String, Hashable, Sendable, CaseIterable {
    case positive, neutral, warning, critical

    /// Passendes SF Symbol für eine Zustandszeile.
    public var systemImage: String {
        switch self {
        case .positive: "checkmark.circle.fill"
        case .neutral: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}
