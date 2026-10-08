import ManagerKit
import SwiftUI

extension PresentationTone {
    /// Konkrete Farbe des semantischen Tons – die einzige Abbildung Ton → Farbe in der App.
    var color: Color {
        switch self {
        case .positive: .green
        case .neutral: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }
}

extension RecordBadge {
    /// Farbe des Badges: „neu“ grün (Spec §6), sonst die Farbe des Tons.
    var color: Color {
        switch self {
        case .new: PresentationTone.positive.color
        case .review, .cleanup: tone.color
        }
    }
}
