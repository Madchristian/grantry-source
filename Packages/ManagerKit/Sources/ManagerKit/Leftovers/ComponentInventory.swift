import Foundation

/// Installierte Komponenten ohne `.app` für den Abgleich der Reste gelöschter Apps (Review M1): Systemeinstellungen,
/// Bildschirmschoner, Audio-Plug-ins, Kernel-Erweiterungen (Bundles mit `CFBundleIdentifier`) und Hilfsprogramme unter
/// `/Library/PrivilegedHelperTools` (Dateiname = Kennung). Gelesen wird nur `Info.plist` ohne Blockieren
/// (`BundleLayout.info`), Symlinks und versteckte Einträge werden übersprungen – keine Systemdienste.
struct ComponentInventory {
    /// Eine Komponente: Kennung und Name für Hinweise.
    struct Component: Equatable {
        let identifier: String
        let name: String
    }

    let components: [Component]
    /// Vorhandene, aber nicht lesbare Ordner – dort ist „keine Komponente“ nicht belegt.
    let unreadableFolders: Int

    init(components: [Component] = [], unreadableFolders: Int = 0) {
        self.components = components
        self.unreadableFolders = unreadableFolders
    }

    init(layout: LibraryLayout) {
        var components: [Component] = [], unreadable = 0
        func entries(in directory: String) -> [String] {
            guard let names = LeftoverScanner.entries(in: directory) else {
                unreadable += 1
                return []
            }
            return names.sorted()
        }
        let bundleDirectories = layout.componentDirectories + layout.componentParentDirectories.flatMap { parent in
            entries(in: parent).map { parent + "/" + $0 }.filter(FileType.isPlainDirectory(atPath:))
        }
        for directory in bundleDirectories {
            for name in entries(in: directory) {
                let path = directory + "/" + name
                guard FileType.isPlainDirectory(atPath: path),
                      let identifier = BundleLayout(path: path).info["CFBundleIdentifier"] as? String,
                      !identifier.isEmpty else { continue }
                components.append(Component(identifier: identifier, name: name))
            }
        }
        components += entries(in: layout.privilegedHelperTools).map { Component(identifier: $0, name: $0) }
        self.init(components: components, unreadableFolders: unreadable)
    }
}
