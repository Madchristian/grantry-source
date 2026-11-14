import AppKit
import CoreGraphics

/// Anordnung des Ringradars (`RingRadar`): Radien der Ringe, Echos je Ring samt Sammel-Echo „+n“ und die Plätze der
/// Beschriftungen, ohne dass zwei einander, einen Peilpunkt, einen Ringtitel oder die Mitte überdecken. Reine Rechnung
/// ohne Ansicht; die Textmaße kommen von außen (`RingRadarTextMeasure`), damit Tests ohne Schriften rechnen.
///
/// Jede Beschriftung nimmt den ersten freien Platz ihrer Vorzugsreihenfolge am Punkt (darunter, vom Mittelpunkt weg,
/// darüber, seitlich, schräg). Findet sich keiner, steht sie gekürzt da, danach eine Zeile weiter weg; passt auch das
/// nicht, bleibt der Punkt ohne Beschriftung – die Liste für VoiceOver und die Tabelle daneben nennen ihn weiter.
struct RingRadarLayout: Equatable {
    struct Ring: Equatable {
        let title: String
        /// Höchstens so viele Echos in der kleinen Karte; vergrößert trägt der Ring, was sein Umfang fasst.
        let capacity: Int
    }

    struct Entry: Hashable {
        let id: String
        let label: String
        /// Index des Rings von innen nach außen.
        let ring: Int
    }

    struct Caption: Equatable {
        /// Beschriftung wie gezeichnet, gegebenenfalls gekürzt.
        let text: String
        let frame: CGRect
    }

    struct Mark: Equatable, Identifiable {
        let id: String
        let label: String
        let ring: Int
        /// Sammel-Echo „+n“ für den Rest eines vollen Rings.
        let isSummary: Bool
        let degrees: Double
        let point: CGPoint
        /// `nil`, wenn für die Beschriftung kein freier Platz blieb.
        let caption: Caption?
    }

    let center: CGPoint
    /// Radius je Ring von innen nach außen.
    let radii: [CGFloat]
    /// Mittelpunkt des Titels je Ring: oben unter der Ringlinie, bei einem zu kleinen Ring über ihr.
    let titlePoints: [CGPoint]
    let marks: [Mark]

    /// Bogen der Echos: 300° über unten, oben bleibt der Ringtitel frei.
    static let arcDegrees = 300.0
    /// Kleinster Abstand zweier Echos auf einem vergrößerten Ring.
    static let pitch: CGFloat = 46
    /// Rand um den äußeren Ring: klein wie der Panelabstand, vergrößert mit Platz für Beschriftungen in zwei Zeilen.
    static let compactMargin: CGFloat = 12
    static let expandedMargin: CGFloat = 40
    /// Halbe Kantenlänge der Fläche, die ein Peilpunkt freihält.
    static let dotClearance: CGFloat = 5
    /// Abstand vom Punkt zur Mitte einer Beschriftung darunter oder darüber und zur Kante einer seitlichen.
    static let captionOffset: CGFloat = 16
    static let sideOffset: CGFloat = 10
    static let cornerOffset: CGFloat = 6
    /// Luft zwischen zwei Beschriftungen und zwischen gestaffelten Zeilen.
    static let captionGap: CGFloat = 2
    /// Abstand des Ringtitels von der Ringlinie.
    static let titleInset: CGFloat = 10
    /// Halber Durchmesser der Mitte mit dem Symbol.
    static let centerRadius: CGFloat = 22
    /// Länge einer gekürzten Beschriftung in Zeichen.
    static let shortenedLength = 12

