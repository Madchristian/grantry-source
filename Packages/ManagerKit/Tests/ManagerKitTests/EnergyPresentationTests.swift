import Testing
@testable import ManagerKit

@Suite struct EnergyPresentationTests {
    /// Bewertung 2026.11.7-1188, Mangel 14: Der Helper liefert keine Energie je Prozess (nur `powermetrics` für Chip
    /// und Leistungsaufnahme). Der Hinweis darf sie also weder ohne noch mit bereitem Helper versprechen.
    @Test func foreignNotePromisesNothingFromTheHelper() {
        #expect(!EnergyPresentation.foreignNote.contains("Helper"))
        #expect(EnergyPresentation.foreignNote.contains("anderer Benutzer"))
    }

    @Test(arguments: [(0.0, EnergyLevel.veryLow), (99, .veryLow), (100, .low), (499, .low), (500, .moderate),
                      (1_499, .moderate), (1_500, .high), (3_999, .high), (4_000, .veryHigh), (40_000, .veryHigh)])
    func levelFollowsThresholds(milliwatts: Double, level: EnergyLevel) {
        #expect(EnergyLevel(milliwatts: milliwatts) == level)
    }

    @Test func levelsHaveWindowsTitlesAndRisingHeat() {
        #expect(EnergyLevel.allCases.map(\.title) == ["Sehr niedrig", "Niedrig", "Mittel", "Hoch", "Sehr hoch"])
        let heats = EnergyLevel.allCases.map(\.heat)
        #expect(heats == heats.sorted())
        #expect(heats.last == 1)
    }

    @Test(arguments: [(nil, "–"), (0.4, "0 mW"), (350.4, "350 mW"), (999.6, "1,0 W"), (2_730, "2,7 W"),
                      (88_619, "89 W")] as [(Double?, String)])
    func powerText(milliwatts: Double?, text: String) {
        #expect(EnergyFormat.power(milliwatts) == text)
    }

    @Test(arguments: [(0.0, "0 mWh"), (36, "10 mWh"), (12_240, "3,4 Wh"), (180_000, "50 Wh")])
    func energyText(joules: Double, text: String) {
        #expect(EnergyFormat.energy(joules: joules) == text)
    }

    @Test func energyColumnsShowRateAndTrendLevel() {
        let figures = ProcessFigures(cpuLoad: 0.1, memoryBytes: nil, diskPerSecond: nil, networkPerSecond: nil,
                                     energyMilliwatts: 2_730, energyTrendMilliwatts: 420)
        #expect(ProcessColumn.energy.text(figures) == "2,7 W")
        #expect(ProcessColumn.energyTrend.text(figures) == "Niedrig")
        #expect(ProcessColumn.energy.value(figures) == 2_730)
        #expect(ProcessColumn.energyTrend.value(figures) == 420)
        #expect(ProcessColumn.energyTrend.heat(figures, physicalMemory: 1) == EnergyLevel.low.heat)
        #expect(ProcessColumn.energy.heat(figures, physicalMemory: 1) == (2_730.0 / 5_000).squareRoot())
    }

    @Test func unmeasuredEnergyIsDash() {
        let figures = ProcessFigures(cpuLoad: nil, memoryBytes: nil, diskPerSecond: nil, networkPerSecond: nil)
        #expect(ProcessColumn.energy.text(figures) == "–")
        #expect(ProcessColumn.energyTrend.text(figures) == "–")
        #expect(ProcessColumn.energy.heat(figures, physicalMemory: 1) == nil)
        #expect(ProcessColumn.energyTrend.heat(figures, physicalMemory: 1) == nil)
    }

    @Test func tabSortsByEnergyAndCollapsesSystem() {
        let options = EnergyPresentation.defaultOptions
        #expect(options.sort == ProcessSort(column: .energy, ascending: false))
        #expect(options.collapsedGroups == [.system])
        #expect(EnergyPresentation.columns == [.energy, .energyTrend, .cpu])
    }

