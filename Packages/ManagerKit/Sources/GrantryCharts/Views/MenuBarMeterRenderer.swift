import AppKit
import SwiftUI

/// Inhalt eines Menüleisten-Elements für `MenuBarMeterRenderer` (TM17, Spec 2026-11-09 § 2) – ohne ManagerKit-Typen;
/// die App baut es aus `MenuBarMeterReading` und der gewählten Darstellung.
public struct MenuBarMeterFace: Equatable, Sendable {
    public enum Trace: Equatable, Sendable {
        /// Verlauf 0…1, älteste zuerst.
        case single([Double?])
        /// Gespiegelt um die Mitte: oben empfangen bzw. lesen, unten gesendet bzw. schreiben, beide 0…1.
        case mirror(upper: [Double?], lower: [Double?])
    }

    public enum Gauge: Equatable, Sendable {
        case level(Double?)
        case thermometer(Double?)
        case battery(Double?, isCharging: Bool)
    }

    /// Kurzbezeichnung; `nil` oder leer zeigt keine.
    public var tag: String?
    /// Eine Zeile (Wert) oder zwei (Netz, Datenträger).
    public var lines: [String]
    /// Breiteste mögliche Zeilen: Das Element behält seine Breite, damit nichts rechts davon je Takt springt.
    public var widest: [String]
    public var trace: Trace?
    public var gauge: Gauge?
    public var showsNumber: Bool
    public var showsGraph: Bool
    public var showsBar: Bool
    public var isFinding: Bool

    public init(tag: String?, lines: [String], widest: [String], trace: Trace?, gauge: Gauge?, showsNumber: Bool,
                showsGraph: Bool, showsBar: Bool, isFinding: Bool = false) {
        self.tag = tag
        self.lines = lines
        self.widest = widest
        self.trace = trace
        self.gauge = gauge
        self.showsNumber = showsNumber
        self.showsGraph = showsGraph
        self.showsBar = showsBar
        self.isFinding = isFinding
    }
}

/// Zeichnet ein Menüleisten-Element als Vorlagenbild (TM17): nur die Deckkraft zählt, das System färbt es in heller
/// und dunkler Leiste ein. Gezeichnet wird je Messpunkt, ohne Animation; der Verlauf rückt mit jedem Punkt nach.
/// Eigene Handschrift: gerundetes Messfeld, durchgehende Pegel ohne Segmente, Befund als ausgestanzter Punkt wie am
/// Grantry-Schild.

@MainActor
public enum MenuBarMeterRenderer {
    public static let height: CGFloat = 18
    private static let graphSize = CGSize(width: 28, height: 14)
    private static let barSize = CGSize(width: 5, height: 14)
    private static let gap: CGFloat = 3
    private static let findingDiameter: CGFloat = 5
    /// Punkte des Verlaufs (`MenuBarMeterPresentation.pointCount`).
    private static let pointCount = 30

