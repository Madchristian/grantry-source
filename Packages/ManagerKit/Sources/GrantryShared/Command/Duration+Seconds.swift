import Foundation

extension Duration {
    /// Gesamtdauer in Sekunden.
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Dauer in Sekunden mit deutschem Zahlenformat, z. B. `45 s` oder `0,2 s`.
    public var formattedSeconds: String {
        "\(seconds.formatted(.number.locale(Locale(identifier: "de_DE")))) s"
    }
}
