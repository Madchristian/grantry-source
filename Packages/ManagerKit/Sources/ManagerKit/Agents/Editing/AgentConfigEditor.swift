import Foundation

/// Berechnet den neuen Inhalt einer Agenten-Konfiguration für genau eine Änderung an einem Server und prüft ihn nach
/// (Stufe 2). Rein, ohne Dateizugriff.
///
/// Ablauf: Inhalt parsen (mit derselben Schwärzung wie der Scan), Server suchen, Änderung textuell berechnen
/// (`JSONConfigEditor`, `TOMLConfigEditor`), Ergebnis neu parsen und mit dem erwarteten Baum vergleichen
/// (`ConfigValue.isEquivalent`) – weicht es ab, wird nichts geschrieben (`verificationFailed`). Eine UTF-8-BOM bleibt
/// erhalten.
struct AgentConfigEditor: Sendable {
    enum Operation: Hashable, Sendable {
        case remove
        case setEnabled(Bool)
    }

    let target: AgentServerTarget
    /// Schlüssel der Transport-Fingerabdrücke – derselbe wie im Scan (`AgentConfigActions`), sonst wären die
    /// Fingerabdrücke von `expected` und dem frisch gelesenen Eintrag nie vergleichbar.
    var fingerprinter: SecretFingerprinter = .processLocal

    /// Neuer Inhalt nach `operation`. Mit `expected` muss der Server noch der angezeigte sein, sonst `entryChanged`.
    /// Verglichen wird nur der Transport (Befehl samt Argumenten bzw. URL und Art) samt seinem Fingerabdruck
    /// (`MCPServerEntry.hasSameTransport`) – nicht der Schalter (den ändert die Operation ja), nicht Umgebung oder Header
    /// (deren Werte sind geschwärzt) und nichts Abgeleitetes.
    func apply(_ operation: Operation, expected: MCPServerEntry?, to contents: Data) throws(AgentConfigEditError) -> Data {
        let (byteOrderMark, body) = ConfigParsing.splittingByteOrderMark(contents)
        let tree = try parse(body, containers: [])
        guard let serverPath = try target.serverPath(in: tree), let current = target.currentEntry(in: tree, fingerprinter: fingerprinter) else {
            try refuseEntriesInArraysOfTables(body, tree: tree)
            throw .entryChanged
        }
        if let expected, !expected.hasSameTransport(as: current) { throw .entryChanged }
        var result: [UInt8]
        switch operation {
        case .remove:
            result = try removal(at: serverPath, in: body, tree: tree)
        case .setEnabled(let enabled):
            guard current.isEnabled != enabled else { throw .alreadyInState }
            result = try switching(enabled, at: serverPath, in: body, tree: tree)
        }
        return Data(byteOrderMark + result)
    }

    /// Fügt den entfernten Server aus `backup` (der Datei vor der Änderung) wieder in `contents` ein.
    /// Steht dort schon ein Server dieses Namens: `alreadyInState` nur, wenn sein Quelltext byte-gleich dem aus der
    /// Sicherung ist, sonst `nameTaken`. Der Baum taugt dafür nicht – Geheimwerte (`env`, `headers`) sind darin
    /// geschwärzt; ein falsches „schon da“ löschte die einzige Sicherung samt dieser Werte, ein falscher Konflikt
    /// schadet nicht. Lässt sich der Quelltext nicht bestimmen (doppelter Name, mehrere Listen), ist das
    /// `unsupportedLayout` – kein Konflikt.
    func reinsert(from backup: Data, into contents: Data) throws(AgentConfigEditError) -> Data {
        let (byteOrderMark, body) = ConfigParsing.splittingByteOrderMark(contents)
        let backupBody = ConfigParsing.splittingByteOrderMark(backup).body
        let tree = try parse(body, containers: [])
        let backupTree = try parse(backupBody, containers: [])
        guard let serverPath = try target.serverPath(in: backupTree), let server = backupTree.value(at: serverPath) else {
            throw .backupUnusable("der Server fehlt darin")
        }
        let parent = Array(serverPath.dropLast())
        let backupDocument = try document(backupBody, containers: [parent])
        if let currentPath = try target.serverPath(in: tree) {
            let current = try entryText(at: currentPath, in: document(body, containers: [Array(currentPath.dropLast())]))
            guard current == (try entryText(at: serverPath, in: backupDocument)) else { throw .nameTaken }
            throw .alreadyInState
        }
        let document = try document(body, containers: [parent])
        let edits: [ByteEdit]
        switch target.syntax {
        case .json, .jsonc:
            guard tree.value(at: parent)?.object != nil else { throw .unsupportedLayout }
            let member = try JSONConfigEditor.memberText(target.reference.name, inObjectAt: parent, of: backupDocument)
            edits = try JSONConfigEditor.insert(member, intoContainerAt: parent, of: document)
        case .toml:
            edits = try TOMLConfigEditor.reinsertEntry(at: serverPath, from: backupDocument, into: document)
        }
        let result = try verified(body.applying(edits), expected: [tree.setting(serverPath, to: server)]) { entry in
            entry != nil
        }
        return Data(byteOrderMark + result)
    }

