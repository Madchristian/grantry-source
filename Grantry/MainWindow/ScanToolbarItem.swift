import ManagerKit
import SwiftUI

/// „Jetzt scannen“ mit Fortschrittsanzeige, solange ein Scan läuft.
struct ScanToolbarItem: ToolbarContent {
    let isScanning: Bool
    var progress = ScanProgress()
    var pendingSignatureChecks = 0
    var signatureChecksTimedOut = false
    let action: () -> Void

    private var signatureStatus: String? {
        if pendingSignatureChecks > 0 {
            return String(localized: "Signaturen: \(pendingSignatureChecks) offen")
        }
        if signatureChecksTimedOut { return String(localized: "Prüfung unvollständig") }
        return nil
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ScanProgressText(progress: isScanning ? progress : ScanProgress()) { valueText in
                Button(action: action) {
                    Label {
                        if let signatureStatus {
                            Text(verbatim: signatureStatus)
                        } else {
                            Text("Jetzt scannen")
                        }
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                        .frame(width: 180)
                        .opacity(isScanning ? 0 : 1)
                        .overlay {
                            if isScanning {
                                ScanProgressView(progress: progress)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .disabled(isScanning)
                .accessibilityLabel("Jetzt scannen")
                .accessibilityValue(isScanning ? valueText : signatureStatus ?? "Bereit")
                .accessibilityIdentifier("scanToolbarControl")
                .help(isScanning ? "Scan läuft" : signatureStatus != nil
                    ? "Inventarscan beendet; Signaturprüfung läuft oder ist unvollständig. Erneut scannen ist möglich." : "Jetzt scannen")
            }
        }
    }
}

