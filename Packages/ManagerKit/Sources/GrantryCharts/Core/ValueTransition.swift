import SwiftUI

/// Weiche Übergänge für Anteile (0…1), die sich mit jedem Messtakt ändern – Heatmap, Ringe, Säulen (Leistungsbudget
/// Spec §4). Eine Animation je Takt liefe fast ununterbrochen mit der Bildwiederholrate: `.smooth(duration: 0.6)` kommt
/// erst nach 0,9 s zur Ruhe, bei 1 s Takt also zu 90 % der Zeit, und hielt die Tabellen des Task-Managers bei 60–100 %
/// CPU eines Kerns. Deshalb gleitet nur ein deutlicher Sprung, und kurz; kleinere Schwankungen übernimmt die Ansicht
/// ohne Übergang.
public enum ValueTransition {
    /// Kurz und ohne Nachschwingen: läuft höchstens ein Drittel eines 1-s-Takts.
    public static let animation = Animation.easeOut(duration: duration)
    static let duration: TimeInterval = 0.3
    /// Anzahl der Stufen über 0…1; ein Wechsel der Stufe löst den Übergang aus.
    static let steps = 10.0

    /// Stufe eines Anteils als Wert für `.animation(_:value:)`; nicht endliche Werte zählen als 0.
    public static func step(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(max(fraction, 0), 1) * steps).rounded())
    }
}

extension View {
    /// Animiert Änderungen dieser Ansicht kurz, aber nur, wenn `fraction` die Stufe wechselt (`ValueTransition`); ohne
    /// `animates` („Bewegung reduzieren“, angehaltene Graphen) nie.
    public func animatesSteps(of fraction: Double, when animates: Bool) -> some View {
        renderProbe(site: RenderProbe.valueTransition)
            .animation(animates ? ValueTransition.animation : nil, value: ValueTransition.step(fraction))
    }

    /// Wie `animatesSteps(of:when:)` für mehrere Anteile, etwa die Säulen eines Verlaufs.
    public func animatesSteps(of fractions: [Double], when animates: Bool) -> some View {
        renderProbe(site: RenderProbe.valueTransition)
            .animation(animates ? ValueTransition.animation : nil, value: fractions.map(ValueTransition.step))
    }
}
