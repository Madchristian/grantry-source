import Foundation
import Testing
@testable import ManagerKit

@Suite struct NetworkActivityTextsTests {
    @Test func scalesUnits() {
        #expect(TrafficFormat.rate(0) == "0 B/s")
        #expect(TrafficFormat.rate(512.4) == "512 B/s")
        #expect(TrafficFormat.rate(1234) == "1,2 KB/s")
        #expect(TrafficFormat.rate(34_000) == "34 KB/s")
        #expect(TrafficFormat.rate(3_400_000) == "3,4 MB/s")
        #expect(TrafficFormat.bytes(1_100_000_000) == "1,1 GB")
        #expect(TrafficFormat.bytes(999) == "999 B")
        #expect(TrafficFormat.rate(-5) == "0 B/s")
    }

    /// Erst gerundet, dann die Einheit gewählt: nie „1000 KB“ oder „10,0 KB“.
    @Test func roundsBeforeChoosingUnit() {
        #expect(TrafficFormat.bytes(999_499) == "999 KB")
        #expect(TrafficFormat.bytes(999_500) == "1,0 MB")
        #expect(TrafficFormat.bytes(999_999) == "1,0 MB")
        #expect(TrafficFormat.rate(999.6) == "1,0 KB/s")
        #expect(TrafficFormat.rate(9_960) == "10 KB/s")
        #expect(TrafficFormat.rate(9_940) == "9,9 KB/s")
    }

    @Test func mapsSamplerErrors() {
        #expect(NetworkActivityFailure(.launchFailed(reason: "fehlt")) == .unavailable(reason: "fehlt"))
        #expect(NetworkActivityFailure(.unrecognizedFormat) == .unrecognizedFormat)
        #expect(NetworkActivityFailure(.endedRepeatedly(count: 3)) == .endedRepeatedly)
        #expect(NetworkActivityFailure(.endedRepeatedly(count: 7)) == .endedRepeatedly)
    }

    /// Der Sampler meldet 3 (Läufe ohne Messung) oder 7 (instabile Läufe) – der Text nennt keine feste Zahl.
    @Test func noticeForRepeatedEndsOffersRetryWithoutCount() throws {
        let notice = try #require(NetworkActivityNotice.make(failure: .endedRepeatedly, skippedLineCount: 0,
                                                             systemVersion: "27.0.1"))
        #expect(notice.headline == "Netzwerkaktivität nicht verfügbar – nettop wurde wiederholt beendet")
        #expect(notice.offersRetry)
        #expect(notice.tone == .critical)
    }

    @Test func noticeForLaunchFailureOffersRetry() throws {
        let notice = try #require(NetworkActivityNotice.make(failure: .unavailable(reason: "Datei nicht gefunden"),
                                                             skippedLineCount: 0, systemVersion: "27.0.1"))
        #expect(notice.headline == "Netzwerkaktivität nicht verfügbar – nettop ließ sich nicht starten")
        #expect(notice.reasons == ["Datei nicht gefunden"])
        #expect(notice.offersRetry)
        #expect(notice.tone == .critical)
    }

    @Test func noticeForUnknownFormatNamesSystemVersionWithoutRetry() throws {
        let notice = try #require(NetworkActivityNotice.make(failure: .unrecognizedFormat, skippedLineCount: 4,
                                                             systemVersion: "27.0.1"))
        #expect(notice.headline == "Ausgabeformat von nettop nicht erkannt (macOS 27.0.1)")
        #expect(!notice.offersRetry)
    }

    @Test func noticeForSkippedLinesIsAWarning() throws {
        #expect(NetworkActivityNotice.make(failure: nil, skippedLineCount: 0, systemVersion: "27.0") == nil)
        let notice = try #require(NetworkActivityNotice.make(failure: nil, skippedLineCount: 3, systemVersion: "27.0"))
        #expect(notice.tone == .warning)
        #expect(notice.reasons == ["3 Verbindungszeilen von nettop nicht lesbar – diese Verbindungen fehlen."])
        let single = try #require(NetworkActivityNotice.make(failure: nil, skippedLineCount: 1, systemVersion: "27.0"))
        #expect(single.reasons.first?.hasPrefix("1 Verbindungszeile von") == true)
    }
}
