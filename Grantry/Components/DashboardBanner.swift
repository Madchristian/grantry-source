import SwiftUI

/// Hinweis oben in der Übersicht: Symbol und Titel in `tint`, erklärender Text, rechts die Aktionen.
struct DashboardBanner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let text: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.headline)
                Text(verbatim: text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            actions()
        }
        .padding(12)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.3))
        }
    }
}
