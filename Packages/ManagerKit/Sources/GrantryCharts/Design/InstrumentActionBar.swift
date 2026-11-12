import SwiftUI

// Aktionsleiste unten im Fund-Panel (LB-4.2, #548; Entwurf LB-4.1, #547, Spec 2026-11-10 § 11.4 a, e und Korrektur 1):
// Aufräumen (Reste, Speicher, Prozesse) und das Blatt „App entfernen“. Knöpfe bleiben native Steuerelemente.

/// Aktionsleiste: links Suchen bzw. Scannen oder Abbrechen, daneben der Umfang der Auswahl, rechts die laufende Aktion mit
/// Text und die Aktion selbst. Knöpfe und laufende Aktion behalten ihre Breite; der Umfang bricht um, statt abgeschnitten
/// zu werden. Sperren (ohne Auswahl, ohne Ergebnis, veraltet, während einer Aktion) setzt die Ansicht an ihren Knöpfen.
public struct InstrumentActionBar<Leading: View, Trailing: View>: View {
    let scope: String
    let runningText: String?
    let leading: Leading
    let trailing: Trailing

    public init(scope: String, runningText: String? = nil, @ViewBuilder leading: () -> Leading,
                @ViewBuilder trailing: () -> Trailing) {
        self.scope = scope
        self.runningText = runningText
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.panel) {
            HStack(spacing: InstrumentSpacing.group) { leading }.fixedSize()
            Text(verbatim: scope).font(InstrumentFont.label.monospacedDigit()).foregroundStyle(.instrumentSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityReading(Text(verbatim: String(localized: "Umfang")), value: Text(verbatim: scope))
            if let runningText {
                RunningActionLabel(runningText).fixedSize()
            }
            HStack(spacing: InstrumentSpacing.group) { trailing }.fixedSize()
        }
        .font(InstrumentFont.body)
        .instrumentBar()
    }
}
