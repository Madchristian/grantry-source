import GrantryCharts
import SwiftUI

// Entwurf LB-5.1 (#552, Spec docs/superpowers/specs/2026-11-10-lagebild-altansichten-design.md § 4.3, § 5 Welle 5):
// gemeinsame Teile der Fenster und Blätter außerhalb der Bereiche – Einstellungen, Onboarding, Was ist neu und das
// Menüleisten-Menü. Nur Galerie mit festen Beispieldaten; Seite, Abschnitte, Leerzustände und die zentralen Bausteine
// kommen aus LB-1.2 (#536) und dem Entwurf LB-2.1 (`LagebildAreaDraft.swift`) und bleiben unverändert. Die Vorschläge
// sind mit #553 bis #555 zentral geworden; was hier auf `Gallery` beginnt, ist nur der Rahmen der Bilder.

// MARK: - Bausteine des Entwurfs

// `SettingsPanel`, `SettingRow`, `SettingToggle`, `SettingActionLine` und `WindowBar` sind seit LB-5.2 (#553) zentral in GrantryCharts.

// MARK: - Fenster

/// Breiten der Fenster wie heute (Einstellungen 560, Onboarding 620, Was ist neu 560); das Menü (380, Entscheidung 7)
/// steht zentral in `MenuBarMenuLayout`.
enum GalleryWindowWidth {
    static let settings: CGFloat = 560
    static let onboarding: CGFloat = 620
    static let whatsNew: CGFloat = 560
}

/// Ausschnitt eines Fensters oder Blatts in fester Breite: Fensterbezeichnung klein darüber, Inhalt auf dem Grund mit
/// Seitenrand 14, unten auf Wunsch die Aktionsleiste (`instrumentBar()`, Standard § 3.1).
struct GalleryWindow<Content: View, Bar: View>: View {
    let name: String
    let width: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let bar: Bar

    var body: some View {
        VStack(alignment: .leading, spacing: InstrumentSpacing.item) {
            Text(verbatim: name).font(InstrumentFont.label).foregroundStyle(.instrumentSecondary)
                .accessibilityHidden(true)
            WindowContent(width: width) { content } bar: { bar }
                .clipShape(.rect(cornerRadius: InstrumentRadius.panel, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: InstrumentRadius.panel, style: .continuous)
                        .strokeBorder(.instrumentSecondary, lineWidth: InstrumentStroke.border)
                        .accessibilityHidden(true)
                }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension GalleryWindow where Bar == EmptyView {
    init(name: String, width: CGFloat, @ViewBuilder content: () -> Content) {
        self.init(name: name, width: width, content: content, bar: { EmptyView() })
    }
}

/// Zustände nebeneinander, oben ausgerichtet.
struct GalleryRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: InstrumentSpacing.empty) { content }
    }
}
