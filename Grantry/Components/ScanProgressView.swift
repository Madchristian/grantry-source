import ManagerKit
import SwiftUI

/// Darstellende Scan-Anzeige mit genau einer abbrechbaren Warteaufgabe je Prognose.
/// Kein Polling; SwiftUI beendet die Aufgabe beim Ausblenden und bei neuer Prognose.
struct ScanProgressView: View {
    let progress: ScanProgress

    static func valueText(_ progress: ScanProgress, at now: ContinuousClock.Instant = .now) -> String {
        let percent = Int((progress.fraction * 100).rounded(.down))
        guard let remaining = progress.remainingSeconds(at: now) else { return String(localized: "\(percent) %") }
        let seconds = Int(min(86_400, ceil(remaining / 5) * 5))
        return String(localized: "\(percent) % · noch ca. \(max(5, seconds)) s")
    }

    var body: some View {
        ScanProgressText(progress: progress) { text in
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progress.fraction, total: 1)
                    .progressViewStyle(.linear)
                Text(verbatim: text)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(idealWidth: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Scan")
            .accessibilityValue(text)
        }
    }
}

/// Gleicher Ablauf für sichtbaren Text und den Wert des zugänglichen Toolbar-Buttons.
struct ScanProgressText<Content: View>: View {
    let progress: ScanProgress
    @ViewBuilder let content: (String) -> Content
    @State private var displayTime = ContinuousClock.now

    var body: some View {
        // Bei erneutem Anzeigen oder neuen Daten auch ohne abgelaufene Task frisch prüfen.
        content(ScanProgressView.valueText(progress, at: max(displayTime, .now)))
            .task(id: progress.estimateExpiresAt) {
                guard let deadline = progress.estimateExpiresAt, deadline > .now else { return }
                do {
                    try await ContinuousClock().sleep(until: deadline)
                    try Task.checkCancellation()
                    displayTime = .now
                } catch { /* Neue Prognose, Scan-Ende oder ausgeblendete Anzeige. */ }
            }
    }
}

#Preview("Erster Scan – ohne Prognose") {
    ScanProgressView(progress: ScanProgress(fraction: 0.25))
        .frame(width: 200).padding()
}

#Preview("Scan – mit Restdauer") {
    ScanProgressView(progress: ScanProgress(fraction: 0.62, remainingSeconds: 18))
        .frame(width: 200).padding()
}

#Preview("Scan – fertig") {
    ScanProgressView(progress: ScanProgress(fraction: 1))
        .frame(width: 200).padding()
}
