import AppKit
import ManagerKit
import SwiftUI
import UniformTypeIdentifiers

/// App-Symbole, ohne Launch Services gelesen (`AppIconLoader`, Review H1): `.icns` aus dem Bundle, sonst ein
/// generisches Symbol. `NSWorkspace.icon(forFile:)` ließ den `lsd` das Bundle öffnen – an einer FIFO hing er dauerhaft.
/// Das Kit liest auf eigener Queue und merkt sich die Daten je Pfad und Fingerabdruck; dekodiert wird ebenfalls auf
/// eigener Queue – sofort und auf höchstens 256 px verkleinert (`AppIconDecoder`, Review N4), nicht erst beim Zeichnen. Das Bild bleibt, solange die Revision gleich bleibt. Pfade ohne Datei werden vermerkt, bis ein
/// neuer Snapshot sie wieder prüfen lässt (`invalidate()`), der zugleich geänderte Symbole neu laden lässt.
@MainActor
@Observable
final class AppIconCache {
    static let shared = AppIconCache()

    /// Stand der Symbole; ändert sich mit `invalidate()`, damit Ansichten neu laden.
    private(set) var generation = 0
    @ObservationIgnored private let loader: AppIconLoader
    @ObservationIgnored private let icons = NSCache<NSString, CachedIcon>()
    @ObservationIgnored private var missingPaths: Set<String> = []
    /// Laufende Ladevorgänge je Pfad; weitere Zeilen mit derselben App warten auf denselben.
    @ObservationIgnored private var loading: [String: Task<NSImage?, Never>] = [:]
    nonisolated private static let decodeQueue = DispatchQueue(label: "de.cstrube.Grantry.app-icon-images", qos: .utility)

    init(loader: AppIconLoader = .shared) {
        self.loader = loader
    }

    /// Bereits geladenes Symbol; `nil`, wenn es fehlt oder noch nicht geladen ist.
    func cachedIcon(for app: AppIdentity) -> NSImage? {
        iconPath(for: app).flatMap { icons.object(forKey: $0 as NSString)?.image }
    }

    /// Lädt das Symbol außerhalb des Main Actors, sofern es nicht als fehlend vermerkt ist; ein unverändertes Symbol
    /// (gleiche Revision) wird nicht neu dekodiert.
    func loadIcon(for app: AppIdentity) async -> NSImage? {
        guard let path = iconPath(for: app), !missingPaths.contains(path) else { return nil }
        if let running = loading[path] { return await running.value }
        let task = Task<NSImage?, Never> {
            defer { loading[path] = nil }
            let loaded = await loader.icon(forPath: path)
            if loaded.icon == .missing {
                missingPaths.insert(path)
                icons.removeObject(forKey: path as NSString)
                return nil
            }
            if let cached = icons.object(forKey: path as NSString), cached.revision == loaded.revision { return cached.image }
            let image = await Self.image(for: loaded.icon).image
            icons.setObject(CachedIcon(image: image, revision: loaded.revision), forKey: path as NSString)
            return image
        }
        loading[path] = task
        return await task.value
    }

    /// Vergisst die als fehlend vermerkten Dateien und lässt sichtbare Symbole ihre Revision prüfen (nach einem neuen
    /// Snapshot).
    func invalidate() {
        missingPaths.removeAll()
        generation += 1
    }

    /// Pfad, dessen Symbol gezeigt wird; `nil` ohne Pfad oder wenn die Datei laut Scan fehlt.
    private func iconPath(for app: AppIdentity) -> String? {
        guard let path = app.path, app.presence != .missing, app.presence != .probablyMissing else { return nil }
        return path
    }

    /// Bild zu `icon`, dekodiert auf eigener Queue. Die generischen Symbole kommen über ihren Typ aus `NSWorkspace` –
    /// dabei wird keine Datei des Nutzers angefasst.
    nonisolated private static func image(for icon: AppIcon) async -> DecodedIcon {
        await withCheckedContinuation { continuation in
            decodeQueue.async {
                let image: NSImage = switch icon {
                case .icns(let data):
                    AppIconDecoder.image(fromICNS: data).map { NSImage(cgImage: $0, size: .zero) }
                        ?? NSWorkspace.shared.icon(for: .applicationBundle)
                case .genericExecutable: NSWorkspace.shared.icon(for: .unixExecutable)
                case .genericApplication, .missing: NSWorkspace.shared.icon(for: .applicationBundle)
                }
                continuation.resume(returning: DecodedIcon(image: image))
            }
        }
    }

    /// Frisch dekodiertes, noch nicht geteiltes Symbol – wird nur einmal an den Main Actor übergeben.
    private struct DecodedIcon: @unchecked Sendable {
        let image: NSImage
    }

    /// Bild samt Revision des Kit-Symbols.
    private final class CachedIcon {
        let image: NSImage
        let revision: UInt64

        init(image: NSImage, revision: UInt64) {
            self.image = image
            self.revision = revision
        }
    }
}

/// Symbol einer App; bis es geladen ist bzw. ohne Datei ein neutrales Platzhaltersymbol.
struct AppIconView: View {
    let app: AppIdentity
    var size: CGFloat = 24
    @State private var loadedIcon: NSImage?

    private var cache: AppIconCache { .shared }

    var body: some View {
        Group {
            if let icon = cache.cachedIcon(for: app) ?? loadedIcon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.1)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: LoadKey(path: app.path, presence: app.presence, generation: cache.generation)) {
            loadedIcon = await cache.loadIcon(for: app)
        }
    }

    private struct LoadKey: Hashable {
        let path: String?
        let presence: Presence
        let generation: Int
    }
}

/// SF Symbol eines Datenschutz-Dienstes aus dem `PermissionCatalog`.
struct ServiceIconView: View {
    let service: PermissionService
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: service.systemImage)
            .font(.system(size: size * 0.7))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