    public static func image(for face: MenuBarMeterFace, increasedContrast: Bool = false) -> NSImage {
        let parts = layout(face)
        let width = parts.reduce(0) { $0 + $1.width } + gap * CGFloat(max(parts.count - 1, 0))
            + (face.isFinding ? findingDiameter / 2 : 0)
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0
            for part in parts {
                part.draw(x, context, increasedContrast)
                x += part.width + gap
            }
            if face.isFinding { drawFinding(at: CGPoint(x: width - findingDiameter, y: 0), context: context) }
            return true
        }
        image.isTemplate = true
        return image
    }

    private struct Part {
        let width: CGFloat
        let draw: (CGFloat, CGContext, Bool) -> Void
    }

    private static func layout(_ face: MenuBarMeterFace) -> [Part] {
        var parts: [Part] = []
        let tag = face.tag.flatMap { $0.isEmpty ? nil : $0 }
        if let tag, !face.showsNumber || face.lines.count > 1 { parts.append(sideTagPart(tag)) }
        if face.showsNumber {
            parts.append(face.lines.count > 1 ? twoLinePart(face.lines, widest: face.widest)
                                              : valuePart(face.lines.first ?? "–", widest: face.widest, tag: tag))
        }
        if face.showsGraph, let trace = face.trace {
            switch trace {
            case .single(let values): parts.append(graphPart(values))
            case .mirror(let upper, let lower): parts.append(mirrorPart(upper, lower))
            }
        }
        if face.showsBar, let gauge = face.gauge {
            switch gauge {
            case .level(let share): parts.append(barPart(share))
            case .thermometer(let level): parts.append(thermometerPart(level))
            case .battery(let charge, let isCharging): parts.append(batteryPart(charge, isCharging: isCharging))
            }
        }
        return parts
    }

    /// Breite aus den breitesten möglichen und den aktuellen Zeilen.
    private static func width(of lines: [String], size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        ceil(lines.map { string($0, size: size, weight: weight).size().width }.max() ?? 0)
    }

    // MARK: Text

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    private static func string(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: Double = MenuBarInk.full)
        -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font(size, weight), .foregroundColor: MenuBarInk.nsColor(alpha),
        ])
    }

    /// Kurzbezeichnung über dem Wert, Wert rechtsbündig in fester Breite.
    private static func valuePart(_ value: String, widest: [String], tag: String?) -> Part {
        if let tag {
            let tagText = string(tag, size: 7, weight: .bold, alpha: MenuBarInk.tag)
            let valueText = string(value, size: 10.5, weight: .semibold)
            let width = max(ceil(tagText.size().width), width(of: widest + [value], size: 10.5, weight: .semibold))
            return Part(width: width) { x, _, _ in
                tagText.draw(at: NSPoint(x: x, y: -0.5))
                valueText.draw(at: NSPoint(x: x + width - valueText.size().width, y: 6))
            }
        }
        let valueText = string(value, size: 12, weight: .semibold)
        let width = width(of: widest + [value], size: 12, weight: .semibold)
        return Part(width: width) { x, _, _ in
            valueText.draw(at: NSPoint(x: x + width - valueText.size().width, y: (height - valueText.size().height) / 2))
        }
    }

    private static func twoLinePart(_ lines: [String], widest: [String]) -> Part {
        let texts = lines.prefix(2).map { string($0, size: 8.5, weight: .medium) }
        let width = width(of: widest + lines, size: 8.5, weight: .medium)
        return Part(width: width) { x, _, _ in
            for (index, text) in texts.enumerated() {
                text.draw(at: NSPoint(x: x + width - text.size().width, y: CGFloat(index) * 8.5 - 1))
            }
        }
    }

    /// Kurzbezeichnung links in zwei Zeilen gestapelt, wenn keine Zahl darunter steht.
    private static func sideTagPart(_ tag: String) -> Part {
        let text = string(tag, size: 7, weight: .bold, alpha: MenuBarInk.tag)
        return Part(width: ceil(text.size().width)) { x, _, _ in
            text.draw(at: NSPoint(x: x, y: (height - text.size().height) / 2))
        }
    }

    // MARK: Grafik

    private static func well(_ rect: CGRect, context: CGContext, increasedContrast: Bool) -> CGPath {
        let frame = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.addPath(frame)
        context.setFillColor(MenuBarInk.color(MenuBarInk.well))
        context.fillPath()
        context.addPath(frame)
        context.setStrokeColor(MenuBarInk.color(increasedContrast ? MenuBarInk.wellBorderIncreased : MenuBarInk.wellBorder))
        context.setLineWidth(1)
        context.strokePath()
        return frame
    }

    private static func graphRect(width: CGFloat) -> CGRect {
        CGRect(x: 0.5, y: (height - graphSize.height) / 2, width: width - 1, height: graphSize.height)
    }

    private static func graphPart(_ values: [Double?]) -> Part {
        Part(width: graphSize.width) { x, context, increased in
            let box = graphRect(width: graphSize.width).offsetBy(dx: x, dy: 0)
            let frame = well(box, context: context, increasedContrast: increased)
            context.saveGState()
            context.addPath(frame)
            context.clip()
            drawTrace(values, capacity: pointCount, in: box.insetBy(dx: 1.5, dy: 1.5), context: context)
            context.restoreGState()
        }
    }

    private static func drawTrace(_ values: [Double?], capacity: Int, in plot: CGRect, context: CGContext) {
        context.addPath(SparklineGeometry.area(values, capacity: capacity, in: plot).cgPath)
        context.setFillColor(MenuBarInk.color(MenuBarInk.area))
        context.fillPath()
        context.addPath(SparklineGeometry.line(values, capacity: capacity, in: plot).cgPath)
        context.setStrokeColor(MenuBarInk.color(MenuBarInk.full))
        context.setLineWidth(1.25)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.strokePath()
    }

    /// Empfangen bzw. Lesen nach oben, Senden bzw. Schreiben nach unten, gemeinsame Skala.
    private static func mirrorPart(_ upper: [Double?], _ lower: [Double?]) -> Part {
        Part(width: graphSize.width) { x, context, increased in
            let box = graphRect(width: graphSize.width).offsetBy(dx: x, dy: 0)
            let frame = well(box, context: context, increasedContrast: increased)
            let plot = box.insetBy(dx: 1.5, dy: 1.5)
            let half = plot.height / 2
            context.saveGState()
            context.addPath(frame)
            context.clip()
            drawTrace(upper, capacity: pointCount,
                      in: CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: half), context: context)
            context.translateBy(x: 0, y: plot.maxY + plot.minY)
            context.scaleBy(x: 1, y: -1)
            drawTrace(lower, capacity: pointCount,
                      in: CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: half), context: context)
            context.restoreGState()
            context.setFillColor(MenuBarInk.color(MenuBarInk.midline))
            context.fill(CGRect(x: plot.minX, y: plot.midY - 0.25, width: plot.width, height: 0.5))
        }
    }

    private static func barPart(_ share: Double?) -> Part {
        Part(width: barSize.width) { x, context, _ in
            let rect = CGRect(x: x, y: (height - barSize.height) / 2, width: barSize.width, height: barSize.height)
            let outline = CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            context.addPath(outline)
            context.setFillColor(MenuBarInk.color(MenuBarInk.track))
            context.fillPath()
            guard let share else { return }
            let filled = rect.height * CGFloat(min(max(share, 0), 1))
            context.saveGState()
            context.addPath(outline)
            context.clip()
            context.setFillColor(MenuBarInk.color(MenuBarInk.full))
            context.fill(CGRect(x: rect.minX, y: rect.maxY - filled, width: rect.width, height: filled))
            context.restoreGState()
        }
    }

    /// Thermometer mit Füllstand je Stufe (normal ¼, mäßig ½, ernst ¾, kritisch voll); durchgehend, ohne Segmente.
    private static func thermometerPart(_ level: Double?) -> Part {
        Part(width: 8) { x, context, increased in
            let bulb = CGRect(x: x + 0.5, y: height - 8.5, width: 7, height: 7)
            let stem = CGRect(x: x + 2.25, y: 1.5, width: 3.5, height: height - 7)
            let outline = CGMutablePath()
            outline.addRoundedRect(in: stem, cornerWidth: 1.75, cornerHeight: 1.75)
            outline.addEllipse(in: bulb)
            context.addPath(outline)
            context.setFillColor(MenuBarInk.color(MenuBarInk.track))
            context.fillPath()
            context.addPath(outline)
            context.setStrokeColor(MenuBarInk.color(increased ? MenuBarInk.outlineIncreased : MenuBarInk.outline))
            context.setLineWidth(0.75)
            context.strokePath()
            guard let level else { return }
            context.setFillColor(MenuBarInk.color(MenuBarInk.full))
            context.fillEllipse(in: bulb.insetBy(dx: 1.25, dy: 1.25))
            let filled = (stem.height - 1) * CGFloat(min(max(level, 0), 1))
            context.fill(CGRect(x: stem.minX + 0.75, y: stem.maxY - filled, width: stem.width - 1.5, height: filled))
        }
    }

    private static func batteryPart(_ charge: Double?, isCharging: Bool) -> Part {
        Part(width: 23) { x, context, increased in
            let body = CGRect(x: x + 0.5, y: (height - 10) / 2, width: 20, height: 10)
            let shell = CGPath(roundedRect: body, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            context.addPath(shell)
            context.setStrokeColor(MenuBarInk.color(increased ? MenuBarInk.outlineIncreased : MenuBarInk.tip))
            context.setLineWidth(1)
            context.strokePath()
            context.setFillColor(MenuBarInk.color(MenuBarInk.tip))
            context.fill(CGRect(x: body.maxX + 1, y: body.midY - 2, width: 1.5, height: 4))
            let inner = body.insetBy(dx: 1.75, dy: 1.75)
            if let charge {
                let fill = CGRect(x: inner.minX, y: inner.minY, width: inner.width * CGFloat(min(max(charge, 0), 1)),
                                  height: inner.height)
                context.addPath(CGPath(roundedRect: fill, cornerWidth: 1, cornerHeight: 1, transform: nil))
                context.setFillColor(MenuBarInk.color(MenuBarInk.full))
                context.fillPath()
            }
            guard isCharging else { return }
            let bolt = CGMutablePath()
            let cx = body.midX, top = body.minY - 1.5, bottom = body.maxY + 1.5
            bolt.move(to: CGPoint(x: cx + 1.5, y: top))
            bolt.addLine(to: CGPoint(x: cx - 3, y: body.midY + 0.75))
            bolt.addLine(to: CGPoint(x: cx - 0.25, y: body.midY + 0.75))
            bolt.addLine(to: CGPoint(x: cx - 1.5, y: bottom))
            bolt.addLine(to: CGPoint(x: cx + 3, y: body.midY - 0.75))
            bolt.addLine(to: CGPoint(x: cx + 0.25, y: body.midY - 0.75))
            bolt.closeSubpath()
            context.setBlendMode(.clear)
            context.addPath(bolt)
            context.setLineWidth(2)
            context.strokePath()
            context.setBlendMode(.normal)
            context.addPath(bolt)
            context.setFillColor(MenuBarInk.color(MenuBarInk.full))
            context.fillPath()
        }
    }

    /// Befund-Punkt oben rechts, mit ausgestanztem Rand wie am Grantry-Schild.
    private static func drawFinding(at origin: CGPoint, context: CGContext) {
        let rect = CGRect(origin: origin, size: CGSize(width: findingDiameter, height: findingDiameter))
        context.setBlendMode(.clear)
        context.fillEllipse(in: rect.insetBy(dx: -1.25, dy: -1.25))
        context.setBlendMode(.normal)
        context.setFillColor(MenuBarInk.color(MenuBarInk.full))
        context.fillEllipse(in: rect)
    }
}
