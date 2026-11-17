import SwiftUI

/// Ring mit Wert in der Mitte für Kacheln des Übersichts-Baukastens (Spec 2026-11-09-uebersicht-baukasten § 2): füllt die
/// Höhe, die ihm die Kachel lässt (1 × 1: unter dem Titel), und bleibt rund. Bahn und Bogen wie `LoadRing`, ohne Übergang;
/// `nil` heißt „keine Messung“: nur die Bahn, der Wert zeigt dann „–“. Der Wert gehört zur Kachel, die ihn VoiceOver
/// nennt; der Ring selbst ist verborgen.
public struct TileRing: View {
    let fraction: Double?
    let value: String
    let hue: InstrumentHue

    @Environment(\.self) private var environment

    public init(fraction: Double?, value: String, hue: InstrumentHue) {
        self.fraction = fraction
        self.value = value
        self.hue = hue
    }

    static let lineWidth: CGFloat = 4

    public var body: some View {
        ZStack {
            LoadRing(fraction: fraction, color: environment.instrumentColor(hue), lineWidth: Self.lineWidth)
            Text(verbatim: value)
                .font(InstrumentFont.label.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, Self.lineWidth + InstrumentSpacing.stack)
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .renderProbe("TileRing")
        .accessibilityHidden(true)
    }
}
