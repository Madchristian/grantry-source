import GrantryCharts
import SwiftUI

/// Spaltenbreiten des Hauptfensters: Seitenleiste (höchstens `sidebarMax`) und Inhalt (mindestens `contentMin`) passen in
/// `windowMinWidth`. Liste und Detail teilt `InstrumentSplit` mit denselben Mindestbreiten (`InstrumentSize.listMin`,
/// `detailMin`); bis LB-5.5 (#556) stand das Gerüst `ListDetailSplit` daneben.
enum WindowLayout {
    static let sidebarMin: CGFloat = 170
    static let sidebarIdeal: CGFloat = 190
    static let sidebarMax: CGFloat = 240
    /// Mindestbreite des Inhalts: Liste, Trennlinie und Detail. Seitenrand und Abstand des `InstrumentSplit` sind nicht
    /// eingerechnet; die Fensterprüfung (`window_layout_check.swift`) belegt, dass bei `windowMinWidth` nichts herausragt.
    static let contentMin: CGFloat = InstrumentSize.listMin + 1 + InstrumentSize.detailMin
    static let windowMinWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 600
}
