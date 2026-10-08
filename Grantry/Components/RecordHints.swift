import ManagerKit
import SwiftUI

/// Prüfhinweise (Findings, höchster Schweregrad zuerst) und Aufräumhinweis eines Eintrags – in Berechtigungszeilen
/// und im Detail von Autostart-Einträgen und Apps.
struct RecordHints: View {
    let findings: [RiskFinding]
    let cleanupHint: CleanupHint?

    init(presentation: PresentationSnapshot, recordID: String) {
        self.init(findings: presentation.findings(for: recordID), cleanupHint: presentation.cleanupHint(for: recordID))
    }

    init(findings: [RiskFinding], cleanupHint: CleanupHint? = nil) {
        self.findings = findings
        self.cleanupHint = cleanupHint
    }

    /// Ob es keinen Hinweis gibt.
    var isEmpty: Bool { findings.isEmpty && cleanupHint == nil }

    var body: some View {
        ForEach(findings) { finding in
            HintLabel(text: finding.message, systemImage: "exclamationmark.triangle.fill",
                      color: RecordBadge.review(finding.severity).color)
        }
        if let cleanupHint {
            HintLabel(text: cleanupHint.message, systemImage: "trash", color: .secondary)
        }
    }
}

/// Kleiner Hinweis mit Symbol (Prüfhinweis, Aufräumhinweis, Grund für Schreibschutz).
struct HintLabel: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
