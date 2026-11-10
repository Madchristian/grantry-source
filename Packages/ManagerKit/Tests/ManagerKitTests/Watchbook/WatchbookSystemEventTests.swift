import Foundation
import Testing
@testable import ManagerKit

/// Systemereignisse des Wachbuchs (Spec 2026-11-08 §5.1): Start, Ruhezustand, Aufwachen mit Grund und Wechsel von
/// Stromquelle, thermischem Zustand, Speicherdruck und Energiesparmodus.
@Suite struct WatchbookSystemEventTests {
    private let time = WatchbookFixtures.dayStart.addingTimeInterval(3_600)

    private func state(thermal: Double? = 0, pressure: Double? = 0, power: Double? = 1,
                       lowPower: Bool? = false) -> WatchbookSystemState {
        var values = WatchbookValues()
        values[.thermalState] = thermal
        values[.memoryPressure] = pressure
        values[.externalPower] = power
        return WatchbookSystemState(
            point: WatchbookPoint(time: time, values: values, cpuConsumers: [], memoryConsumers: []),
            isLowPowerModeEnabled: lowPower)
    }

    private func types(_ events: [WatchbookEvent]) -> [String] { events.map(\.type) }

    @Test func noEventsWithoutChange() {
        #expect(state().changes(since: state(), at: time).isEmpty)
    }

    @Test func firstStateIsNoChange() {
        #expect(state().changes(since: WatchbookSystemState(), at: time).isEmpty)
    }

    @Test func powerAdapterConnectedAndDisconnected() throws {
        let unplugged = state(power: 0).changes(since: state(power: 1), at: time)
        #expect(types(unplugged) == ["system.power-adapter-off"])
        #expect(types(state(power: 1).changes(since: state(power: 0), at: time)) == ["system.power-adapter-on"])
        let event = try #require(unplugged.first)
        #expect(event.kind == .system)
        #expect(event.start == time && event.end == time)
        #expect(event.tone == nil && event.subject == nil)
        #expect(event.summary == "Netzteil getrennt – der Mac läuft auf Akku.")
    }

    @Test func thermalStateChangeNamesTheNewState() {
        let events = state(thermal: 2).changes(since: state(thermal: 0), at: time)
        #expect(types(events) == ["system.thermal-state"])
        #expect(events.first?.summary == "Thermischer Zustand jetzt ernst.")
    }

    @Test func memoryPressureChangeNamesTheNewLevel() {
        let events = state(pressure: 2).changes(since: state(pressure: 1), at: time)
        #expect(types(events) == ["system.memory-pressure"])
        #expect(events.first?.summary == "Speicherdruck jetzt kritisch.")
    }

    @Test func lowPowerModeOnAndOff() {
        #expect(types(state(lowPower: true).changes(since: state(lowPower: false), at: time)) == ["system.low-power-on"])
        #expect(types(state(lowPower: false).changes(since: state(lowPower: true), at: time))
            == ["system.low-power-off"])
    }

    /// Nicht Gemessenes ist kein Wechsel; der letzte bekannte Wert bleibt Vergleichsbasis.
    @Test func unmeasuredValuesKeepTheLastKnownState() {
        let known = state(power: 1)
        let unmeasured = state(thermal: nil, pressure: nil, power: nil, lowPower: nil)
        #expect(unmeasured.changes(since: known, at: time).isEmpty)
        let merged = unmeasured.merged(over: known)
        #expect(types(state(power: 0).changes(since: merged, at: time)) == ["system.power-adapter-off"])
    }

    @Test func severalChangesAtOnce() {
        let events = state(thermal: 1, power: 0).changes(since: state(thermal: 0, power: 1), at: time)
        #expect(Set(types(events)) == ["system.power-adapter-off", "system.thermal-state"])
    }

    /// Derselbe Start ergibt dieselbe ID: Bei jedem App-Start erneut eingetragen, steht er im Wachbuch nur einmal.
    @Test func bootEventIsStableAcrossLaunches() {
        let boot = time.addingTimeInterval(-600)
        let first = WatchbookSystemEvent.boot(at: boot), second = WatchbookSystemEvent.boot(at: boot)
        #expect(first.id == second.id)
        #expect(first.type == "system.boot")
        #expect(first.start == boot && first.end == boot)
        #expect(WatchbookSystemEvent.boot(at: boot.addingTimeInterval(1)).id != first.id)
    }

    @Test func sleepSpansUntilWaking() {
        let event = WatchbookSystemEvent.sleep(from: time, to: time.addingTimeInterval(1_800))
        #expect(event.type == "system.sleep")
        #expect(event.start == time && event.end == time.addingTimeInterval(1_800))
        #expect(event.summary == "Ruhezustand.")
    }

    /// Der Grund kommt ungeprüft von macOS: einzeilig und begrenzt.
    @Test func wakeNamesItsReasonOnOneLine() {
        let event = WatchbookSystemEvent.wake(at: time, reason: "AOP.Outbox0_NotEmpty\nvoice_trigger")
        #expect(event.type == "system.wake")
        #expect(event.summary == "Aufgewacht, Grund laut macOS: AOP.Outbox0_NotEmpty voice_trigger.")
        #expect(WatchbookSystemEvent.wake(at: time, reason: nil).summary == "Aufgewacht.")
        let long = WatchbookSystemEvent.wake(at: time, reason: String(repeating: "x", count: 500))
        #expect(long.summary.count < 120)
    }
}