    /// - Parameters:
    ///   - isExpanded: Vergrößerte Karte: Ringe tragen so viele Echos, wie ihr Umfang fasst.
    ///   - preferred: Echo, dessen Beschriftung zuerst einen Platz bekommt (das gewählte).
    init(size: CGSize, rings: [Ring], entries: [Entry], isExpanded: Bool = false, preferred: String? = nil,
         measure: RingRadarTextMeasure) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let base = max(min(size.width, size.height) / 2 - (isExpanded ? Self.expandedMargin : Self.compactMargin), 0)
        let radii = rings.indices.map { base * Self.scale(ring: $0, of: rings.count) }
        let titleSizes = rings.map { measure.title($0.title) }
        let titlePoints = rings.indices.map { index in
            CGPoint(x: center.x, y: center.y - radii[index]
                + (Self.titleFitsInside(width: titleSizes[index].width, radius: radii[index]) ? 1 : -1) * Self.titleInset)
        }
        let capacities = rings.indices.map { index in
            isExpanded ? Self.expandedCapacity(base: rings[index].capacity, radius: radii[index]) : rings[index].capacity
        }
        let arranged = Self.arranged(entries, capacities: capacities)
        let points = arranged.map { item -> CGPoint in
            let angle = item.degrees * .pi / 180
            let radius = radii[item.entry.ring]
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }

        var packer = CaptionPacker(bounds: CGRect(origin: .zero, size: size), dots: points.map(Self.dotFrame))
        packer.reserve(Self.dotFrame(center).insetBy(dx: Self.dotClearance - Self.centerRadius,
                                                     dy: Self.dotClearance - Self.centerRadius))
        for (index, titleSize) in titleSizes.enumerated() {
            packer.reserve(CGRect(x: titlePoints[index].x - titleSize.width / 2,
                                  y: titlePoints[index].y - titleSize.height / 2,
                                  width: titleSize.width, height: titleSize.height))
        }
        // Das gewählte Echo zuerst, dann von innen nach außen: innen ist am wenigsten Platz.
        let order = arranged.indices.sorted { lhs, rhs in
            (arranged[lhs].entry.id == preferred ? 0 : 1, lhs) < (arranged[rhs].entry.id == preferred ? 0 : 1, rhs)
        }
        var captions = [Caption?](repeating: nil, count: arranged.count)
        for index in order {
            let item = arranged[index]
            let texts = [item.entry.label, Self.shortened(item.entry.label)].reduce(into: [String]()) { result, text in
                if !result.contains(text) { result.append(text) }
            }
            let isInnermost = item.entry.ring == 0 && rings.count > 1
            // Erst alle Plätze am Punkt, voll und dann gekürzt; zuletzt eine Zeile weiter weg, wo die Zuordnung leidet.
            let attempts = texts.map { ($0, false) } + texts.map { ($0, true) }
            for (text, isDetached) in attempts {
                let size = measure.label(text)
                let frames = isDetached ? Self.detachedCandidates(for: size, at: points[index])
                    : Self.candidates(for: size, at: points[index], degrees: item.degrees, isInnermost: isInnermost)
                if let frame = packer.place(frames, owner: index) {
                    captions[index] = Caption(text: text, frame: frame)
                    break
                }
            }
        }

