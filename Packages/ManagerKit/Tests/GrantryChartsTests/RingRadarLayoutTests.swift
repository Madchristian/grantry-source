import CoreGraphics
import Testing
@testable import GrantryCharts

/// Anordnung des Ringradars (`RingRadarLayout`): Ringe, Sammel-Echos und Beschriftungen ohne Überlappung, in der
/// kleinen Karte und vergrößert. Die Textmaße sind hier fest (6 pt je Zeichen), damit die Rechnung ohne Schrift prüfbar
/// bleibt.
@Suite struct RingRadarLayoutTests {
    static let measure = RingRadarTextMeasure(label: { CGSize(width: CGFloat($0.count) * 6, height: 12) },
                                              title: { CGSize(width: CGFloat($0.count) * 6, height: 12) })
    static let reachRings = ReachRadar.rings.map { RingRadarLayout.Ring(title: $0.title, capacity: $0.capacity) }
    /// Fläche des Radars in der Karte „Erreichbarkeit“: Spalte 400 abzüglich Panelrand, Höhe `InstrumentSize.radar`.
    static let cardSize = CGSize(width: 376, height: 280)
    static let pageSize = CGSize(width: 1100, height: 640)

    /// Stand des Bildschirmfotos zum Auftrag: 5 Programme nur auf diesem Mac, 19 aus dem Netz erreichbar.
    static let reported: [RingRadarLayout.Entry] = {
        let local = ["ACCpromAdapterDaemon :9200", "Discord :6463", "launchd :8021", "node :3456", "Orca :64270",
                     "Warp :9277"]
        let network = ["ARDAgent :3283", "ControlCenter :5000", "ControlCenter :7000", "Orca :6768", "rapportd :57618",
                       "rapportd :57617", "rapportd :57387"] + (0..<10).map { "dienst\($0) :\(49000 + $0)" }
        return local.map { RingRadarLayout.Entry(id: $0, label: $0, ring: 0) }
            + network.map { RingRadarLayout.Entry(id: $0, label: $0, ring: 2) }
    }()

    static func layout(_ entries: [RingRadarLayout.Entry], size: CGSize, isExpanded: Bool = false,
                       preferred: Set<String> = []) -> RingRadarLayout {
        RingRadarLayout(size: size, rings: reachRings, entries: entries, isExpanded: isExpanded, preferred: preferred,
                        measure: measure)
    }

    /// Flächen, die keine Beschriftung berühren darf, und die Beschriftungen selbst: paarweise getrennt.
    static func overlaps(in layout: RingRadarLayout, size: CGSize) -> [String] {
        var problems: [String] = []
        let bounds = CGRect(origin: .zero, size: size)
        let captions = layout.marks.compactMap { mark in mark.caption.map { (mark, $0) } }
        for (index, (mark, caption)) in captions.enumerated() {
            if !bounds.contains(caption.frame) { problems.append("\(mark.label) ragt über den Rand") }
            for (other, otherCaption) in captions[(index + 1)...] where caption.frame.intersects(otherCaption.frame) {
                problems.append("\(mark.label) überdeckt \(other.label)")
            }
            for other in layout.marks where other.id != mark.id
                && RingRadarLayout.dotFrame(other.point).intersects(caption.frame) {
                problems.append("\(mark.label) überdeckt den Punkt von \(other.label)")
            }
            for (ring, point) in layout.titlePoints.enumerated() {
                let title = measure.title(reachRings[ring].title)
                let frame = CGRect(x: point.x - title.width / 2, y: point.y - title.height / 2, width: title.width,
                                   height: title.height)
                if frame.intersects(caption.frame) { problems.append("\(mark.label) überdeckt den Ringtitel \(ring)") }
            }
            let middle = RingRadarLayout.centerRadius
            if CGRect(x: layout.center.x - middle, y: layout.center.y - middle, width: 2 * middle, height: 2 * middle)
                .intersects(caption.frame) {
                problems.append("\(mark.label) überdeckt die Mitte")
            }
        }
        return problems
    }

