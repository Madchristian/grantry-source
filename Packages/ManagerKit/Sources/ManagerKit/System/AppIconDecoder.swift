import CoreGraphics
import Foundation
import ImageIO

/// Dekodiert `.icns`-Daten (`AppIcon.icns`) sofort zu einem Bitmap begrenzter Größe (Review N4). `NSImage(data:)`
/// dekodiert erst beim Zeichnen – auf dem Main Thread und in voller Größe (bis 1024 px).
///
/// Gewählt wird das kleinste enthaltene Bild bis `maximumSourceEdge`, das mindestens `maximumPixelSize` misst (sonst
/// das größte), und per `CGImageSourceCreateThumbnailAtIndex` verkleinert (`kCGImageSourceShouldCacheImmediately`);
/// kleinere Bilder werden nicht vergrößert. Läuft synchron – Aufrufer nutzen eine eigene Queue.
public enum AppIconDecoder {
    /// Höchste Kantenlänge in Pixeln: reicht für 128-pt-Symbole auf Retina-Displays.
    public static let maximumPixelSize = 256
    /// Größte Kante eines Quellbildes (Review N7): `.icns` enthält höchstens 1024 px; größere Bilder (manipulierte oder
    /// fremde Dateien) werden anhand ihrer Eigenschaften übersprungen, bevor etwas dekodiert wird.
    public static let maximumSourceEdge = 1024

    /// Bitmap aus `data`; `nil`, wenn sich nichts dekodieren lässt.
    public static func image(fromICNS data: Data, maximumPixelSize: Int = maximumPixelSize) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let index = bestIndex(in: source, for: maximumPixelSize) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, index, options)
    }

    /// Index des kleinsten Bildes mit mindestens `size` Pixeln Kantenlänge, sonst des größten; `nil` ohne Bilder.
    /// Bilder ohne bekannte Größe oder mit einer Kante über `maximumSourceEdge` zählen nicht.
    private static func bestIndex(in source: CGImageSource, for size: Int) -> Int? {
        let widths = (0..<CGImageSourceGetCount(source)).compactMap { index -> IndexedWidth? in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties?[kCGImagePropertyPixelHeight] as? Int,
                  max(width, height) <= maximumSourceEdge else { return nil }
            return IndexedWidth(index: index, width: width)
        }
        let largeEnough = widths.filter { $0.width >= size }
        return (largeEnough.min { $0.width < $1.width } ?? widths.max { $0.width < $1.width })?.index
    }

    /// Bild einer Quelle samt Breite (Struct statt Tupel).
    private struct IndexedWidth {
        let index: Int
        let width: Int
    }
}
