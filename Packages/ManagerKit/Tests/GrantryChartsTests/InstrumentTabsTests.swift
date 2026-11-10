import AppKit
import SwiftUI
import Testing
@testable import GrantryCharts

/// Tab-Leiste im Inhalt (#463): Bei jeder Breite stehen alle Segmente innerhalb der Leiste – erst in einer Zeile, sonst
/// kompakt, zuletzt umbrochen in ausgeglichene Zeilen. Vorher lag die Auswahl in der Symbolleiste und verschwand bei
/// zehn Tabs komplett im Überlaufmenü.
@MainActor
@Suite struct InstrumentTabsTests {
    private static let size = CGSize(width: 60, height: 20)

    /// Rahmen gelten als Zeilen, wenn sie dieselbe Oberkante haben.
    private static func rows(_ frames: [CGRect]) -> [[CGRect]] {
        Dictionary(grouping: frames, by: \.minY).sorted { $0.key < $1.key }.map(\.value)
    }

    @Test func staysInOneRowWithoutWidthLimit() {
        let frames = SegmentRows.frames(for: Array(repeating: Self.size, count: 10), maxWidth: nil, spacing: 2)
        #expect(Self.rows(frames).count == 1)
        #expect(frames.last?.maxX == CGFloat(10 * 60 + 9 * 2))
    }

    @Test func wrapsWithinTheWidthInOrder() {
        let widths: [CGFloat] = [40, 47, 54, 61, 40, 47, 54, 61, 40, 47]
        let sizes = widths.map { CGSize(width: $0, height: 20) }
        let frames = SegmentRows.frames(for: sizes, maxWidth: 230, spacing: 2)
        #expect(frames.count == sizes.count)
        #expect(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= 230 })
        #expect(zip(frames, sizes).allSatisfy { $0.size == $1 })
        // Lesereihenfolge bleibt erhalten: jede Zeile von links nach rechts, Zeilen von oben nach unten, ohne Überlappung.
        for (previous, next) in zip(frames, frames.dropFirst()) {
            #expect(next.minY > previous.minY || (next.minY == previous.minY && next.minX >= previous.maxX))
            #expect(next.minY == previous.minY || next.minY >= previous.maxY)
        }
    }

    /// Statt 7 + 3 Segmente stehen 5 + 5 – ruhiger und gleich hoch.
    @Test func balancesTheRows() {
        let frames = SegmentRows.frames(for: Array(repeating: Self.size, count: 10), maxWidth: 440, spacing: 2)
        #expect(Self.rows(frames).map(\.count) == [5, 5])
    }

    @Test func givesAnOversizedSegmentItsOwnRow() {
        let sizes = [Self.size, CGSize(width: 300, height: 20), Self.size]
        let frames = SegmentRows.frames(for: sizes, maxWidth: 200, spacing: 2)
        #expect(Self.rows(frames).map(\.count) == [1, 1, 1])
        #expect(frames.allSatisfy { $0.minX == 0 })
    }

    private static let titles = ["Übersicht", "Prozesse", "Leistung", "Chip", "Details", "Energie", "App-Verlauf",
                                 "Wachbuch", "Benutzer", "Dienste"]

    private static func tabs(width: CGFloat?) -> some View {
        InstrumentTabs("Ansicht", selection: .constant(titles[9]), options: titles.map { ($0, $0) }) {
            Color.gray.frame(width: 180, height: 22)
        }
        .frame(width: width)
    }

    private static func renderedSize(width: CGFloat?) throws -> CGSize {
        let renderer = ImageRenderer(content: tabs(width: nil))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.nsImage).size
    }

    /// Schmalste Leiste im Fenster: 900 pt Mindestbreite, 240 pt Seitenleiste, 14 pt Seitenrand je Seite.
    @Test func fitsTheNarrowestWindowWithAllSegments() throws {
        let narrowest: CGFloat = 900 - 240 - 2 * 14
        let ideal = try Self.renderedSize(width: nil)
        #expect(ideal.width > narrowest, "die Probe muss breiter als die Leiste sein, sonst prüft sie nichts")
        let fitted = try Self.renderedSize(width: narrowest)
        #expect(fitted.width <= narrowest, "Leiste ragt über den Rand: \(fitted.width) pt")
        // Umbrochen statt abgeschnitten: Die Segmente stehen in mehr als einer Zeile.
        #expect(fitted.height > ideal.height)
    }

    @Test func staysInOneLineWhenThereIsRoom() throws {
        let ideal = try Self.renderedSize(width: nil)
        #expect(try Self.renderedSize(width: ideal.width + 100).height == ideal.height)
    }
}