    // MARK: Ringe und Sammel-Echos

    @Test func crowdedRingsSummarizeAndKeepTheTopFree() {
        let entries = (0..<12).map { RingRadarLayout.Entry(id: "\($0)", label: "p\($0)", ring: 2) }
            + [RingRadarLayout.Entry(id: "local", label: "postgres", ring: 0)]
        let arranged = RingRadarLayout.arranged(entries, capacities: Self.reachRings.map(\.capacity))
        let network = arranged.filter { $0.entry.ring == 2 }
        #expect(network.count == ReachRadar.maximumPerRing)
        #expect(network.last?.entry.label == "+5")
        #expect(network.last?.isSummary == true)
        // Oben (um 270°) steht der Titel des Rings.
        #expect(arranged.allSatisfy { !(255...285).contains($0.degrees) })
    }

    /// Rechte-Schichten: Jeder Ring fasst nach seiner eigenen Grenze zusammen – innen weniger, weil der Ring kürzer ist.
    @Test func eachRingSummarizesAtItsOwnCapacity() {
        let entries = (0..<5).map { RingRadarLayout.Entry(id: "i\($0)", label: "i\($0)", ring: 0) }
            + (0..<12).map { RingRadarLayout.Entry(id: "a\($0)", label: "a\($0)", ring: 1) }
        let arranged = RingRadarLayout.arranged(entries, capacities: [3, 12])
        let inner = arranged.filter { $0.entry.ring == 0 }
        let outer = arranged.filter { $0.entry.ring == 1 }
        #expect(inner.map(\.entry.label) == ["i0", "i1", "+3"])
        #expect(inner.map(\.isSummary) == [false, false, true])
        #expect(outer.count == 12)
        #expect(outer.last?.entry.label == "a11")
        #expect(arranged.allSatisfy { !(255...285).contains($0.degrees) })
    }

    /// Ringe gleichmäßig von innen (0,34) bis außen (0,93); ein einzelner Ring liegt außen.
    @Test func ringsAreSpacedEvenly() {
        #expect(RingRadarLayout.scale(ring: 0, of: 4) == 0.34)
        #expect(abs(RingRadarLayout.scale(ring: 2, of: 3) - 0.93) < 1e-9)
        #expect(abs(RingRadarLayout.scale(ring: 1, of: 3) - 0.635) < 1e-9)
        #expect(RingRadarLayout.scale(ring: 0, of: 1) == 0.93)
    }

    /// Rechte-Schichten: außen ab 12 Echos zusammengefasst, innen im Verhältnis des kürzeren Rings früher.
    @Test func capacityFollowsCircumference() {
        #expect((0..<4).map { RingRadar.proportionalCapacity(ring: $0, of: 4, outermost: 12) } == [4, 7, 9, 12])
        #expect(RingRadar.proportionalCapacity(ring: 0, of: 1, outermost: 12) == 12)
    }

    /// Echos außerhalb der Ringe fallen weg, statt einen Ring vorzutäuschen.
    @Test func entriesWithoutRingAreDropped() {
        let arranged = RingRadarLayout.arranged([RingRadarLayout.Entry(id: "x", label: "x", ring: 5)], capacities: [4])
        #expect(arranged.isEmpty)
    }

    /// Vergrößert trägt ein Ring, was im Abstand `pitch` auf seinen Bogen passt – nie weniger als in der kleinen Karte.
    @Test func expandedCapacityGrowsWithTheRadius() {
        #expect(RingRadarLayout.expandedCapacity(base: 8, radius: 40) == 8)
        #expect(RingRadarLayout.expandedCapacity(base: 8, radius: 260) == 29)
        #expect(RingRadarLayout.expandedCapacity(base: 8, radius: 520) == 59)
    }

    // MARK: Beschriftungen

