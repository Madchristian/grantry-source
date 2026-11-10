import SwiftUI

/// Graph ohne Werte mit Grund (§3.11): Der Rahmen bleibt, darin ein Satz und auf Wunsch ein Knopf – etwa „Wachbuch
/// einschalten“ für den längeren Leistungsverlauf (TM-14.5).
public struct GraphNotice: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: InstrumentSpacing.panel) {
            Text(verbatim: text)
                .font(InstrumentFont.body)
                .foregroundStyle(.instrumentSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) { Text(verbatim: actionTitle) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(InstrumentSpacing.empty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .graphFrame()
        .accessibilityElement(children: .contain)
    }
}
