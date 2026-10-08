/// Fremden Text (Datei- und Programmnamen) für Logzeilen und Meldungen aufbereiten.
public enum DisplayText {
    /// `text` als eine Zeile: ohne Steuer- (Cc) und Formatzeichen (Cf, darunter Bidi-Overrides und unsichtbare
    /// Trenner), Leerraum samt Zeilenumbrüchen zu je einem Leerzeichen zusammengefasst und an den Rändern entfernt. So
    /// kann ein Name weder eine weitere Logzeile vortäuschen noch die Anzeige umdrehen – Voraussetzung für
    /// `privacy: .public`.
    public static func singleLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format: continue
            default: break
            }
            if pendingSpace { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
