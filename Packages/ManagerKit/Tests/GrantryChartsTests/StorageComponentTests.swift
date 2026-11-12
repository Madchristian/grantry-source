import SwiftUI
import Testing
@testable import GrantryCharts

/// Bausteine des Speichers im Lagebild (LB-4.3, #549; Spec 2026-11-10 § 11.4 c): Kopf einer Kategorie mit Spur des Anteils
/// und Eintrag nur zum Bericht. Jedes Element liest Beschriftung und Wert (#563).
@MainActor
@Suite struct StorageComponentTests {
    @Test func categoryHeadReadsSizeShareRiskAndStatus() {
        #expect(StorageCategoryHead.spokenValue(size: "18,6 GB", share: 0.654, risk: StatusItem("Risiko gering", tone: .neutral),
                                                status: nil, summary: "Zwischenstände")
            == "18,6 GB, \(percent(0.654)) des Aufräumbaren, Risiko gering, Zwischenstände")
        #expect(StorageCategoryHead.spokenValue(size: "–", share: nil, risk: StatusItem("Risiko gering", tone: .neutral),
                                                status: StatusItem("nicht erfasst", tone: .finding), summary: "")
            == "–, Risiko gering, nicht erfasst")
    }

    @Test func reportRowReadsDetailAndSize() {
        #expect(ReportRow<EmptyView>.spokenValue(detail: "nur mit Befehl entfernbar", size: "3,1 GB")
            == "nur mit Befehl entfernbar, 3,1 GB")
        #expect(ReportRow<EmptyView>.spokenValue(detail: "", size: "3,1 GB") == "3,1 GB")
    }
}

/// Was VoiceOver im Speicher liest: Kategorie als Aufklapp-Knopf mit Größe, Anteil und Zustand, Bericht-Eintrag mit
/// Grund und Größe, Knopf mit Ziel (Spec § 7).
@MainActor
@Suite(.serialized) struct StorageAccessibilityTests {
    @Test func categoryAndReportRowReadLabelAndValue() async throws {
        let nodes = try await AccessibilityTree.nodes(of: StorageSample(), size: CGSize(width: 800, height: 400))
        #expect(nodes.contains { $0.role == "AXButton" && $0.label == "Simulator-Laufzeiten"
                && $0.value == "3,1 GB, \(percent(0.11)) des Aufräumbaren, Risiko mittel, Nicht mehr benutzte Laufzeiten, aufgeklappt" },
                "\(nodes)")
        #expect(nodes.contains(AccessibilityTree.Node(role: "AXStaticText", label: "iOS 25.4",
                                                      value: "nur mit Befehl entfernbar, 3,1 GB")), "\(nodes)")
        #expect(nodes.contains { $0.role == "AXLink" && $0.label == "Befehl kopieren: iOS 25.4" }, "\(nodes)")
    }
}

/// Anteil wie in der Ansicht formatiert (mit geschütztem Leerzeichen vor dem Prozentzeichen).
private func percent(_ share: Double) -> String { share.formatted(.percent.precision(.fractionLength(0))) }

private struct StorageSample: View {
    @State private var isExpanded = true

    var body: some View {
        let risk = StatusItem("Risiko mittel", tone: .neutral)
        let summary = "Nicht mehr benutzte Laufzeiten"
        DisclosureSection("Simulator-Laufzeiten",
                          value: StorageCategoryHead.spokenValue(size: "3,1 GB", share: 0.11, risk: risk, status: nil,
                                                                 summary: summary),
                          isExpanded: $isExpanded, togglesOnHead: true) {
            StorageCategoryHead(title: "Simulator-Laufzeiten", summary: summary, risk: risk, status: nil,
                                size: "3,1 GB", share: 0.11)
        } content: {
            ReportRow(symbol: "terminal", title: "iOS 25.4", detail: "nur mit Befehl entfernbar", size: "3,1 GB") {
                Button("Befehl kopieren") {}.accessibilityLabel(Text(verbatim: "Befehl kopieren: iOS 25.4"))
            }
        }
        .frame(width: 800)
    }
}
