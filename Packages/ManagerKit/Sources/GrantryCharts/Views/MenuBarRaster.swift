import AppKit

/// Gerasterte Statusbilder der Menüleiste (#491, #570): AppKit zeichnet ein Statusobjekt je Bild mehrfach (Anzeige,
/// Schnappschuss für die Menüleiste), ein Vektorbild jedes Mal neu; eine Bitmap nur einmal.
public extension NSImage {
    /// Dasselbe Vorlagenbild als Bitmap mit `scale` Pixeln je Punkt und derselben Punktgrösse; ohne Grafikkontext
    /// unverändert.
    ///
    /// Die Punktgrösse der Bitmap steht fest, bevor der Kontext entsteht: Der Kontext übernimmt daraus seinen Massstab.
    /// Später gesetzt, zeichnete er 1 Pixel je Punkt, und das Bild füllte auf Retina nur das untere linke Viertel (#570).
    func rasterized(scale: CGFloat) -> NSImage {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                                            pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return self }
        bitmap.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return self }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = isTemplate
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// Pixel je Punkt für Statusbilder: die schärfste angeschlossene Anzeige. So bleibt ein Element scharf, wenn die
    /// Menüleiste auf einen Retina-Bildschirm wechselt, ohne dass sich der Wert ändert; ein 1x-Bildschirm verkleinert.
    static func menuBarRasterScale(screens: [CGFloat] = NSScreen.screens.map(\.backingScaleFactor)) -> CGFloat {
        screens.max() ?? 2
    }
}