        self.center = center
        self.radii = radii
        self.titlePoints = titlePoints
        marks = arranged.indices.map { index in
            let item = arranged[index]
            return Mark(id: item.entry.id, label: item.entry.label, ring: item.entry.ring, isSummary: item.isSummary,
                        degrees: item.degrees, point: points[index], caption: captions[index])
        }
    }

    // MARK: Ringe

    /// Radius eines Rings relativ zum halben Durchmesser: gleichmäßig von 0,34 (innen) bis 0,93 (außen).
    static func scale(ring: Int, of count: Int) -> CGFloat {
        guard count > 1 else { return 0.93 }
        return 0.34 + 0.59 * CGFloat(ring) / CGFloat(count - 1)
    }

    /// Grenze eines Rings im Verhältnis seines Umfangs zum äußersten, der `outermost` Echos fasst – innen liegen die
    /// Beschriftungen sonst übereinander.
    static func proportionalCapacity(ring: Int, of count: Int, outermost: Int) -> Int {
        max(1, Int((Double(outermost) * scale(ring: ring, of: count) / scale(ring: count - 1, of: count)).rounded()))
    }

    /// Grenze eines vergrößerten Rings: so viele Echos, wie im Abstand `pitch` auf seinen Bogen passen, nie weniger als
    /// in der kleinen Karte.
    static func expandedCapacity(base: Int, radius: CGFloat) -> Int {
        max(base, Int(radius * arcDegrees * .pi / 180 / pitch))
    }

    /// Echos je Ring mit Winkel (Grad); über der Grenze des Rings ein Sammel-Echo „+n“. Die Ringe sind gegeneinander
    /// versetzt, damit Beschriftungen benachbarter Ringe nicht übereinander liegen; oben bleibt Platz für den Ringtitel.
    /// Echos ohne passenden Ring fallen weg.
    static func arranged(_ entries: [Entry], capacities: [Int]) -> [(entry: Entry, isSummary: Bool, degrees: Double)] {
        capacities.indices.flatMap { index -> [(entry: Entry, isSummary: Bool, degrees: Double)] in
            let capacity = max(capacities[index], 1)
            var members = entries.filter { $0.ring == index }.map { (entry: $0, isSummary: false) }
            if members.count > capacity {
                let rest = members.count - (capacity - 1)
                members = Array(members.prefix(capacity - 1))
                    + [(Entry(id: "more-\(index)", label: "+\(rest)", ring: index), true)]
            }
            // Bogen von 300° über unten bis 240° (oben bleibt frei); je Ring um ein Viertel Schritt versetzt.
            let step = arcDegrees / Double(max(members.count, 1))
            let shift = 0.25 * Double(index - 1)
            return members.enumerated().map { position, member in
                (member.entry, member.isSummary,
                 (arcDegrees + step * (Double(position) + 0.5 + shift)).truncatingRemainder(dividingBy: 360))
            }
        }
    }

    // MARK: Beschriftungen

    /// Kürzt in der Mitte auf `shortenedLength` Zeichen: Anfang des Namens und Ende (der Port) bleiben lesbar.
    static func shortened(_ label: String) -> String {
        guard label.count > shortenedLength else { return label }
        let tail = (shortenedLength - 1) / 2
        return label.prefix(shortenedLength - 1 - tail).trimmingCharacters(in: .whitespaces) + "…"
            + label.suffix(tail).trimmingCharacters(in: .whitespaces)
    }

    /// Mögliche Plätze einer Beschriftung in Vorzugsreihenfolge. Der innerste Ring beschriftet zuerst vom Mittelpunkt
    /// weg (unter dem Punkt läge die Beschriftung auf der Mitte), die übrigen zuerst unter dem Punkt.
    static func candidates(for size: CGSize, at point: CGPoint, degrees: Double, isInnermost: Bool) -> [CGRect] {
        let angle = degrees * .pi / 180
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        func centered(dy: CGFloat) -> CGRect {
            CGRect(x: point.x - size.width / 2, y: point.y + dy - size.height / 2, width: size.width, height: size.height)
        }
        /// Beschriftung, deren dem Punkt zugewandte Ecke im Abstand `sideOffset` auf dem Strahl liegt.
        func radial(_ sign: CGFloat) -> CGRect {
            let anchor = CGPoint(x: 0.5 - 0.5 * sign * direction.x, y: 0.5 - 0.5 * sign * direction.y)
            return CGRect(x: point.x + sign * direction.x * sideOffset - anchor.x * size.width,
                          y: point.y + sign * direction.y * sideOffset - anchor.y * size.height,
                          width: size.width, height: size.height)
        }
        let below = centered(dy: captionOffset), above = centered(dy: -captionOffset)
        let trailing = CGRect(x: point.x + sideOffset, y: point.y - size.height / 2, width: size.width, height: size.height)
        let leading = trailing.offsetBy(dx: -size.width - 2 * sideOffset, dy: 0)
        let first = isInnermost ? [radial(1), below, above] : [below, radial(1), above]
        // Auf der rechten Hälfte zuerst nach rechts, links zuerst nach links: weg von der Mitte.
        let sides = direction.x >= 0 ? [trailing, leading] : [leading, trailing]
        /// Schräg am Punkt: die ihm zugewandte Ecke im Abstand `cornerOffset`.
        func corner(_ horizontal: CGFloat, _ vertical: CGFloat) -> CGRect {
            CGRect(x: horizontal > 0 ? point.x + cornerOffset : point.x - cornerOffset - size.width,
                   y: vertical > 0 ? point.y + cornerOffset : point.y - cornerOffset - size.height,
                   width: size.width, height: size.height)
        }
        let outwardX: CGFloat = direction.x >= 0 ? 1 : -1, outwardY: CGFloat = direction.y >= 0 ? 1 : -1
        let corners = [corner(outwardX, outwardY), corner(outwardX, -outwardY), corner(-outwardX, outwardY),
                       corner(-outwardX, -outwardY)]
        return first + sides + corners + [radial(-1)]
    }

    /// Plätze eine Zeile weiter unter und über dem Punkt, wenn an ihm nichts frei ist.
    static func detachedCandidates(for size: CGSize, at point: CGPoint) -> [CGRect] {
        let offset = captionOffset + size.height + captionGap
        return [offset, -offset].map { dy in
            CGRect(x: point.x - size.width / 2, y: point.y + dy - size.height / 2, width: size.width, height: size.height)
        }
    }

    /// Ob der Titel eines Rings unter dessen Linie zwischen die obersten Echos passt (oben bleiben 60° frei); sonst
    /// steht er über der Linie.
    static func titleFitsInside(width: CGFloat, radius: CGFloat) -> Bool {
        let freeHalfWidth = radius * sin((360 - arcDegrees) / 2 * .pi / 180)
        return width / 2 + dotClearance <= freeHalfWidth
    }

    static func dotFrame(_ point: CGPoint) -> CGRect {
        CGRect(x: point.x - dotClearance, y: point.y - dotClearance, width: 2 * dotClearance, height: 2 * dotClearance)
    }
}

