import Foundation
import Testing
import ManagerKit

@Suite struct InstanceArbitrationTests {
    private typealias Instance = InstanceArbitration.Instance
    private static let early = Date(timeIntervalSince1970: 1_000)
    private static let late = Date(timeIntervalSince1970: 2_000)

    @Test func runsAloneWithoutOtherInstances() {
        let current = Instance(processIdentifier: 10, launchDate: Self.late)
        #expect(InstanceArbitration.instance(toDeferTo: [], current: current) == nil)
        #expect(InstanceArbitration.instance(toDeferTo: [current], current: current) == nil)
    }

    @Test func defersToTheEarlierInstance() {
        let current = Instance(processIdentifier: 10, launchDate: Self.late)
        let running = Instance(processIdentifier: 20, launchDate: Self.early)
        #expect(InstanceArbitration.instance(toDeferTo: [running], current: current) == running)
    }

    @Test func keepsRunningWhenTheOtherStartedLater() {
        let current = Instance(processIdentifier: 20, launchDate: Self.early)
        let newer = Instance(processIdentifier: 10, launchDate: Self.late)
        #expect(InstanceArbitration.instance(toDeferTo: [newer], current: current) == nil)
    }

    /// Gleichzeitig gestartet: Genau eine der beiden weicht (die mit der höheren PID).
    @Test func simultaneousLaunchesResolveToExactlyOneSurvivor() {
        let first = Instance(processIdentifier: 10, launchDate: Self.early)
        let second = Instance(processIdentifier: 11, launchDate: Self.early)
        #expect(InstanceArbitration.instance(toDeferTo: [first], current: second) == first)
        #expect(InstanceArbitration.instance(toDeferTo: [second], current: first) == nil)
    }

    @Test func unknownLaunchDateCountsAsEarlier() {
        let current = Instance(processIdentifier: 10, launchDate: Self.early)
        let unknown = Instance(processIdentifier: 30, launchDate: nil)
        #expect(InstanceArbitration.instance(toDeferTo: [unknown], current: current) == unknown)
    }

    @Test func defersToTheOldestOfSeveral() {
        let current = Instance(processIdentifier: 40, launchDate: Self.late.addingTimeInterval(10))
        let older = Instance(processIdentifier: 20, launchDate: Self.late)
        let oldest = Instance(processIdentifier: 30, launchDate: Self.early)
        #expect(InstanceArbitration.instance(toDeferTo: [older, oldest], current: current) == oldest)
    }

    /// Kennt das System keine der beiden Startzeiten, entscheidet die PID – für beide Seiten gleich.
    @Test func unknownLaunchDatesOnBothSidesResolveByProcessIdentifier() {
        let lower = Instance(processIdentifier: 10, launchDate: nil)
        let higher = Instance(processIdentifier: 11, launchDate: nil)
        #expect(InstanceArbitration.instance(toDeferTo: [lower], current: higher) == lower)
        #expect(InstanceArbitration.instance(toDeferTo: [higher], current: lower) == nil)
    }

    /// Für jedes Paar weicht genau eine Instanz – auch wenn eine Startzeit fehlt.
    @Test(arguments: [
        (Self.early, Self.late), (Self.early, Self.early), (nil, Self.late), (Self.early, nil), (nil, nil),
    ] as [(Date?, Date?)])
    func everyPairHasExactlyOneSurvivor(_ first: Date?, _ second: Date?) {
        let a = Instance(processIdentifier: 10, launchDate: first)
        let b = Instance(processIdentifier: 11, launchDate: second)
        let aDefers = InstanceArbitration.instance(toDeferTo: [b], current: a) != nil
        let bDefers = InstanceArbitration.instance(toDeferTo: [a], current: b) != nil
        #expect(aDefers != bDefers)
    }
}