    #if DEBUG
    @Test func headerTotalsCarryEnergy() {
        let presentation = ProcessListPresenter.present(
            ProcessListPreviewData.snapshot, apps: ProcessListPreviewData.apps,
            currentUID: ProcessListPreviewData.currentUID, network: nil, options: ProcessListOptions()
        )
        #expect(presentation.headerValue(.energy) == "–")
    }
    #endif

    private static let onBattery = BatteryReading(
        charge: 0.62, source: .battery, minutesToEmpty: 254, cycleCount: 86, designCycleCount: 1_000,
        maximumCapacity: 0.976, condition: .normal, batteryMilliwatts: -14_200, systemMilliwatts: 14_200
    )

    @Test func batteryTextsOnBattery() {
        #expect(EnergyPresentation.chargeText(Self.onBattery) == "62 %")
        #expect(EnergyPresentation.stateText(Self.onBattery) == "Akkubetrieb")
        #expect(EnergyPresentation.batteryStats(Self.onBattery).map(\.title)
            == ["Leistungsaufnahme", "Akku", "Restlaufzeit", "Ladezyklen", "Maximale Kapazität", "Zustand"])
        #expect(EnergyPresentation.batteryStats(Self.onBattery).map(\.value)
            == ["14 W", "−14 W", "4:14 h", "86 von 1.000", "98 %", "Normal"])
    }

    @Test func batteryTextsWhileCharging() {
        let charging = BatteryReading(charge: 0.4, source: .externalPower, isCharging: true, minutesToFull: 45,
                                      condition: .serviceRecommended, batteryMilliwatts: 31_000)
        #expect(EnergyPresentation.stateText(charging) == "Lädt")
        let stats = EnergyPresentation.batteryStats(charging)
        #expect(stats.map(\.title) == ["Leistungsaufnahme", "Akku", "Voll in", "Ladezyklen", "Maximale Kapazität",
                                       "Zustand"])
        #expect(stats.map(\.value) == ["–", "+31 W", "0:45 h", "–", "–", "Service empfohlen"])
    }

    @Test func stateOnExternalPower() {
        #expect(EnergyPresentation.stateText(BatteryReading(charge: 1, source: .externalPower, isCharged: true))
            == "Voll geladen")
        #expect(EnergyPresentation.stateText(BatteryReading(charge: 0.8, source: .externalPower)) == "Netzteil")
    }

    @Test func powerGraphUsesSystemPowerOnlyWhenKnown() {
        #expect(EnergyPresentation.powerMetric(for: Self.onBattery) == .systemPower)
        #expect(EnergyPresentation.powerMetric(for: BatteryReading(charge: 0.5, source: .battery)) == .energyTotal)
        #expect(EnergyPresentation.powerMetric(for: nil) == .energyTotal)
        #expect(EnergyPresentation.powerTitle(for: .systemPower) == "Leistungsaufnahme")
        #expect(EnergyPresentation.powerTitle(for: .energyTotal) == "Eigene Prozesse")
    }

    @Test func chargeHeatIsWarmWhenEmpty() {
        #expect(EnergyPresentation.chargeHeat(Self.onBattery) < EnergyPresentation.chargeHeat(
            BatteryReading(charge: 0.1, source: .battery)))
    }

    private static let adapter = PowerAdapterReading(watts: 100, name: "pd charger")

    @Test func chargingPanelOnlyWithBatteryAndAdapter() {
        #expect(EnergyPresentation.chargingPanel(for: nil) == nil)
        #expect(EnergyPresentation.chargingPanel(for: Self.onBattery) == nil)
        #expect(EnergyPresentation.chargingPanel(for: BatteryReading(charge: 0.8, source: .externalPower)) == nil)
    }

    @Test func chargingPanelWhileCharging() throws {
        let battery = BatteryReading(charge: 0.4, source: .externalPower, isCharging: true, batteryMilliwatts: 31_000,
                                     systemMilliwatts: 24_000, adapter: Self.adapter)
        let panel = try #require(EnergyPresentation.chargingPanel(for: battery))
        #expect(panel.detail == "pd charger")
        // Das Netzteil liefert, was der Mac aufnimmt, und die Ladeleistung (`SystemPowerIn`).
        #expect(panel.value == "55 W")
        #expect(panel.fraction == 0.55)
        #expect(panel.stats.map(\.title) == ["Netzteil", "Ladeleistung", "Ladezustand", "Auslastung"])
        #expect(panel.stats.map(\.value) == ["100 W", "31 W", "Lädt", "55 %"])
        #expect(panel.note == nil)
    }

    /// Befund 10.11.2026 (65-W-Netzteil, 77 %, 24 W): Am Netzteil ohne Laden ruht der Akku – 0 W am Akku und als
    /// Ladeleistung sind gemessen und richtig. Die Auslastung des Netzteils ist aber nicht 0 %: Es versorgt den Mac.
    @Test func chargingPanelWhenNotCharging() throws {
        let held = BatteryReading(charge: 0.77, source: .externalPower, batteryMilliwatts: 0, systemMilliwatts: 24_000,
                                  adapter: PowerAdapterReading(watts: 65, name: "pd charger"))
        let panel = try #require(EnergyPresentation.chargingPanel(for: held))
        #expect(panel.value == "24 W")
        #expect(try #require(panel.fraction) > 0.36 && panel.fraction! < 0.37)
        #expect(panel.stats.map(\.value) == ["65 W", "0 W", "Lädt nicht", "37 %"])
        #expect(panel.note == EnergyPresentation.notChargingNote)
        #expect(EnergyPresentation.batteryStats(held)[1] == PerformanceStat("Akku", "0 W"))
        let full = BatteryReading(charge: 1, source: .externalPower, isCharged: true, batteryMilliwatts: 0,
                                  adapter: Self.adapter)
        let fullPanel = try #require(EnergyPresentation.chargingPanel(for: full))
        #expect(fullPanel.stats[2].value == "Voll geladen")
        #expect(fullPanel.note == nil)
    }

    /// Ladeschutz bei 80 %, der Akku gibt trotzdem etwas ab: Das Netzteil liefert nur den Rest.
    @Test func adapterPowerExcludesBatteryDischarge() throws {
        let held = BatteryReading(charge: 0.8, source: .externalPower, batteryMilliwatts: -4_288,
                                  systemMilliwatts: 14_288, adapter: Self.adapter)
        let panel = try #require(EnergyPresentation.chargingPanel(for: held))
        #expect(panel.stats.map(\.value) == ["100 W", "0 W", "Lädt nicht", "10 %"])
    }

    /// Nicht Gemessenes erscheint als „–“, nie als 0.
    @Test func chargingPanelShowsMissingValuesAsDash() throws {
        let battery = BatteryReading(charge: nil, source: .externalPower, isCharging: true,
                                     adapter: PowerAdapterReading(watts: nil, name: nil))
        let panel = try #require(EnergyPresentation.chargingPanel(for: battery))
        #expect(panel.detail.isEmpty)
        #expect(panel.value == "–")
        #expect(panel.fraction == nil)
        #expect(panel.stats.map(\.value) == ["–", "–", "Lädt", "–"])
        let withoutSystem = BatteryReading(charge: 0.5, source: .externalPower, batteryMilliwatts: 0,
                                           adapter: Self.adapter)
        let unknownLoad = try #require(EnergyPresentation.chargingPanel(for: withoutSystem))
        #expect(unknownLoad.value == "–")
        #expect(unknownLoad.stats.map(\.value) == ["100 W", "0 W", "Lädt nicht", "–"])
    }

    @Test func chargingFractionStaysWithinAdapterRating() throws {
        let battery = BatteryReading(charge: 0.2, source: .externalPower, isCharging: true, batteryMilliwatts: 90_000,
                                     systemMilliwatts: 50_000, adapter: Self.adapter)
        #expect(try #require(EnergyPresentation.chargingPanel(for: battery)).fraction == 1)
    }
}
