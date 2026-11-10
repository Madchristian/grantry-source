import Testing
@testable import GrantryCharts

/// Zeitachse und Beschriftungen langer Zeiträume (Leistungsverlauf aus dem Wachbuch, TM-14.5).
@Suite struct TrendGraphTests {
    /// Kurze Fenster wie bisher in Sekunden bzw. Minuten, ab 2 h in Stunden, ab 2 Tagen in Tagen.
    @Test(arguments: [
        (60.0, ["−60 s", "−30 s", "jetzt"]),
        (900.0, ["−15 min", "−7 min", "jetzt"]),
        (3_600.0, ["−60 min", "−30 min", "jetzt"]),
        (21_600.0, ["−6 h", "−3 h", "jetzt"]),
        (86_400.0, ["−24 h", "−12 h", "jetzt"]),
        (604_800.0, ["−7 Tage", "−3,5 Tage", "jetzt"]),
    ])
    func timeAxisLabels(window: Double, expected: [String]) {
        #expect(TimeAxisLabels.labels(window: window) == expected)
    }

    /// Alter am Fadenkreuz: Minuten, Stunden mit Minuten, ab zwei Tagen Tage mit Stunden.
    @Test(arguments: [
        (30.0, "vor 0 min"),
        (600.0, "vor 10 min"),
        (7_200.0, "vor 2 h"),
        (8_040.0, "vor 2 h 14 min"),
        (100_800.0, "vor 28 h"),
        (190_800.0, "vor 2 Tagen 5 h"),
        (259_200.0, "vor 3 Tagen"),
    ])
    func age(seconds: Double, expected: String) {
        #expect(TrendGraph.age(seconds) == expected)
    }

    /// Alle Reihen teilen eine Skala; sie reicht über die größte, nicht nur über die Hauptreihe.
    @Test func linesShareOneScale() {
        let main = ChartSeries(values: [2, nil, 3], spacing: 60, latest: .distantPast)
        let other = ChartSeries(values: [nil, 14, 1], spacing: 60, latest: .distantPast)
        let scale = TrendGraph.sharedScale([main, other], minimum: 5)
        #expect(scale == .fixed(0...20))
    }
}