/// Vergibt Plätze für Beschriftungen: innerhalb der Fläche, ohne belegte Flächen und ohne fremde Peilpunkte.
private struct CaptionPacker {
    let bounds: CGRect
    let dots: [CGRect]
    private var occupied: [CGRect] = []

    init(bounds: CGRect, dots: [CGRect]) {
        self.bounds = bounds
        self.dots = dots
    }

    mutating func reserve(_ frame: CGRect) {
        occupied.append(frame)
    }

    /// Erster freier Platz aus `frames`; der Punkt `owner` gehört zur Beschriftung und zählt nicht als Hindernis.
    mutating func place(_ frames: [CGRect], owner: Int) -> CGRect? {
        let gap = RingRadarLayout.captionGap
        guard let frame = frames.first(where: { frame in
            let padded = frame.insetBy(dx: -gap / 2, dy: -gap / 2)
            return bounds.contains(frame) && !occupied.contains { $0.intersects(padded) }
                && !dots.indices.contains { $0 != owner && dots[$0].intersects(frame) }
        }) else { return nil }
        occupied.append(frame.insetBy(dx: -gap / 2, dy: -gap / 2))
        return frame
    }
}

/// Maße der Texte im Ringradar: Beschriftung eines Echos und Titel eines Rings.
struct RingRadarTextMeasure: Sendable {
    let label: @Sendable (String) -> CGSize
    let title: @Sendable (String) -> CGSize

    /// Maße der Systemschrift wie gezeichnet (`InstrumentFont.micro`, Beschriftung mittel, Titel halbfett), auf ganze
    /// Punkte aufgerundet.
    static let system = RingRadarTextMeasure(label: { size(of: $0, weight: .medium) },
                                             title: { size(of: $0, weight: .semibold) })

    private static func size(of text: String, weight: NSFont.Weight) -> CGSize {
        let pointSize = NSFont.preferredFont(forTextStyle: .caption2).pointSize
        let size = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: pointSize,
                                                                                         weight: weight)]).size()
        return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }
}