    /// Stellt den Schalter des Servers auf `enabled` zurück – fürs Wiederherstellen, wenn sich die Datei seit der
    /// Änderung geändert hat. Der Server muss noch der aus `backup` (der Datei vor der Änderung) sein: Verglichen wird
    /// sein ganzer Eintrag ohne den Schalter (`serverIdentity`), ungeschwärzt aus beiden Dateiinhalten – Transport,
    /// `env`, Header, Zugangsdaten und alle übrigen Felder. Weder der maskierte Transport (`?server=alpha` und
    /// `?server=beta` sind darin gleich) noch der geschwärzte Baum (`DATABASE_URL` Test und Prod sind darin gleich)
    /// taugen dafür. Weicht er ab, stellte ein alter Beleg einen inzwischen anderen Server an: `nameTaken`, die
    /// Sicherung bleibt. Fehlt der Server in der Sicherung, `backupUnusable`; in der Datei, `entryChanged`; steht der
    /// Schalter schon so, `alreadyInState` – das erst nach dem Vergleich.
    func revertSwitch(to enabled: Bool, from backup: Data, into contents: Data) throws(AgentConfigEditError) -> Data {
        guard let expected = try serverIdentity(in: backup) else { throw .backupUnusable("der Server fehlt darin") }
        guard let current = try serverIdentity(in: contents) else { throw .entryChanged }
        guard current.isEquivalent(to: expected) else { throw .nameTaken }
        return try apply(.setEnabled(enabled), expected: nil, to: contents)
    }

    /// Der Eintrag des Servers in `contents` ohne seinen Schalter (`Switch.field`; eine Namensliste steht ohnehin
    /// außerhalb) – ungeschwärzt geparst, nur zum Vergleichen im Speicher: Er gelangt in keinen Snapshot und keinen
    /// Beleg. `nil`, wenn der Server fehlt.
    private func serverIdentity(in contents: Data) throws(AgentConfigEditError) -> ConfigValue? {
        let tree = try AgentConfigEditError.parsing { () throws(ConfigParseError) in
            try ConfigParsing.parse(contents, syntax: target.syntax, redaction: .none)
        }
        guard let serverPath = try target.serverPath(in: tree), let server = tree.value(at: serverPath) else { return nil }
        guard case .field(let key, _)? = target.switchKind else { return server }
        return server.removing([key])
    }

    /// Quelltext des Servers unter `serverPath` (JSON: das Mitglied, TOML: seine Teile) – nur zum Vergleichen.
    private func entryText(at serverPath: [String], in document: ConfigDocument) throws(AgentConfigEditError) -> [[UInt8]] {
        switch target.syntax {
        case .json, .jsonc: [try JSONConfigEditor.memberText(target.reference.name, inObjectAt: Array(serverPath.dropLast()), of: document)]
        case .toml: try TOMLConfigEditor.entryText(at: serverPath, of: document)
        }
    }

    /// Fehlt der Server im Baum, kann er bei TOML im letzten Element eines `[[…]]` stehen – das ist Lage
    /// (`unsupportedLayout`), kein „fehlt“.
    private func refuseEntriesInArraysOfTables(_ body: [UInt8], tree: ConfigValue) throws(AgentConfigEditError) {
        guard target.syntax == .toml else { return }
        let document = try document(body, containers: [])
        for list in target.serverLists(in: tree) where try TOMLConfigEditor.isInArrayOfTables(list + [target.reference.name], of: document) {
            throw .unsupportedLayout
        }
    }

    // MARK: Entfernen

    private func removal(at serverPath: [String], in body: [UInt8], tree: ConfigValue) throws(AgentConfigEditError) -> [UInt8] {
        let parent = Array(serverPath.dropLast())
        let document = try document(body, containers: [parent])
        let edits = switch target.syntax {
        case .json, .jsonc: try JSONConfigEditor.removeMember(target.reference.name, inObjectAt: parent, of: document)
        case .toml: try TOMLConfigEditor.removeEntry(at: serverPath, of: document)
        }
        let expected = tree.removing(serverPath)
        // TOML kennt eine nur implizit angelegte Elterntabelle danach nicht mehr – beides ist richtig. JSON behält das
        // leere Objekt immer.
        let candidates = target.syntax == .toml ? [expected, expected.removingEmptyObjects(along: parent)] : [expected]
        return try verified(body.applying(edits), expected: candidates) { $0 == nil }
    }

