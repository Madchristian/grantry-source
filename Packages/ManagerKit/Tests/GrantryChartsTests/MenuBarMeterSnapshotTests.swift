import AppKit
import Foundation
import SwiftUI
import Testing
@testable import GrantryCharts

/// Menüleisten-Elemente (TM-17.2, #465) und ihr Popover (TM-17.3, #466) in hell, dunkel und „Kontrast erhöhen“.
/// Neu aufzeichnen mit `GRANTRY_RECORD_SNAPSHOTS=1`; `GRANTRY_GALLERY_DIR=<Ordner>` schreibt zusätzlich die Galerie
/// hell und dunkel für `docs/design/galerie`.
@MainActor
@Suite struct MenuBarMeterSnapshotTests {
    nonisolated static let scenes = ["elemente", "popover"].flatMap { scene in
        ChartAppearance.allCases.map { (scene, $0) }
    }

    @Test(arguments: SnapshotGallery.MeterKind.allCases)
    func everyStyleDrawsWithFixedHeight(_ kind: SnapshotGallery.MeterKind) {
        for style in kind.styles {
            let image = MenuBarMeterRenderer.image(for: SnapshotGallery.face(kind, style: style))
            #expect(image.size.width > 4, "\(kind) \(style) ist leer")
            #expect(image.size.height == MenuBarMeterRenderer.height)
            #expect(image.isTemplate)
        }
    }

    /// Die Breite folgt den breitesten möglichen Werten, nicht dem aktuellen: Elemente rechts davon springen nicht.
    @Test func widthStaysWhenTheValueChanges() {
        var face = SnapshotGallery.face(.cpu)
        let wide = MenuBarMeterRenderer.image(for: face).size.width
        face.lines = ["3 %"]
        #expect(MenuBarMeterRenderer.image(for: face).size.width == wide)
        face.lines = ["–"]
        #expect(MenuBarMeterRenderer.image(for: face).size.width == wide)
    }

    @Test func findingAddsRoomForTheDot() {
        let calm = MenuBarMeterRenderer.image(for: SnapshotGallery.face(.memory)).size.width
        #expect(MenuBarMeterRenderer.image(for: SnapshotGallery.face(.memory, finding: true)).size.width > calm)
    }

    /// Zeichenkosten je Takt (Spec 2026-11-09 § 6): alle acht Elemente in Standard-Darstellung als Bitmap in doppelter
    /// Auflösung gezeichnet, CPU-Zeit des Threads im Median über 20 Takte. 1 % eines Kerns bei 2 s Takt sind 20 ms; hier
    /// gilt ein Zehntel davon.
    @Test func drawingAllElementsIsCheap() throws {
        let faces = SnapshotGallery.MeterKind.allCases.map { SnapshotGallery.face($0) }
        func takt() {
            for face in faces {
                let image = MenuBarMeterRenderer.image(for: face)
                let size = NSSize(width: image.size.width * 2, height: image.size.height * 2)
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                                    pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0) else { return }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                image.draw(in: NSRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        takt()
        var costs: [UInt64] = []
        for _ in 0..<20 {
            let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            takt()
            costs.append(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before)
        }
        costs.sort()
        print("menuBarMeters draw cpu_us median=\(costs[10] / 1_000) max=\(costs[19] / 1_000)")
        #expect(costs[10] < 2_000_000)
    }

    @Test(arguments: scenes)
    func snapshot(_ scene: String, _ appearance: ChartAppearance) throws {
        if scene == "elemente" {
            try ChartSnapshot.verify(SnapshotGallery.menuBarGallery, named: "menubar-meters",
                                     size: SnapshotGallery.menuBarGallerySize, appearance: appearance)
        } else {
            try ChartSnapshot.verify(SnapshotGallery.popoverGallery, named: "menubar-meter-popover",
                                     size: SnapshotGallery.popoverGallerySize, appearance: appearance)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRANTRY_GALLERY_DIR"] != nil),
          arguments: [ChartAppearance.light, .dark])
    func gallery(_ appearance: ChartAppearance) throws {
        let directory = URL(filePath: try #require(ProcessInfo.processInfo.environment["GRANTRY_GALLERY_DIR"]))
        let name = appearance == .dark ? "dunkel" : "hell"
        let pages: [(String, AnyView, CGSize)] = [
            ("menueleiste", AnyView(SnapshotGallery.menuBarGallery), SnapshotGallery.menuBarGallerySize),
            ("menueleiste-einstellungen", AnyView(SnapshotGallery.settingsGallery), CGSize(width: 600, height: 610)),
            ("menueleiste-popover", AnyView(SnapshotGallery.popoverGallery), SnapshotGallery.popoverGallerySize),
        ]
        for (file, view, size) in pages {
            let image = try #require(ChartImage(view, size: size, appearance: appearance))
            try #require(image.png).write(to: directory.appending(path: "\(file)-\(name).png"))
        }
    }
}
