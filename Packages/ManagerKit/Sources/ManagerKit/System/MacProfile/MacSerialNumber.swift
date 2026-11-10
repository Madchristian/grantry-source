/// Seriennummer des Macs, verdeckt bis zum ausdrücklichen `reveal()` (Spec § 4.5). Nicht `Codable`; Beschreibung,
/// Debug-Ausgabe und Spiegelung zeigen nur `hiddenText` – so landet sie weder in einem Log (auch nicht per
/// Interpolation) noch in Verlauf oder Snapshot. Wer sie anzeigt, hält sie nur im Zustand der Ansicht.
public struct MacSerialNumber: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let hiddenText = "••••••"

    private let value: String

    /// `nil` für einen leeren Wert.
    init?(_ raw: String) {
        guard let value = MacProfile.cleaned(raw) else { return nil }
        self.value = value
    }

    /// Der Klartext – nur für die Anzeige nach dem Klick auf „Einblenden“.
    public func reveal() -> String { value }

    public var description: String { Self.hiddenText }
    public var debugDescription: String { Self.hiddenText }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