    // MARK: Schalten

    private func switching(_ enabled: Bool, at serverPath: [String], in body: [UInt8], tree: ConfigValue) throws(AgentConfigEditError) -> [UInt8] {
        switch target.switchKind {
        case .field(let key, let inverted)?:
            let stored = inverted ? !enabled : enabled
            let path = serverPath + [key]
            guard tree.value(at: path).map({ $0.bool != nil }) ?? true else { throw .unsupportedLayout }
            let document = try document(body, containers: [serverPath])
            let edits = switch target.syntax {
            case .json, .jsonc: try JSONConfigEditor.setMember(key, to: ConfigText.bool(stored), inObjectAt: serverPath, of: document)
            case .toml: try TOMLConfigEditor.setBool(stored, key: key, ofEntryAt: serverPath, of: document)
            }
            return try verified(body.applying(edits), expected: [tree.setting(path, to: .bool(stored))]) { $0?.isEnabled == enabled }
        case .disabledNames(let relativePath)?:
            guard target.syntax != .toml, let project = target.projectObjectPath(in: tree), let listName = relativePath.last else {
                throw .unsupportedLayout
            }
            let listPath = project + relativePath
            return try switchingNameList(enabled, listPath: listPath, listName: listName, in: body, tree: tree)
        case nil:
            throw .unsupportedLayout
        }
    }

    /// Nimmt den Namen in die Liste abgeschalteter Server auf bzw. entfernt jedes Vorkommen daraus. Fehlt die Liste,
    /// wird sie mit dem Namen angelegt.
    private func switchingNameList(
        _ enabled: Bool, listPath: [String], listName: String, in body: [UInt8], tree: ConfigValue
    ) throws(AgentConfigEditError) -> [UInt8] {
        let name = ConfigValue.string(target.reference.name)
        let objectPath = Array(listPath.dropLast())
        guard let list = tree.value(at: listPath) else {
            guard !enabled else { throw .alreadyInState }
            let document = try document(body, containers: [objectPath])
            let edits = try JSONConfigEditor.setMember(listName, to: Array("[".utf8) + ConfigText.jsonString(target.reference.name) + Array("]".utf8),
                                                       inObjectAt: objectPath, of: document)
            return try verified(body.applying(edits), expected: [tree.setting(listPath, to: .array([name]))]) { $0?.isEnabled == false }
        }
        guard let elements = list.array else { throw .unsupportedLayout }
        let document = try document(body, containers: [listPath])
        if !enabled {
            let edits = try JSONConfigEditor.insert(ConfigText.jsonString(target.reference.name), intoContainerAt: listPath, of: document)
            return try verified(body.applying(edits), expected: [tree.setting(listPath, to: .array(elements + [name]))]) { $0?.isEnabled == false }
        }
        guard let index = elements.firstIndex(of: name) else { throw .alreadyInState }
        var remaining = elements
        remaining.remove(at: index)
        let edits = try JSONConfigEditor.removeElement(at: index, fromArrayAt: listPath, of: document)
        let isLast = !remaining.contains(name)
        let result = try verified(body.applying(edits), expected: [tree.setting(listPath, to: .array(remaining))]) { entry in
            !isLast || entry?.isEnabled == true
        }
        // Steht der Name mehrfach in der Liste, je Durchgang ein Vorkommen.
        return isLast ? result : try switchingNameList(true, listPath: listPath, listName: listName, in: result,
                                                       tree: try parse(result, containers: []))
    }

    // MARK: Prüfen

    /// Parst `result` neu und verlangt einen der `expected`-Bäume sowie einen Server-Zustand, den `isExpected` annimmt.
    private func verified(
        _ result: [UInt8], expected: [ConfigValue], _ isExpected: (MCPServerEntry?) -> Bool
    ) throws(AgentConfigEditError) -> [UInt8] {
        let tree: ConfigValue
        do {
            tree = try ConfigParsing.parse(Data(result), syntax: target.syntax, redaction: target.redaction)
        } catch {
            throw .verificationFailed
        }
        guard expected.contains(where: tree.isEquivalent), isExpected(target.currentEntry(in: tree, fingerprinter: fingerprinter)) else {
            throw .verificationFailed
        }
        return result
    }

    private func parse(_ body: [UInt8], containers: Set<[String]>) throws(AgentConfigEditError) -> ConfigValue {
        try document(body, containers: containers).tree
    }

    private func document(_ body: [UInt8], containers: Set<[String]>) throws(AgentConfigEditError) -> ConfigDocument {
        try AgentConfigEditError.parsing { () throws(ConfigParseError) in
            try ConfigDocument(bytes: body, syntax: target.syntax, redaction: target.redaction, containers: containers)
        }
    }
}
