import SwiftUI

/// „Jetzt scannen“ mit Fortschrittsanzeige, solange ein Scan läuft.
struct ScanToolbarItem: ToolbarContent {
    let isScanning: Bool
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: action) {
                Label("Jetzt scannen", systemImage: "arrow.clockwise")
                    .opacity(isScanning ? 0 : 1)
                    .overlay {
                        if isScanning {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .disabled(isScanning)
            .accessibilityLabel("Jetzt scannen")
            .accessibilityValue(isScanning ? "Scan läuft" : "Bereit")
            .accessibilityIdentifier("scanToolbarControl")
            .help(isScanning ? "Scan läuft" : "Jetzt scannen")
        }
    }
}

