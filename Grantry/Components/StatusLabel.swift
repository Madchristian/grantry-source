import ManagerKit
import SwiftUI

/// Zustandszeile mit farbigem SF Symbol oder Fortschrittsanzeige.
struct StatusLabel: View {
    enum Status {
        case toned(PresentationTone, String)
        case loading(String)

        static func ok(_ text: String) -> Status { .toned(.positive, text) }
        static func warning(_ text: String) -> Status { .toned(.warning, text) }
        static func failed(_ text: String) -> Status { .toned(.critical, text) }
    }

    private let status: Status

    init(_ status: Status) {
        self.status = status
    }

    var body: some View {
        switch status {
        case .toned(let tone, let text):
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: tone.systemImage).foregroundStyle(tone.color)
            }
        case .loading(let text):
            HStack {
                ProgressView().controlSize(.small)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension StatusLabel.Status {
    /// Deutsche Darstellung eines Helper-Zustands (`HelperStatePresentation`).
    init(_ state: HelperState) {
        let presentation = HelperStatePresentation(state)
        self = .toned(presentation.tone, presentation.text)
    }
}
