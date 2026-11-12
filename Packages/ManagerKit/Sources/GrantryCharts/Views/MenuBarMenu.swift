import SwiftUI

// Menüleisten-Menü im Lagebild (LB-5.4, #555; Entwurf LB-5.1, #552; Spec 2026-11-10 § 11 Entscheidung 7, § 11.5 f und g):
// Fenster 380 breit mit Lagezeile, Panels (`SettingsPanel`) und den Befehlen als Aktionsleiste unten. Texte, Zustände und
// Aktionen kommen von der App, damit App, Galerie und Bild-Tests dieselbe Darstellung zeichnen. Kein Takt: Das Menü zeichnet
// nur bei neuen Daten (Scan, Beobachtung, Update); die relativen Zeiten liefert die App.

/// Maße des Menüs (Entscheidung 7: Breite 380 wie bisher).
public enum MenuBarMenuLayout {
    public static let width: CGFloat = 380
}

/// Fenster des Menüs: Inhalt auf dem Grund mit Seitenrand, darunter die Befehle (`MenuBarCommandBar`).
public struct MenuBarMenu<Content: View, Commands: View>: View {
    let content: Content
    let commands: Commands

    public init(@ViewBuilder content: () -> Content, @ViewBuilder commands: () -> Commands) {
        self.content = content()
        self.commands = commands()
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: InstrumentSpacing.panel) { content }
                .padding(InstrumentSpacing.page)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            commands
        }
        .frame(width: MenuBarMenuLayout.width)
        .instrumentBackground()
    }
}

/// Sprünge als Links nebeneinander (Beobachtung, Hinweise) in `font.label` bzw. `font.body`.
public struct MenuBarLinks<Links: View>: View {
    let font: Font
    let links: Links

    public init(font: Font = InstrumentFont.body, @ViewBuilder links: () -> Links) {
        self.font = font
        self.links = links()
    }

    public var body: some View {
        HStack(spacing: InstrumentSpacing.cell) { links }
            .buttonStyle(.link)
            .font(font)
    }
}

/// Hinweis (`InstrumentNote`) mit seinen Sprüngen darunter, eingerückt unter den Text; ohne Sprünge nur der Hinweis.
public struct LinkedNote<Links: View>: View {
    let text: String
    let kind: InstrumentNote.Kind
    let links: Links

    public init(_ text: String, kind: InstrumentNote.Kind, @ViewBuilder links: () -> Links) {
        self.text = text
        self.kind = kind
        self.links = links()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.inline) {
            InstrumentNote(text, kind: kind)
            MenuBarLinks(font: InstrumentFont.label) { links }
                .padding(.leading, InstrumentSpacing.bar)
        }
    }
}

/// Änderungen untereinander im Abstand `group`.
public struct ChangeLines<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.group) { content }
    }
}

/// Eine Änderung: Symbol der Art im Kreis ohne Farbe (Spec § 11.5 g, Bernstein bleibt dem Befund), Titel – ungelesen
/// fett –, darunter der Satz, rechts die Zeit. VoiceOver liest den Titel als Beschriftung und „ungelesen, Zeit, Satz“ als
/// Wert.
public struct ChangeLine: View {
    let symbol: String
    let title: String
    let detail: String
    let time: String
    let isUnread: Bool

    public init(symbol: String, title: String, detail: String, time: String, isUnread: Bool) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.time = time
        self.isUnread = isUnread
    }

    public var body: some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.cell) {
            InstrumentRowIcon(symbol: symbol, size: InstrumentSize.rowIcon)
            VStack(alignment: .leading, spacing: InstrumentSpacing.stack) {
                Text(verbatim: title).font(InstrumentFont.body.weight(isUnread ? .semibold : .regular))
                    .lineLimit(1)
                Text(verbatim: detail).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: InstrumentSpacing.group)
            Text(verbatim: time).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                .lineLimit(1)
        }
        .accessibilityReading(Text(verbatim: title), value: Text(verbatim: spokenValue))
    }

    private var spokenValue: String {
        [isUnread ? String(localized: "ungelesen") : nil, time, detail].compactMap(\.self)
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Befehle des Menüs als Aktionsleiste (`instrumentBar()`): vier native Knöpfe im Raster, bei Platzmangel (große Schrift)
/// untereinander, darunter rechts „Beenden“ mit ⌘Q. „Hauptfenster öffnen“ ist der Standardknopf (Return).
public struct MenuBarCommandBar: View {
    let isScanning: Bool
    let hasReleaseHighlights: Bool
    let showMainWindow: () -> Void
    let scan: () -> Void
    let settings: () -> Void
    let whatsNew: () -> Void
    let quit: () -> Void

    public init(isScanning: Bool, hasReleaseHighlights: Bool, showMainWindow: @escaping () -> Void,
                scan: @escaping () -> Void, settings: @escaping () -> Void, whatsNew: @escaping () -> Void,
                quit: @escaping () -> Void) {
        self.isScanning = isScanning
        self.hasReleaseHighlights = hasReleaseHighlights
        self.showMainWindow = showMainWindow
        self.scan = scan
        self.settings = settings
        self.whatsNew = whatsNew
        self.quit = quit
    }

    public var body: some View {
        VStack(spacing: InstrumentSpacing.cell) {
            // Native macOS-Knöpfe kürzen Text einzeilig: bei Platzmangel ganze Zeilen verwenden.
            ViewThatFits(in: .horizontal) {
                Grid(horizontalSpacing: InstrumentSpacing.cell, verticalSpacing: InstrumentSpacing.cell) {
                    GridRow { mainWindowButton; scanButton }
                    GridRow { settingsButton; whatsNewButton }
                }
                VStack(spacing: InstrumentSpacing.cell) {
                    mainWindowButton
                    scanButton
                    settingsButton
                    whatsNewButton
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Beenden"), action: quit)
                    .keyboardShortcut("q")
            }
        }
        .frame(maxWidth: .infinity)
        .instrumentBar()
    }

    private var mainWindowButton: some View {
        Button(action: showMainWindow) { label(String(localized: "Hauptfenster öffnen")) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }

    private var scanButton: some View {
        Button(action: scan) { label(String(localized: "Jetzt scannen")) }
            .disabled(isScanning)
    }

    private var settingsButton: some View {
        Button(action: settings) { label(String(localized: "Einstellungen …")) }
    }

    private var whatsNewButton: some View {
        Button(action: whatsNew) { label(String(localized: "Was ist neu?")) }
            .disabled(!hasReleaseHighlights)
    }

    private func label(_ title: String) -> some View {
        Text(verbatim: title)
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.vertical, InstrumentSpacing.stack)
    }
}
