import SwiftUI

/// Zählpunkte des Render-Wächters (#372): wie oft eine Ansicht ausgewertet (`body`) und gezeichnet (`Plot`) wird und
/// wie oft eine animierte Transaktion bei ihr ankommt. `RenderGuard` treibt die Ansichten über feste Messtakte und
/// prüft daran die Leistungsregeln aus #369.
///
/// Gezählt wird nur unterhalb von `RenderGuard`: Der Empfänger steht in der Umgebung und in jeder Transaktion, die ein
/// neuer Messwert auslöst (`renderRecorder`), nicht in einer globalen Variable – andere Ansichten im selben Prozess,
/// etwa Snapshot-Tests, zählen nicht mit.
///
/// Nur im Debug-Build aktiv: Im Release-Build ist `renderProbe(_:)` eine leere `@inlinable`-Funktion, die der Compiler
/// samt der Literale entfernt – kein Laufzeitaufwand in der ausgelieferten App. Im Debug-Build kostet ein Zählpunkt
/// einen Lesezugriff auf die Umgebung (ohne Wächter `nil`), dazu je `renderProbe(_:)` einen Modifier. Zeichenaufrufe
/// zählt `Plot` selbst unter ihrem Zählpunkt.
public enum RenderProbe {
    /// Zählpunkt der Übergänge von `animatesSteps(of:when:)`: Dort sind Animationen erlaubt, aber nur je Stufenwechsel.
    public static let valueTransition = "ValueTransition"

    /// Ob die Zählpunkte in diesem Build zählen.
    public static var isActive: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    #if DEBUG
    /// Zählt Erzeugungen von `RenderProbeModifier`, damit jede Auswertung des umgebenden `body` den Modifier neu
    /// auswertet.
    @MainActor static var evaluations = 0
    #endif
}

/// Zählstand eines Zählpunkts.
public struct RenderCounts: Equatable, Sendable {
    public var bodies = 0
    public var draws = 0
    public var animatedUpdates = 0

    public init() {}
}

#if DEBUG
/// Sammelt die Zählungen aller Zählpunkte unterhalb von `RenderGuard`, bis `take()` sie abholt.
@MainActor
public final class RenderRecorder {
    public private(set) var counts: [String: RenderCounts] = [:]

    public init() {}

    func record(_ site: String, _ measure: WritableKeyPath<RenderCounts, Int>) {
        counts[site, default: RenderCounts()][keyPath: measure] += 1
    }

    /// Zählungen seit dem letzten Abholen; danach beginnt die Zählung von vorn.
    public func take() -> [String: RenderCounts] {
        defer { counts = [:] }
        return counts
    }
}

extension EnvironmentValues {
    /// Empfänger der Auswertungen und Zeichenaufrufe; gesetzt nur von `RenderGuard`.
    @Entry var renderRecorder: RenderRecorder?
}

extension Transaction {
    /// Empfänger der animierten Transaktionen; `RenderGuard` setzt ihn in jede Aktualisierung eines Messtakts.
    @Entry var renderRecorder: RenderRecorder?
}

/// Zählt die Auswertungen der Ansicht, die ihn anlegt: `evaluation` ist bei jeder Anlage neu, also wertet SwiftUI den
/// Fühler genau so oft aus wie den `body`, der ihn anlegt. Liegt als leerer Hintergrund an der Ansicht und ändert weder
/// Größe noch Bild. (Ein `ViewModifier` taugt dafür nicht: Dessen `body` wertet SwiftUI nicht bei jeder Anlage aus.)
private struct RenderProbeView: View {
    let site: String
    let evaluation: Int

    @Environment(\.renderRecorder) private var recorder

    var body: some View {
        recorder?.record(site, \.bodies)
        return Color.clear
    }
}
#endif

extension View {
    #if DEBUG
    /// Zählpunkt einer Ansicht: zählt jede Auswertung des umgebenden `body` und jede animierte Transaktion, die hier
    /// ankommt – also Animationen von außen, etwa animiertes Umsortieren einer Tabelle oder `withAnimation` im Modell.
    public func renderProbe(_ site: StaticString) -> some View {
        renderProbe(site: site.description)
    }

    func renderProbe(site: String) -> some View {
        RenderProbe.evaluations &+= 1
        // Am Inhalt, nicht am Fühler: Eine Transaktion kommt nur dort an, wo sich etwas ändert.
        return transaction { transaction in
            guard transaction.animation != nil, !transaction.disablesAnimations else { return }
            transaction.renderRecorder?.record(site, \.animatedUpdates)
        }
        .background(RenderProbeView(site: site, evaluation: RenderProbe.evaluations))
    }
    #else
    @inlinable public func renderProbe(_ site: StaticString) -> Self { self }

    @inlinable func renderProbe(site: String) -> Self { self }
    #endif
}
