import Foundation
import SwiftUI
import Testing

/// Vergleich mit dem Referenzbild `__Snapshots__/<Name>-<Erscheinungsbild>.png` (Spec 2026-11-06 §7). Fehlt die Referenz
/// oder ist `GRANTRY_RECORD_SNAPSHOTS=1` gesetzt, schreibt der Test sie und schlägt fehl: erst ansehen, dann einchecken.
/// Erlaubt sind höchstens 0,5 % Pixel mit mehr als 8 Stufen Abweichung – das fängt Farb-, Linien- und Layoutfehler, aber
/// kein Dithering. Bei einer Abweichung liegt das neue Bild im Temp-Ordner unter `GrantryChartSnapshots/`.
@MainActor
enum ChartSnapshot {
    static let references = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "__Snapshots__")
    static let maximumDifference = 0.005

    static var isRecording: Bool { ProcessInfo.processInfo.environment["GRANTRY_RECORD_SNAPSHOTS"] == "1" }

    static func verify(_ view: some View, named name: String, size: CGSize, appearance: ChartAppearance,
                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let file = "\(name)-\(appearance.rawValue).png"
        let image = try #require(ChartImage(view, size: size, appearance: appearance), "kein Bild für \(file)",
                                 sourceLocation: sourceLocation)
        #expect(image.coverage > 0.02, "\(file) ist fast leer", sourceLocation: sourceLocation)
        let reference = references.appending(path: file)
        guard !isRecording, let data = try? Data(contentsOf: reference), let expected = ChartImage(png: data) else {
            try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
            try #require(image.png).write(to: reference)
            let message = "Referenz aufgezeichnet: \(reference.path) – ansehen, einchecken und ohne "
                + "GRANTRY_RECORD_SNAPSHOTS erneut laufen lassen"
            Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
            return
        }
        let difference = image.difference(to: expected)
        guard difference > maximumDifference else { return }
        let failures = FileManager.default.temporaryDirectory.appending(path: "GrantryChartSnapshots")
        try FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
        try #require(image.png).write(to: failures.appending(path: file))
        let percent = (difference * 100).formatted(.number.precision(.fractionLength(2)))
        let message = "\(file): \(percent) % der Pixel weichen ab; neues Bild unter \(failures.path)"
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }
}
