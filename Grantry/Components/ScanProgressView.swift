import ManagerKit
import SwiftUI

/// Darstellende Scan-Anzeige mit genau einer abbrechbaren Warteaufgabe je Prognose.
/// Kein Polling; SwiftUI beendet die Aufgabe beim Ausblenden und bei neuer Prognose.
struct ScanProgressView: View {
    let progress: ScanProgress

    static func valueText(_ progress: ScanProgress, at now: ContinuousClock.Instant = .now) -> String {
        if progress.isIndeterminate { return String(localized: "Scan läuft …") }
        let percent = Int((progress.fraction * 100).rounded(.down))
        guard let remaining = progress.remainingSeconds(at: now) else { return String(localized: "\(percent) %") }
        let seconds = Int(min(86_400, ceil(remaining / 5) * 5))
        return String(localized: "\(percent) % · noch ca. \(max(5, seconds)) s")
    }

    var body: some View {
        ScanProgressText(progress: progress) { text in
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if progress.isIndeterminate {
                        ProgressView()
                    } else {
                        ProgressView(value: progress.fraction, total: 1)
                    }
                }
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

/// Leiste direkt über einer Tabelle, solange der Scan ihres Segments läuft (#262, #270): Balken über die gesamte
/// Tabellenbreite, Restdauer darunter.
struct ScanProgressStrip: View {
    let progress: ScanProgress

    var body: some View {
        ScanProgressView(progress: progress)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}

extension View {
    /// Setzt die Scan-Leiste des Segments über diese Tabelle, solange `progress` einen Lauf zeigt.
    func scanProgressAboveTable(_ progress: SegmentScanProgress) -> some View {
        modifier(ScanProgressAboveTable(progress: progress))
    }
}

private struct ScanProgressAboveTable: ViewModifier {
    let progress: SegmentScanProgress

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if let current = progress.current { ScanProgressStrip(progress: current) }
            content
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

#Preview("Scan – zu kurz, unbestimmt") {
    ScanProgressView(progress: ScanProgress(isIndeterminate: true))
        .frame(width: 200).padding()
}

#Preview("Scan – fertig") {
    ScanProgressView(progress: ScanProgress(fraction: 1))
        .frame(width: 200).padding()
}
