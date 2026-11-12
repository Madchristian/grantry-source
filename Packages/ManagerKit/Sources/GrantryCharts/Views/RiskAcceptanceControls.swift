import SwiftUI

// Eigene Einschätzung einer App im Detail (LB-2.5, #542; Entwurf LB-2.1, #538): Inhalt der Gruppe „Eigene Einschätzung“
// im `RecordDetailPanel`. Akzeptiert mit „Risiko akzeptiert“ vorweg, darunter die Erklärung, der Knopf und ein Fehler
// beim Speichern als Hinweis `critical`. Den Knopf liefert die Ansicht.

/// Inhalt der eigenen Einschätzung.
public struct RiskAcceptanceContent: Hashable, Sendable {
    public let isAccepted: Bool
    public let explanation: String
    public let error: String?

    public init(isAccepted: Bool, explanation: String, error: String? = nil) {
        self.isAccepted = isAccepted
        self.explanation = explanation
        self.error = error
    }
}

/// Eigene Einschätzung: Zustand, Erklärung, Knopf, Fehler.
public struct RiskAcceptanceControls<Toggle: View>: View {
    let content: RiskAcceptanceContent
    let toggle: Toggle

    public init(_ content: RiskAcceptanceContent, @ViewBuilder toggle: () -> Toggle) {
        self.content = content
        self.toggle = toggle()
    }

    public var body: some View {
        if content.isAccepted {
            Label(String(localized: "Risiko akzeptiert"), systemImage: "checkmark.circle")
                .font(InstrumentFont.body.weight(.medium))
                .accessibilityReading(Text(verbatim: String(localized: "Eigene Einschätzung")),
                                      value: Text(verbatim: String(localized: "Risiko akzeptiert")))
        }
        InstrumentNote(content.explanation)
        toggle.controlSize(.small)
        if let error = content.error { InstrumentNote(error, kind: .critical) }
    }
}
