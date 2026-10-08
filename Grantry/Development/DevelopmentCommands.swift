#if DEBUG
import AppKit
import ManagerKit
import Observation
import SwiftUI

/// Werkzeuge nur für die Entwicklung; in Release-Builds nicht enthalten.
@MainActor
@Observable
final class DevelopmentTools {
    /// `true`, solange die BTM-Rohdaten gesichert werden.
    private(set) var isDumpingBTM = false

    /// Gemeinsame XPC-Verbindung zum Helper.
    private let helperClient: HelperClient

    init(helperClient: HelperClient) {
        self.helperClient = helperClient
    }

    /// Sichert die Rohausgabe von `sfltool dumpbtm` (über den Helper) als Textdatei auf dem Schreibtisch und meldet
    /// das Ergebnis in einem Dialog.
    func dumpBTMRaw() async {
        guard !isDumpingBTM else { return }
        isDumpingBTM = true
        defer { isDumpingBTM = false }
        do {
            let output = try await helperClient.dumpBTM()
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Desktop", directoryHint: .isDirectory)
                .appending(path: "btm-dump-real.txt")
            try output.write(to: url, atomically: true, encoding: .utf8)
            var lineCount = 0
            output.enumerateLines { _, _ in lineCount += 1 }
            showResult(title: "BTM-Rohdaten gesichert", message: "\(url.path) (\(lineCount) Zeilen)", revealing: url)
        } catch {
            showResult(title: "Sicherung fehlgeschlagen", message: error.readableDescription, revealing: nil)
        }
    }

    private func showResult(title: String, message: String, revealing url: URL?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = url == nil ? .warning : .informational
        alert.addButton(withTitle: "OK")
        if url != nil { alert.addButton(withTitle: "Im Finder zeigen") }
        if alert.runModal() == .alertSecondButtonReturn, let url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

/// Startoptionen für Bildschirmprüfungen ohne Bedienung (nur DEBUG), z. B.
/// `open -n Grantry.app --args -AllowSecondInstance YES -DebugInitialSection history`.
enum DevelopmentLaunchOptions {
    /// Bereich, den das Hauptfenster beim Start zeigt (`-DebugInitialSection <Bereich>`).
    static var initialSection: MainSection? {
        UserDefaults.standard.string(forKey: "DebugInitialSection").flatMap(MainSection.init(rawValue:))
    }

    /// Zweite Instanz neben einer laufenden zulassen (`-AllowSecondInstance YES`), mit eigener Ablage.
    static var allowsSecondInstance: Bool {
        UserDefaults.standard.bool(forKey: "AllowSecondInstance")
    }

    /// Onboarding beim Start zeigen, auch wenn es erledigt ist (`-DebugShowOnboarding YES`).
    static var showsOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "DebugShowOnboarding")
    }

    /// Onboarding beim Start nicht von selbst zeigen (`-DebugSuppressOnboarding YES`), etwa damit eine Zweitinstanz ohne
    /// Freigaben andere Blätter zeigen kann. Vermerkt nichts als erledigt.
    static var suppressesOnboarding: Bool {
        UserDefaults.standard.bool(forKey: "DebugSuppressOnboarding")
    }

    /// Inhalt des Menüleisten-Popovers zusätzlich in einem Fenster zeigen (`-DebugShowMenuBarContent YES`), da sich
    /// das Popover nicht ohne Klick öffnen lässt.
    static var showsMenuBarContent: Bool {
        UserDefaults.standard.bool(forKey: "DebugShowMenuBarContent")
    }

    /// Öffnet beim Start das Entfernen-Blatt der App mit dieser Bundle-ID (`-DebugRemovalPreview <Bundle-ID>`), damit es
    /// sich ohne Klick fotografieren lässt. Die Reste-Suche liest nur; bestätigt wird nie.
    static var removalPreviewBundleID: String? {
        UserDefaults.standard.string(forKey: "DebugRemovalPreview")
    }

    /// Art des Vorschau-Blatts (`-DebugRemovalPreviewMode leftovers`); Vorgabe „App entfernen …“.
    static var removalPreviewMode: RemovalRequest.Mode {
        UserDefaults.standard.string(forKey: "DebugRemovalPreviewMode").flatMap(RemovalRequest.Mode.init(rawValue:)) ?? .uninstall
    }

    /// Startet im Bereich „Aufräumen“ nach dem ersten Scan die (nur lesende) Suche (`-DebugCleanupAutoSearch YES`).
    static var autoSearchesCleanup: Bool {
        UserDefaults.standard.bool(forKey: "DebugCleanupAutoSearch")
    }

    /// Testfeed statt `UpdateFeed.url` (`-DebugUpdateFeedURL file:///…/update-testfeed.xml`); nur damit prüfen
    /// Debug-Builds automatisch.
    static var updateFeedURL: URL? {
        UserDefaults.standard.string(forKey: "DebugUpdateFeedURL").flatMap(URL.init(string:))
    }

    /// Fenster mit dem Inhalt des Menüleisten-Popovers.
    static let menuBarPreviewWindowID = "debug-menubar"
}

/// Menü „Entwicklung“ (nur DEBUG).
struct DevelopmentCommands: Commands {
    let tools: DevelopmentTools

    var body: some Commands {
        CommandMenu("Entwicklung") {
            Button("BTM-Rohdaten sichern") { Task { await tools.dumpBTMRaw() } }
                .disabled(tools.isDumpingBTM)
        }
    }
}
#endif
