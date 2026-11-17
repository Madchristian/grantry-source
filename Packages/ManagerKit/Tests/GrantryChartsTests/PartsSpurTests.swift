import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Spur mit Anteilen (Übersichts-Baukasten, Kachel Arbeitsspeicher, #502): Teile hintereinander in ihren Farben, Kerben
/// nur zwischen gefüllten Teilen, der Rest ist die Bahn. Aus Formen, nie `Canvas` (#491). Neu aufzeichnen mit
/// `GRANTRY_RECORD_SNAPSHOTS=1`.
@MainActor
@Suite struct PartsSpurTests {
    nonisolated static let appearances = ChartAppearance.allCases

    /// Kerben trennen benachbarte Teile; am Anfang, am Ende und hinter leeren Teilen steht keine.
    @Test func notchesSitBetweenFilledParts() {
        #expect(PartsSpur.notches([0.25, 0.125, 0.125]) == [0.25, 0.375])
        #expect(PartsSpur.notches([0.5, 0, 0.25]) == [0.5])
        #expect(PartsSpur.notches([0.6, 0.6]) == [0.6])
        #expect(PartsSpur.notches([1]).isEmpty)
        #expect(PartsSpur.notches([]).isEmpty)
    }

    /// VoiceOver liest die Teile mit Namen, die Farbe allein trägt keine Bedeutung.
    @Test func spokenValueListsTheParts() {
        let spur = PartsSpur(parts: PartsSpurGallery.memory, label: "Belegt", value: "App 25 %, Zug. 13 %, Kompr. 13 %")
        #expect(spur.value == "App 25 %, Zug. 13 %, Kompr. 13 %")
    }

    @Test(arguments: appearances)
    func snapshot(_ appearance: ChartAppearance) throws {
        try ChartSnapshot.verify(PartsSpurGallery.view, named: "baukasten-anteile", size: PartsSpurGallery.size,
                                 appearance: appearance)
    }
}

/// Speicher mit drei Teilen, ein volles und ein leeres Band, wie die Kachel Arbeitsspeicher sie zeigt.
@MainActor
enum PartsSpurGallery {
    static let size = CGSize(width: 240, height: 80)
    static let memory = [ValueRing.Part(fraction: 0.38, hue: .memory), ValueRing.Part(fraction: 0.15, hue: .sent),
                         ValueRing.Part(fraction: 0.08, hue: .diskWrite)]

    static var view: some View {
        let examples = [memory, [ValueRing.Part(fraction: 0.7, hue: .memory), ValueRing.Part(fraction: 0.5, hue: .sent)], []]
        return VStack(spacing: InstrumentSpacing.group) {
            ForEach(examples.indices, id: \.self) { index in
                PartsSpur(parts: examples[index], label: "", value: "").frame(height: InstrumentSize.spurList)
            }
        }
        .instrumentPanel()
        .padding(InstrumentSpacing.page)
        .frame(width: size.width, alignment: .topLeading)
    }
}