    /// Kleine Karte mit dem Stand des Bildschirmfotos: Der äußere Ring fasst zusammen, keine Beschriftung überdeckt
    /// eine andere, einen fremden Punkt, einen Ringtitel oder die Mitte, und jedes Echo bleibt beschriftet.
    @Test func cardCaptionsDoNotOverlap() {
        let layout = Self.layout(Self.reported, size: Self.cardSize)
        #expect(layout.marks.filter(\.isSummary).map(\.label) == ["+10"])
        #expect(Self.overlaps(in: layout, size: Self.cardSize) == [])
        #expect(layout.marks.filter { $0.caption == nil }.map(\.label) == [])
    }

    /// Vergrößert steht jedes Programm einzeln und ungekürzt da.
    @Test func expandedPageShowsEveryEntryWithItsFullCaption() {
        let layout = Self.layout(Self.reported, size: Self.pageSize, isExpanded: true)
        #expect(layout.marks.count == Self.reported.count)
        #expect(layout.marks.filter(\.isSummary).isEmpty)
        #expect(layout.marks.allSatisfy { $0.caption?.text == $0.label })
        #expect(Self.overlaps(in: layout, size: Self.pageSize) == [])
    }

    /// Vergrößert sind die Ringe größer als in der Karte.
    @Test func expandedRingsAreLarger() throws {
        let card = Self.layout([], size: Self.cardSize)
        let page = Self.layout([], size: Self.pageSize, isExpanded: true)
        #expect(zip(card.radii, page.radii).allSatisfy { $0 < $1 })
        let outermost = try #require(page.radii.last)
        #expect(abs(outermost - (Self.pageSize.height / 2 - RingRadarLayout.expandedMargin) * 0.93) < 1e-9)
    }

    /// Auch mit sehr vielen Programmen überdeckt keine Beschriftung eine andere; was keinen Platz findet, steht gekürzt
    /// oder ohne Beschriftung da, der Rest eines vollen Rings als „+n“.
    @Test(arguments: [false, true])
    func crowdedRadarNeverOverlaps(isExpanded: Bool) {
        let entries = (0..<90).map { index in
            RingRadarLayout.Entry(id: "\(index)", label: "programm-\(index) :\(50000 + index)", ring: index % 3)
        }
        let size = isExpanded ? Self.pageSize : Self.cardSize
        let layout = Self.layout(entries, size: size, isExpanded: isExpanded)
        #expect(Self.overlaps(in: layout, size: size) == [])
        #expect(layout.marks.filter(\.isSummary).count == 3)
        #expect(layout.marks.count > (isExpanded ? 50 : 20))
    }

    /// Das gewählte Echo bekommt seinen Platz zuerst und behält die volle Beschriftung.
    @Test func preferredEntryKeepsItsFullCaption() {
        let entries = (0..<8).map { RingRadarLayout.Entry(id: "\($0)", label: "ein-langer-programmname-\($0)", ring: 0) }
        let layout = Self.layout(entries, size: Self.cardSize, preferred: ["7"])
        #expect(layout.marks.first { $0.id == "7" }?.caption?.text == "ein-langer-programmname-7")
        #expect(Self.overlaps(in: layout, size: Self.cardSize) == [])
    }

    /// Gekürzt bleiben Anfang des Namens und der Port lesbar; kurze Beschriftungen bleiben, wie sie sind.
    @Test func shorteningKeepsNameStartAndPort() {
        #expect(RingRadarLayout.shortened("ACCpromAdapterDaemon :9200") == "ACCpro…:9200")
        #expect(RingRadarLayout.shortened("rapportd :57617") == "rappor…57617")
        #expect(RingRadarLayout.shortened("node :3456") == "node :3456")
    }

    /// Der innerste Ring beschriftet zuerst vom Mittelpunkt weg, die übrigen zuerst unter dem Punkt.
    @Test func captionPreferenceDependsOnTheRing() throws {
        let point = CGPoint(x: 100, y: 100), size = CGSize(width: 60, height: 12)
        let inner = try #require(RingRadarLayout.candidates(for: size, at: point, degrees: 0, isInnermost: true).first)
        #expect(inner == CGRect(x: 110, y: 94, width: 60, height: 12))
        let outer = try #require(RingRadarLayout.candidates(for: size, at: point, degrees: 0, isInnermost: false).first)
        #expect(outer == CGRect(x: 70, y: 110, width: 60, height: 12))
    }

