import AppKit
import GrantryCharts
import SwiftUI

/// Rendert die Graphen des Prototyps als PNG, wenn `GRANTRY_DEMO_SNAPSHOTS=<Ordner>` gesetzt ist (Sichtprüfung ohne
/// Bildschirmaufnahme-Berechtigung; Grundlage der Snapshot-Tests in TM-7.2).
@MainActor
enum DemoSnapshots {
    static func renderIfRequested() {
        renderDesignIfRequested()
        guard let directory = ProcessInfo.processInfo.environment["GRANTRY_DEMO_SNAPSHOTS"] else { return }
        let feed = DemoFeed()
        let styles: [(String, ColorScheme)] = [("dark", .dark), ("light", .light)]
        for (name, scheme) in styles {
            let renderer = ImageRenderer(content: DemoGallery(feed: feed)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.09) : Color(white: 0.97)))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("gallery-\(name).png"))
        }
        exit(0)
    }
}

extension DemoSnapshots {
    /// Galerie des Design-Standards (`GRANTRY_DEMO_DESIGN=<Ordner>`): Tokens und Bausteine in hell, dunkel und mit
    /// „Kontrast erhöhen“ für `docs/design/galerie`.
    static func renderDesignIfRequested() {
        guard let directory = ProcessInfo.processInfo.environment["GRANTRY_DEMO_DESIGN"] else { return }
        let looks: [(String, ColorScheme, ColorSchemeContrast)] = [
            ("hell", .light, .standard), ("dunkel", .dark, .standard), ("kontrast", .light, .increased),
        ]
        for page in DesignGallery.Page.allCases {
            for (name, scheme, contrast) in looks {
                let content = DesignGallery(page: page)
                    .environment(\.colorScheme, scheme)
                    .environment(\._colorSchemeContrast, contrast)
                    .environment(\.chartSnapshotRendering, true)
                    .environment(\.chartRenderingPaused, true)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
                let file = page == .tokens ? "tokens" : "bausteine"
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(file)-\(name).png"))
            }
        }
        exit(0)
    }
}

/// Alle Graphen nebeneinander für die Sichtprüfung.
struct DemoGallery: View {
    let feed: DemoFeed
    @Environment(\.self) private var environment

    private func color(_ hue: InstrumentHue) -> Color { environment.instrumentColor(hue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                panel("CPU gesamt") { LiveGraph(series: feed.series(feed.cpuTotal)) }
                panel("GPU") { LiveGraph(series: feed.series(feed.gpu)) }
            }
            panel("Pro Kern") {
                CoreGrid(clusters: feed.clusters)
            }
            .frame(height: 340)
            HStack(spacing: 16) {
                panel("Arbeitsspeicher") {
                    HStack {
                        StackedAreaGraph(layers: [
                            .init(id: "App", series: feed.series(feed.memoryLayers[0]), color: color(.memory)),
                            .init(id: "Zugeordnet", series: feed.series(feed.memoryLayers[1]), color: color(.sent)),
                            .init(id: "Komprimiert", series: feed.series(feed.memoryLayers[2]), color: color(.diskWrite)),
                            .init(id: "Cache", series: feed.series(feed.memoryLayers[3]), color: color(.efficiencyCores)),
                        ], total: DemoFeed.memoryTotal)
                        PressureRing(fraction: 0.63, level: .normal).frame(width: 120, height: 120).padding()
                    }
                }
                panel("SSD lesen / schreiben") {
                    MirrorGraph(upper: feed.series(feed.diskRead), lower: feed.series(feed.diskWrite))
                }
            }
        }
        .padding(20)
        .frame(width: 1180, height: 820)
    }

    private func panel(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
