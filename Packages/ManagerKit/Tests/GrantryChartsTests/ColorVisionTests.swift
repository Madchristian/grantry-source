import Foundation
import Testing
@testable import GrantryCharts

/// Kernarten in der Übersicht der Menüleiste und im Chip-Tab (#495, Abnahme Christian 09.11.2026): Leistungskerne
/// (`cpu`) und Effizienzkerne (`efficiencyCores`) müssen sich in hell, dunkel und bei „Kontrast erhöhen“ auch bei
/// Rot-, Grün- und Blau-Sehschwäche deutlich unterscheiden. Simulation nach Machado, Oliveira und Fernandes (2009,
/// Schweregrad 1), Abstand als euklidischer Abstand in CIELAB.
@Suite struct ColorVisionTests {
    typealias Matrix = [[Double]]

    static let visions: [String: Matrix?] = [
        "normal": nil,
        "protan": [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
        "deutan": [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
        "tritan": [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]],
    ]
    /// Dunkel unverändert, hell ×0,62, „Kontrast erhöhen“ ×0,42 (`InstrumentHue.color(in:increasedContrast:)`).
    static let shades = [1.0, 0.62, 0.42]
    /// Ab etwa 10 gelten Farben auf einen Blick als verschieden; Türkis gegen das frühere Himmelblau lag bei 5.
    static let minimumDistance = 20.0

    static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    static func lab(_ linear: [Double]) -> [Double] {
        let (r, g, b) = (linear[0], linear[1], linear[2])
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))]
    }

    /// Lab-Wert der Messgrößenfarbe in `shade`, wie ein Mensch mit `vision` sie sieht.
    static func seen(_ hue: InstrumentHue, shade: Double, vision: Matrix?) -> [Double] {
        let rgb = [hue.base.red, hue.base.green, hue.base.blue].map { linear($0 * shade) }
        guard let vision else { return lab(rgb) }
        return lab(vision.map { row in min(max(zip(row, rgb).map(*).reduce(0, +), 0), 1) })
    }

    static func smallestDistance(_ first: InstrumentHue, _ second: InstrumentHue) -> Double {
        shades.flatMap { shade in
            visions.values.map { vision in
                let (a, b) = (seen(first, shade: shade, vision: vision), seen(second, shade: shade, vision: vision))
                return sqrt(zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
            }
        }.min() ?? 0
    }

    @Test func performanceAndEfficiencyCoresStayApart() {
        #expect(Self.smallestDistance(.cpu, .efficiencyCores) >= Self.minimumDistance)
    }
}
