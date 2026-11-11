import AppKit
import Testing
@testable import GrantryCharts

/// Gerasterte Statusbilder (#570): Punktgrösse wie das Vektorbild, Inhalt über die ganze Bitmap – auf Retina zeigte
/// die Menüleiste sie sonst halb so gross im unteren linken Viertel.
@MainActor
@Suite struct MenuBarRasterTests {
    /// Vollflächiges Vorlagenbild in der Höhe der Menüleisten-Elemente, gezeichnet wie der Renderer (gespiegelt).
    private static func solid(width: CGFloat = 40) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: MenuBarMeterRenderer.height), flipped: true) { bounds in
            NSColor.black.setFill()
            bounds.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CPU, 12 %"
        return image
    }

    /// Kleinstes Rechteck aller deckenden Pixel, in Pixeln.
    private static func inkBounds(of bitmap: NSBitmapImageRep) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var bounds: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                bounds = (min(bounds?.minX ?? x, x), max(bounds?.maxX ?? x, x),
                          min(bounds?.minY ?? y, y), max(bounds?.maxY ?? y, y))
            }
        }
        return bounds
    }

    @Test(arguments: [1.0, 2.0, 3.0])
    func keepsPointSizeAndFillsTheWholeBitmap(scale: CGFloat) throws {
        let source = Self.solid()
        let raster = source.rasterized(scale: scale)
        #expect(raster.size == source.size)
        let bitmap = try #require(raster.representations.first as? NSBitmapImageRep)
        #expect(bitmap.size == source.size)
        #expect(bitmap.pixelsWide == Int(source.size.width * scale))
        #expect(bitmap.pixelsHigh == Int(source.size.height * scale))
        let ink = try #require(Self.inkBounds(of: bitmap))
        #expect(ink.minX == 0 && ink.maxX == bitmap.pixelsWide - 1, "Inhalt nur \(ink.minX)…\(ink.maxX) breit")
        #expect(ink.minY == 0 && ink.maxY == bitmap.pixelsHigh - 1, "Inhalt nur \(ink.minY)…\(ink.maxY) hoch")
    }

    @Test func keepsTemplateAndAccessibility() {
        let raster = Self.solid().rasterized(scale: 2)
        #expect(raster.isTemplate)
        #expect(raster.accessibilityDescription == "CPU, 12 %")
    }

    /// Ein echtes Element: gleiche Punktgrösse und bei Skalierung 2 die doppelte Ausdehnung des Inhalts wie bei 1.
    @Test func meterKeepsItsExtentOnRetina() throws {
        let face = MenuBarMeterFace(tag: nil, lines: ["12 %"], widest: ["100 %"], trace: .single([0.2, 0.5, 0.9]),
                                    gauge: .level(0.6), showsNumber: true, showsGraph: true, showsBar: true)
        let vector = MenuBarMeterRenderer.image(for: face)
        let single = try #require(vector.rasterized(scale: 1).representations.first as? NSBitmapImageRep)
        let double = try #require(vector.rasterized(scale: 2).representations.first as? NSBitmapImageRep)
        let one = try #require(Self.inkBounds(of: single))
        let two = try #require(Self.inkBounds(of: double))
        #expect(abs(two.maxX - 2 * one.maxX) <= 2, "Breite bei 2x \(two.maxX), bei 1x \(one.maxX)")
        #expect(abs(two.maxY - 2 * one.maxY) <= 2, "Höhe bei 2x \(two.maxY), bei 1x \(one.maxY)")
    }

    @Test func screenScaleUsesTheSharpestScreen() {
        #expect(NSImage.menuBarRasterScale(screens: [1, 2]) == 2)
        #expect(NSImage.menuBarRasterScale(screens: [1]) == 1)
        #expect(NSImage.menuBarRasterScale(screens: []) == 2)
    }
}
