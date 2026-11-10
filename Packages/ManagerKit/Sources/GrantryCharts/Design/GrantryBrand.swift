import SwiftUI

/// Farben des App-Symbols (§2.4): Verlauf Indigo → Blau → Petrol für Fokus und Zustandsschild, Bernstein für den
/// Befund-Punkt – und nur dafür.
public enum GrantryBrand {
    static let indigoRGB: Contrast.RGB = (0.227, 0.271, 0.788)
    public static let indigo = Color(indigoRGB)
    public static let blue = Color(red: 0.145, green: 0.376, blue: 0.722)
    public static let teal = Color(red: 0.055, green: 0.557, blue: 0.620)
    /// Petrol unter weißer Schrift (Weiß darauf 5,6 : 1; auf `teal` nur 3,9 : 1).
    static let tealDeep = Color(red: 0.04, green: 0.45, blue: 0.50)

    /// Fläche hinter weißer Schrift: gewähltes Segment, Zustandsschild.
    public static var fill: LinearGradient {
        LinearGradient(colors: [indigo, blue, tealDeep], startPoint: .leading, endPoint: .trailing)
    }

    /// Rand der gewählten Karte und Fokusleiste der gewählten Zeile; dunkel heller, damit er auf dem Panel ≥ 3 : 1 hat.
    public static func focus(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(gradient: focusGradient(scheme), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Farben von `focus` für Zeichnungen im `Canvas` (gewähltes Echo im Radar).
    static func focusGradient(_ scheme: ColorScheme) -> Gradient {
        Gradient(colors: scheme == .dark
            ? [Color(red: 0.45, green: 0.50, blue: 0.95), Color(red: 0.20, green: 0.75, blue: 0.82)]
            : [indigo, blue, teal])
    }

    /// Befund-Punkt; hell abgedunkelt (4,2 : 1 auf Weiß, ≥ 3 : 1 auch auf Grund und gewählter Zeile).
    public static func amber(_ scheme: ColorScheme) -> Color {
        Color(scheme == .dark ? amberDark : amberLight)
    }

    static let amberDark: Contrast.RGB = (0.984, 0.682, 0.173)
    static let amberLight: Contrast.RGB = (0.70, 0.42, 0)
}

/// Zustandstöne (§2.5). `finding` ist der Bernstein des Befund-Punkts; `PresentationTone` der übrigen App gilt in der
/// Instrumententafel nicht.
public enum StatusTone: Sendable, CaseIterable {
    case positive, info, finding, critical, neutral

    /// Farbe für Punkte, Bögen, Leisten und Ringe (≥ 3 : 1).
    public func color(in scheme: ColorScheme) -> Color {
        rgb(dark: scheme == .dark, text: false).map(Color.init) ?? .instrumentSecondary
    }

    /// Farbe für Text (≥ 4,5 : 1 auf Panel, Grund und gewählter Zeile): hell sind Grün und Bernstein dunkler, dunkel
    /// ist Rot heller als die Grafikfarbe.
    public func textColor(in scheme: ColorScheme) -> Color {
        rgb(dark: scheme == .dark, text: true).map(Color.init) ?? .instrumentSecondary
    }

    /// `nil` für `neutral`, das der Sekundärfarbe folgt.
    nonisolated func rgb(dark: Bool, text: Bool) -> Contrast.RGB? {
        switch self {
        case .positive: dark ? (0.36, 0.86, 0.56) : (text ? (0.08, 0.42, 0.23) : (0.10, 0.50, 0.28))
        case .info: dark ? (0.45, 0.68, 1) : (0.14, 0.37, 0.75)
        case .finding: dark ? GrantryBrand.amberDark : (text ? (0.58, 0.35, 0) : GrantryBrand.amberLight)
        case .critical: dark ? (text ? (1, 0.5, 0.48) : (1, 0.42, 0.40)) : (0.75, 0.16, 0.14)
        case .neutral: nil
        }
    }
}

extension EnvironmentValues {
    /// Grafikfarbe eines Zustandstons im aktuellen Erscheinungsbild.
    public func statusColor(_ tone: StatusTone) -> Color { tone.color(in: colorScheme) }

    /// Textfarbe eines Zustandstons im aktuellen Erscheinungsbild.
    public func statusTextColor(_ tone: StatusTone) -> Color { tone.textColor(in: colorScheme) }
}

/// Hitze (§2.6): die Messgrößenfarbe in steigender Deckkraft unter der Schrift `.primary`. Hell reicht die Deckkraft bis
/// 0,55; dunkel bis höchstens 0,7 und nur so weit, wie weiße Schrift auf der Zelle – über dem Panel wie über der gewählten
/// Zeile – 4,5 : 1 behält. Zwischen Weiß und Schwarz zu wechseln hilft nicht: Im Übergang erreicht keine von beiden 4,5 : 1.
public enum HeatShade {
    static let lightMaximum = 0.55
    static let darkMaximum = 0.7

    /// Deckkraft des Grunds ohne Bezug auf eine Messgröße (Zellen ohne Schrift): 0 ohne Last, linear bis zum Höchstwert.
    public nonisolated static func opacity(forHeat heat: Double, dark: Bool) -> Double {
        clamped(heat) * (dark ? darkMaximum : lightMaximum)
    }

    /// Deckkraft des Grunds unter Schrift in der Farbe von `hue`.
    public nonisolated static func opacity(forHeat heat: Double, hue: InstrumentHue, dark: Bool) -> Double {
        clamped(heat) * (dark ? (darkTextMaximum[hue] ?? 0) : lightMaximum)
    }

    /// Kleinster Kontrast von `text` auf der Zelle über Panel und gewählter Zeile (dunkel).
    nonisolated static func textContrast(on hue: InstrumentHue, opacity: Double, text: Contrast.RGB) -> Double {
        [InstrumentSurface.panelDark, InstrumentSurface.selectionRGB(dark: true)]
            .map { Contrast.ratio(text, Contrast.mix(hue.base, opacity: opacity, over: $0)) }
            .min() ?? 0
    }

    /// Je Messgröße die höchste Deckkraft bis `darkMaximum`, bei der Weiß noch 4,5 : 1 hat (Halbierungssuche: der Kontrast
    /// sinkt mit der Deckkraft, alle Messgrößen sind heller als das Panel).
    static let darkTextMaximum: [InstrumentHue: Double] = Dictionary(uniqueKeysWithValues: InstrumentHue.allCases.map { hue in
        var (low, high) = (0.0, darkMaximum)
        guard textContrast(on: hue, opacity: high, text: Contrast.white) < 4.5 else { return (hue, high) }
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if textContrast(on: hue, opacity: middle, text: Contrast.white) >= 4.5 { low = middle } else { high = middle }
        }
        return (hue, low)
    })

    private nonisolated static func clamped(_ heat: Double) -> Double {
        min(max(heat.isFinite ? heat : 0, 0), 1)
    }
}