    /// Passt der Titel nicht zwischen die obersten Echos eines kleinen Rings, steht er über der Ringlinie.
    @Test func titleOfASmallRingSitsAboveItsLine() {
        #expect(!RingRadarLayout.titleFitsInside(width: 76, radius: 44))
        #expect(RingRadarLayout.titleFitsInside(width: 76, radius: 120))
        let layout = Self.layout([], size: Self.cardSize)
        #expect(layout.titlePoints[0].y < layout.center.y - layout.radii[0])
        #expect(layout.titlePoints[2].y > layout.center.y - layout.radii[2])
    }

    // MARK: Klickflächen (#640)

    /// Das Sammel-Echo steht für die Echos, die keinen Platz fanden; jedes andere für sich selbst.
    @Test func summaryEchoNamesItsMembers() throws {
        let entries = (0..<12).map { RingRadarLayout.Entry(id: "\($0)", label: "p\($0)", ring: 2) }
        let layout = Self.layout(entries, size: Self.cardSize)
        let summary = try #require(layout.marks.last)
        #expect(summary.isSummary)
        #expect(summary.members == (ReachRadar.maximumPerRing - 1..<12).map { "\($0)" })
        #expect(layout.marks.dropLast().allSatisfy { $0.members == [$0.id] })
    }

    /// Jede Klickfläche deckt Punkt und Beschriftung und erreicht keinen fremden Punkt – in der Karte und vergrößert.
    @Test(arguments: [false, true])
    func hitFramesCoverPointAndCaption(isExpanded: Bool) {
        let size = isExpanded ? Self.pageSize : Self.cardSize
        let layout = Self.layout(Self.reported, size: size, isExpanded: isExpanded)
        for mark in layout.marks {
            #expect(mark.hitFrame.contains(mark.point))
            #expect(mark.hitFrame.width >= RingRadarLayout.hitSize)
            if let caption = mark.caption { #expect(mark.hitFrame.contains(caption.frame)) }
            for other in layout.marks where other.id != mark.id {
                #expect(!mark.hitFrame.contains(other.point), "\(mark.label) erreicht \(other.label)")
            }
        }
    }

    // MARK: VoiceOver und Knopf

    /// VoiceOver liest jedes Echo einzeln von innen nach außen, auch die im Bild zusammengefassten.
    @Test func voiceOverReadsEveryEchoIndividually() {
        let rings = [RingRadar.Ring(title: "innen", capacity: 1), RingRadar.Ring(title: "außen", capacity: 2)]
        let echoes = [RingRadar.Echo(id: "a", label: "a", ring: 1), RingRadar.Echo(id: "b", label: "b", ring: 0),
                      RingRadar.Echo(id: "c", label: "c", ring: 0, accessibilityLabel: "c, eigener Text"),
                      RingRadar.Echo(id: "x", label: "x", ring: 7)]
        #expect(RingRadar.spoken(echoes, rings: rings).map(\.plainText) == ["b, innen", "c, eigener Text", "a, außen"])
    }

    @Test func expandButtonNamesItsCardAndState() {
        #expect(InstrumentExpandButton.spokenLabel(title: "Erreichbarkeit", isExpanded: false)
            == "Erreichbarkeit vergrößern")
        #expect(InstrumentExpandButton.spokenLabel(title: "Erreichbarkeit", isExpanded: true)
            == "Erreichbarkeit verkleinern")
        #expect(InstrumentExpandButton.helpText(isExpanded: false) == "Auf die ganze Seite vergrößern")
        #expect(InstrumentExpandButton.helpText(isExpanded: true) == "Verkleinern (esc)")
        #expect(InstrumentExpandButton.symbol(isExpanded: false) != InstrumentExpandButton.symbol(isExpanded: true))
    }
}
