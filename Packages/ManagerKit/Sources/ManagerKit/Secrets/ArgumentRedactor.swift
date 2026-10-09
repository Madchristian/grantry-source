import Foundation

/// Maskiert Geheimnisse in Argumenten und URLs, bevor sie im Snapshot landen (Spec §3) – für MCP-Server wie für
/// Programm und `ProgramArguments` von launchd-Einträgen (`MaskedCommand`, #137). Best-Effort, erkannt werden:
/// - Passwörter im URL-Userinfo (`user:pass@host`),
/// - Werte von Query- und Fragment-Parametern (alle maskiert, nur geheimnisartige Namen zählen als Geheimnis),
/// - Webhook-/Bot-Token im URL-Pfad (Slack, Discord, Telegram),
/// - `--flag=wert` und `NAME=wert` mit geheimnisartigem Namen; bei gewöhnlichem Namen wird der Wert wie ein eigenes
///   Argument behandelt (`--header=Authorization: Bearer x`),
/// - der Wert nach einem geheimnisartigen Flag (`--token abc`) – auch wenn er mit `-` beginnt (`--password -x`):
///   Passwörter dürfen so anfangen; ein Flag, das stattdessen folgt (`--token --verbose`), wird in Kauf genommen.
///   Ist es selbst geheimnisartig (`--auth --password x`), maskiert es seinerseits den nächsten Wert,
/// - `Name: wert`-Header und `Bearer x`,
/// - Connection-Strings mit `;` (`Server=x;Password=y`). Getrennt wird nur an einem `;` außerhalb von Zitaten
///   (`'…'`, `"…"`, ODBC-`{…}` direkt hinter `=`), nicht hinter `\` und nicht im Userinfo einer URL
///   (`postgres://u:pw;x@h`) – ein Trenner in einem Wert beginnt nie ein neues Segment (`--password 'a;b'`),
/// - Argumente und Werte, die wie ein bekanntes Token aussehen: Präfix wie `ghp_`, `sk-` oder `AKIA`, mindestens
///   16 Zeichen und mindestens eine Ziffer dahinter (bei `hf_` und `gh?_` nur `A–Z a–z 0–9`),
/// - Argumente mit Leerzeichen (Shell-Aufrufe wie `sh -c "export T=x && run"`): Jedes Wort wird wie ein eigenes
///   Argument behandelt, der Leerraum bleibt erhalten. Ein Anführungszeichen am Wortanfang oder direkt hinter `=` bzw.
///   `:` hält alles bis zum passenden schließenden Anführungszeichen (und den Rest dieses Worts) zusammen, damit
///   `PASSWORD='my secret'` als ein Wert maskiert wird; ohne schließendes Zeichen reicht der Wert bis zum Ende des
///   Arguments. Mitten im Wort öffnet ein Anführungszeichen nur, wenn ein gleiches folgt (`don't` bleibt ein Wort);
///   ein `\` hält das nächste Zeichen im Wort (`a\ b`).
///   Ausgewertet wird jedes Wort so, wie das Programm es bekommt (`ShellWord.literal`: ohne Anführungszeichen und
///   Escapes) – Flags wie `'--password'`, `--pass"word"` oder `\--password` wirken wie `--password`, und
///   `--'password'=x` ist eine Zuweisung. Bleibt dabei nichts zu maskieren, steht das Wort unverändert da; ein ganz in
///   Anführungszeichen stehendes Wort behält sie (`"X-Api-Key: •••"`), sonst erscheint es entquotet.
///
/// Platzhalter (`${input:x}`, `$VAR`) werden maskiert, gelten aber nicht als Geheimnis im Klartext. Dasselbe gilt für
/// leere Werte (bleiben leer), Pfade (`/…`, `~/…`, `./…`, `../…`), reine Zahlen, die Standardeingabe (`-`) und
/// Schlüsselwörter (`true`, `none`, `oauth` …, siehe `nonSecretKeywords`).
///
/// Bekannte Grenzen (bewusst offen):
/// - Als ein Argument übergebenes JSON (`{"token":"x"}`) wird nicht geparst.
/// - Schemalose DSNs wie `user:pass@tcp(host)/db` werden nicht erkannt.
/// - `\;` gilt wie in der Shell als geschützt: Ein Connection-String mit einem Windows-Pfad, der direkt vor `;` auf
///   `\` endet (`Server=C:\db\;Password=y`), wird dort nicht getrennt.
/// - Geheimnisse ohne geheimnisartigen Namen und ohne bekanntes Token-Präfix bleiben unentdeckt.
/// - Shell-Skripte und unterstützter Inline-Code werden nie teilweise maskiert, sondern ganz oder gar nicht (`ShellSyntax`). Andere
///   Shell-Strings in Argumenten werden nur oberflächlich zerlegt: `$(…)`, Variablen, Here-Documents und
///   verschachtelte Zitate werden nicht ausgewertet. Fließtext mit einem Flag-Wort
///   (`use the --token flag`) wird wie ein Aufruf behandelt und kann falsch gemeldet werden.
/// - Mehr als `maximumNestingDepth` verschachtelte Zuweisungen oder Connection-Strings werden ab dort vollständig
///   maskiert (Schutz vor überlangen, absichtlich verschachtelten Eingaben).
enum ArgumentRedactor {
    /// Ersatz für jeden maskierten Wert.
    static let mask = "•••"

    /// Oberhalb dieser Argumentzahl wird der Befehl ohne weitere Analyse vollständig verborgen (#199).
    static let maximumArgumentCount = 4_096

    /// Mehrere maskierte Argumente samt Hinweis, ob darin ein Geheimnis im Klartext stand.
    struct Arguments: Equatable {
        let values: [String]
        /// Mindestens ein maskierter Wert war ein Geheimnis im Klartext (kein Platzhalter, nicht leer, kein Pfad).
        let containsSecret: Bool
        var hasHiddenScript: Bool = false
    }

    /// Ein maskierter Text (URL oder einzelnes Argument) samt Hinweis, ob darin ein Geheimnis im Klartext stand.
    struct Text: Equatable {
        let value: String
        let containsSecret: Bool
    }

    private static let maximumNestingDepth = 8

    /// Webhook-/Bot-APIs, deren URL-Pfad das Token trägt: alles hinter dem Pfadpräfix wird maskiert.
    private static let tokenPaths: [(host: String, prefix: String)] = [
        ("hooks.slack.com", "/services/"),
        ("discord.com", "/api/webhooks/"),
        ("discordapp.com", "/api/webhooks/"),
        ("api.telegram.org", "/bot"),
        ("api.telegram.org", "/file/bot"),
    ]

    /// Präfixe bekannter Zugangs-Token; als eigenes Argument oder Wert ab `minimumTokenLength` Zeichen mit mindestens
    /// einer Ziffer dahinter ein Geheimnis. `alphanumericBody`: dahinter nur `A–Z a–z 0–9` (sonst auch `_ - .`).
    private static let tokenPrefixes: [(prefix: String, alphanumericBody: Bool)] = [
        ("github_pat_", false), ("sk-ant-", false), ("glpat-", false), ("xoxb-", false), ("xoxp-", false),
        ("xapp-", false), ("AKIA", false), ("AIza", false), ("npm_", false), ("sk-", false),
        ("ghp_", true), ("gho_", true), ("ghs_", true), ("ghu_", true), ("hf_", true),
    ]
    private static let minimumTokenLength = 16

    /// Auth-Schemata, die allein (ohne Zugangsdaten dahinter) keinen Wert darstellen.
    private static let authSchemes: Set<String> = ["bearer", "basic", "digest"]

    /// Werte, die wie Schalter oder Auth-Modi aussehen (`--auth none`, `--require-auth true`) oder die Standardeingabe
    /// meinen (`--password -`): werden maskiert, gelten aber nicht als Geheimnis. Kleinschreibung verglichen.
    private static let nonSecretKeywords: Set<String> =
        Set(["true", "false", "yes", "no", "none", "on", "off", "oauth", "oauth2", "-"]).union(authSchemes)
    private static let longestKeywordLength = nonSecretKeywords.map(\.utf8.count).max() ?? 0

    /// Maskiert eine Argumentliste. Der Wert hinter einem geheimnisartigen Flag (`--token abc`) wird ebenfalls
    /// maskiert – unabhängig von seinem ersten Zeichen.
    ///
    /// Argumente, die eine Shell als Skript ausführt (`ShellSyntax.scriptIndices`, `sh -c <Skript>`), werden nicht
    /// zerlegt: Sie stehen entweder unverändert da oder ganz maskiert (`ShellSyntax.hidesScript`, #137).
    ///
    /// - Parameters:
    ///   - program: tatsächlich gestartetes Programm, wenn es nicht `arguments[0]` ist (launchd `Program`).
    ///   - resolvingPath: Pfadauflösung; ohne Vorgabe Symlinks und System-Shell-Kopien (`CommandInterpreterPath`).
    ///     Für rein textuelle Auswertung ohne Dateizugriff `{ _ in nil }` übergeben.
    static func redact(
        arguments: [String], program: String? = nil, resolvingPath: ((String) -> String?)? = nil
    ) -> Arguments {
        guard arguments.count <= maximumArgumentCount else {
            return Arguments(values: Array(repeating: mask, count: arguments.count),
                             containsSecret: false, hasHiddenScript: true)
        }
        let scripts = ShellSyntax.scriptIndices(in: arguments, program: program,
                                               resolvingPath: resolvingPath ?? CommandInterpreterPath.makeResolver())
        let list = redactList(arguments, depth: 0)
        guard !scripts.isEmpty else { return list }
        // Mögliche Skripte: ganz oder gar nicht. Ändert schon die Argumentregel etwas (auch über ein Flag davor, etwa
        // `--token x`), wird das ganze Argument verborgen – nie nur ein Teil davon.
        var values = list.values
        var containsSecret = list.containsSecret
        for index in scripts {
            let verdict = ShellSyntax.hidesScript(arguments[index])
            let hides = verdict.hides || list.values[index] != arguments[index]
            values[index] = hides ? masked(arguments[index]) : arguments[index]
            containsSecret = containsSecret || verdict.indicatesSecret
        }
        return Arguments(values: values, containsSecret: containsSecret,
                         hasHiddenScript: scripts.contains { values[$0] == mask })
    }

    /// Gespeicherte Befehle rein textuell nachmaskieren: Decoder dürfen keine inzwischen unerreichbaren
    /// Interpreter-/Argumentpfade öffnen. Aktuelle Einträge tragen die beim Scan ermittelte Skripteinstufung.
    /// Altdaten ohne dieses Feld behandeln absolute mögliche Interpreter konservativ als Shell-Kandidaten;
    /// so bleiben auch alte neutral benannte Shell-Aufrufe ohne erneuten Dateizugriff ganz maskiert.
    static func redactStored(
        arguments: [String], program: String? = nil, hasScriptClassification: Bool
    ) -> Arguments {
        redact(arguments: arguments, program: program, resolvingPath: { path in
            !hasScriptClassification && path.hasPrefix("/") ? "/bin/sh" : nil
        })
    }

    /// Ob der Redactor an `text` etwas maskieren würde – als ein Argument oder als Folge seiner durch Leerraum getrennten
    /// Wörter (ohne Skript-Erkennung). Grundlage der Indikatorprüfung von Shell-Skripten (`ShellSyntax`, #137).
    static func changes(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return redactList([text], depth: 0).values != [text] || redactList(words, depth: 0).values != words
    }

    /// Ein Argument der Liste oder ein Wort eines Shell-Strings: `source` steht so im Text, `literal` bekommt das
    /// Programm – in Argumentlisten dasselbe, in Shell-Strings ohne Anführungszeichen und Escapes (`shellLiteral`).
    /// Flag- und Geheimniserkennung prüfen immer `literal`.
    private struct ShellWord {
        let source: String
        let literal: String

        /// Ein Element einer Argumentliste: Die Shell ist schon durch, der Text ist das, was das Programm bekommt.
        init(argument: String) {
            source = argument
            literal = argument
        }

        /// Ein Wort aus einem Shell-String.
        init(shellWord: Substring) {
            source = String(shellWord)
            literal = ArgumentRedactor.shellLiteral(of: shellWord)
        }
    }

    /// Wie `redact(arguments:)`; `depth` zählt verschachtelte Zuweisungen, Segmente und Shell-Wörter.
    private static func redactList(_ arguments: [String], depth: Int) -> Arguments {
        redactSequence(arguments.map(ShellWord.init(argument:)), depth: depth)
    }

    /// Gemeinsamer Kern für Argumentlisten und Shell-Strings. Der Wert hinter einem geheimnisartigen Flag wird maskiert –
    /// unabhängig von seinem ersten Zeichen. Die Wirkung jedes Worts als Flag wird fortgeschrieben, auch wenn es selbst
    /// als Wert maskiert wurde (`--auth --password x`, `--auth '--password' x`).
    private static func redactSequence(_ words: [ShellWord], depth: Int) -> Arguments {
        var values: [String] = []
        var containsSecret = false
        var masksNext = false
        for word in words {
            if masksNext {
                values.append(unquoted(word.literal).isEmpty ? word.source : mask)
                containsSecret = containsSecret || isPlaintextSecret(word.literal)
            } else {
                let result = redact(word: word, depth: depth)
                values.append(result.value)
                containsSecret = containsSecret || result.containsSecret
            }
            masksNext = isSecretFlag(word.literal)
        }
        return Arguments(values: values, containsSecret: containsSecret)
    }

    /// Ein Wort, ausgewertet als `literal`. Ist es ganz in Anführungszeichen gehüllt (oder ungequotet), wertet
    /// `redact(argument:)` genau das aus und behält die Hülle (`redactQuoted`). Sonst bleibt ein Wort ohne Maskierung
    /// so, wie es dastand; mit Maskierung erscheint es entquotet.
    private static func redact(word: ShellWord, depth: Int) -> Text {
        guard unquoted(word.source) != word.literal else { return redact(argument: word.source, depth: depth) }
        let result = redact(argument: word.literal, depth: depth)
        return result.value == word.literal ? Text(value: word.source, containsSecret: result.containsSecret) : result
    }

    /// Ein geheimnisartiges Flag ohne eigenen Wert (`--token`, nicht `--token=x`): Der nächste Wert gehört ihm.
    private static func isSecretFlag(_ argument: String) -> Bool {
        argument.hasPrefix("-") && !argument.contains("=") && SecretNames.looksSecret(argument)
    }

    /// Maskiert eine URL: Passwort bzw. Benutzername ohne Passwort im Userinfo, Token im Pfad bekannter Webhook-Hosts sowie die Werte aller Query- und
    /// Fragment-Parameter. Ohne Schema (`host:3000?token=x`) gelten nur die Parameter.
    static func redact(url: String) -> Text {
        guard let schemeEnd = url.range(of: "://") else { return redactParameters(in: url) }
        let afterScheme = url[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex { "/?#".contains($0) } ?? afterScheme.endIndex
        let authority = String(afterScheme[..<authorityEnd])
        let userinfo = redactUserinfo(in: authority)
        let path = redactTokenPath(in: String(afterScheme[authorityEnd...]), host: MCPTransport.host(ofAuthority: authority[...]) ?? "")
        let parameters = redactParameters(in: path.value)
        return Text(
            value: String(url[..<schemeEnd.upperBound]) + userinfo.value + parameters.value,
            containsSecret: userinfo.containsSecret || path.containsSecret || parameters.containsSecret
        )
    }

    // MARK: - Einzelnes Argument

    /// Ein einzelnes Argument (ohne Blick auf das vorige). Reihenfolge: Token → Zitat-Hülle → Zuweisung → Header →
    /// Bearer → Connection-String → Shell-Wörter → URL. `inConnectionString`: das Argument ist ein Segment eines Connection-Strings.
    private static func redact(argument: String, depth: Int = 0, inConnectionString: Bool = false) -> Text {
        guard depth <= maximumNestingDepth else { return Text(value: masked(argument), containsSecret: false) }
        if looksLikeToken(argument) { return Text(value: mask, containsSecret: true) }
        if let quoted = redactQuoted(argument, depth: depth) { return quoted }
        let segments = connectionSegments(of: argument)
        let connectionLike = inConnectionString || segments.count > 1
        if let assignment = splitAssignment(argument, nameMayContainSpaces: connectionLike) {
            let isSecretName = connectionLike
                ? SecretNames.isConnectionStringSecret(assignment.name)
                : SecretNames.looksSecret(assignment.name)
            if isSecretName { return redactSecretValue(of: assignment, depth: depth) }
            let value = redact(argument: assignment.value, depth: depth + 1)
            return Text(value: assignment.name + "=" + value.value, containsSecret: value.containsSecret)
        }
        if let header = redactHeader(argument) { return header }
        if let bearer = argument.range(of: "Bearer ", options: .caseInsensitive) {
            let token = String(argument[bearer.upperBound...])
            return Text(value: String(argument[..<bearer.upperBound]) + masked(token), containsSecret: isPlaintextSecret(token))
        }
        if segments.count > 1 { return redactSegments(segments, depth: depth + 1) }
        if argument.contains(where: \.isWhitespace) { return redactWords(of: argument, depth: depth + 1) }
        return redact(url: argument)
    }

    /// Wert hinter einem geheimnisartigen Namen (`NAME=wert`). Beginnt er mit einem Anführungszeichen, reicht er bis zum
    /// schließenden Zeichen samt Rest dieses Worts (ohne schließendes bis zum Ende); was dahinter folgt, wird wie ein
    /// eigenes Argument behandelt (`PASSWORD='a b' node s.js` → `PASSWORD=••• node s.js`). Sonst gilt der ganze Rest
    /// als Wert, falls das Geheimnis selbst Leerzeichen oder `;` enthält. Leerraum hinter dem `=` bleibt erhalten.
    private static func redactSecretValue(of assignment: (name: String, value: String), depth: Int) -> Text {
        let leading = String(assignment.value.prefix { $0 == " " || $0 == "\t" })
        let content = assignment.value.dropFirst(leading.count)
        let valueEnd = content.first.map(isQuote) == true ? shellWordEnd(in: content) : content.endIndex
        let secret = String(content[..<valueEnd])
        let remainder = valueEnd < content.endIndex ? redact(argument: String(content[valueEnd...]), depth: depth + 1) : nil
        return Text(
            value: assignment.name + "=" + leading + masked(secret) + (remainder?.value ?? ""),
            containsSecret: isPlaintextSecret(secret) || remainder?.containsSecret == true
        )
    }

    /// `Name: wert` mit geheimnisartigem Namen; `nil`, wenn das Argument kein solcher Header ist oder der Wert fehlt.
    private static func redactHeader(_ argument: String) -> Text? {
        guard !argument.contains("://"), let colon = argument.firstIndex(of: ":"), colon > argument.startIndex,
              argument[..<colon].allSatisfy(isHeaderNameCharacter), SecretNames.looksSecret(String(argument[..<colon])) else {
            return nil
        }
        let value = argument[argument.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return Text(value: String(argument[..<colon]) + ": " + mask, containsSecret: isPlaintextSecret(credentials(in: unquoted(value))))
    }

    /// Shell-Aufruf in einem Argument (`export T=x && node s.js --api-key y`): die Wörter werden wie eigene Argumente
    /// behandelt (auch der Wert hinter einem geheimnisartigen Flag), der Leerraum dazwischen bleibt unverändert.
    private static func redactWords(of text: String, depth: Int) -> Text {
        let pieces = shellPieces(of: text)
        guard pieces.count > 1 else { return redact(url: text) }
        let words = pieces.filter { !isWhitespaceRun($0) }.map(ShellWord.init(shellWord:))
        let redacted = redactSequence(words, depth: depth)
        var redactedWords = redacted.values.makeIterator()
        let value = pieces.map { isWhitespaceRun($0) ? String($0) : (redactedWords.next() ?? String($0)) }.joined()
        return Text(value: value, containsSecret: redacted.containsSecret)
    }

    /// Zerlegt Text in abwechselnde Stücke aus Leerraum und Wörtern (siehe `shellWordEnd`); zusammengesetzt ergeben sie
    /// den Text.
    private static func shellPieces(of text: String) -> [Substring] {
        var pieces: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start].isWhitespace
                ? text[start...].firstIndex { !$0.isWhitespace } ?? text.endIndex
                : shellWordEnd(in: text[start...])
            pieces.append(text[start..<end])
            start = end
        }
        return pieces
    }

    /// Ende des Worts, mit dem `text` beginnt: der nächste Leerraum außerhalb eines Zitats und nicht hinter `\` (siehe
    /// `firstUnquotedIndex`).
    private static func shellWordEnd(in text: Substring) -> String.Index {
        firstUnquotedIndex(in: text, where: \.isWhitespace)
    }

    /// Das erste Zeichen von `text`, das `isSeparator` erfüllt und weder in einem Zitat steht noch mit `\` geschützt ist;
    /// sonst `text.endIndex`. Ein Anführungszeichen am Wortanfang (Textanfang, hinter Leerraum oder `;`) oder direkt
    /// hinter `=` oder `:` öffnet ein Zitat; es endet beim nächsten gleichen, nicht mit `\` geschützten Zeichen (in `'…'`
    /// und `{…}` schützt `\` nichts), sonst am Ende des Texts. Mitten im Wort öffnet ein Anführungszeichen nur, wenn ein
    /// gleiches folgt – ein Apostroph im Fließtext (`don't`) verschluckte sonst den Rest. `bracesQuote`: `{` direkt
    /// hinter `=` öffnet ein Zitat bis `}` (ODBC, `PWD={a;b}`).
    private static func firstUnquotedIndex(
        in text: Substring, bracesQuote: Bool = false, where isSeparator: (Character) -> Bool
    ) -> String.Index {
        var closingQuote: Character?
        var previous: Character?
        var isEscaped = false
        for index in text.indices {
            let character = text[index]
            defer { previous = character }
            if isEscaped {
                isEscaped = false
            } else if let quote = closingQuote {
                if character == "\\", quote == "\"" {
                    isEscaped = true
                } else if character == quote {
                    closingQuote = nil
                }
            } else if character == "\\" {
                isEscaped = true
            } else if isSeparator(character) {
                return index
            } else if isQuote(character), opensQuote(at: index, in: text, after: previous) {
                closingQuote = character
            } else if bracesQuote, character == "{", previous == "=" {
                closingQuote = "}"
            }
        }
        return text.endIndex
    }

    /// Ob das Anführungszeichen bei `index` ein Zitat öffnet: am Wortanfang oder hinter `=`/`:` immer, sonst nur, wenn
    /// dahinter ein gleiches Zeichen folgt.
    private static func opensQuote(at index: String.Index, in text: Substring, after previous: Character?) -> Bool {
        guard let previous, !previous.isWhitespace, !"=:;".contains(previous) else { return true }
        return text[text.index(after: index)...].contains(text[index])
    }

    /// Das Wort, wie eine POSIX-Shell es dem Programm übergibt: Anführungszeichen entfernt, `\x` → `x` (in `"…"` nur
    /// vor `"`, `\`, `$` und `` ` ``, in `'…'` nie); `\` vor einem Zeilenumbruch fällt samt Umbruch weg. Ein offenes
    /// Zitat reicht bis zum Wortende.
    private static func shellLiteral(of word: Substring) -> String {
        var literal = ""
        var openQuote: Character?
        var isEscaped = false
        for character in word {
            if isEscaped {
                isEscaped = false
                if character == "\n" { continue }
                if openQuote == "\"", !"\"\\$`".contains(character) { literal.append("\\") }
                literal.append(character)
            } else if character == "\\", openQuote != "'" {
                isEscaped = true
            } else if let quote = openQuote {
                if character == quote { openQuote = nil } else { literal.append(character) }
            } else if isQuote(character) {
                openQuote = character
            } else {
                literal.append(character)
            }
        }
        if isEscaped { literal.append("\\") }
        return literal
    }

    /// Ein Wort, das mit einem Anführungszeichen beginnt und als Ganzes ein Shell-Wort ist: ohne das öffnende (und ein
    /// abschließendes) Zeichen auswerten und wieder umhüllen. `nil`, wenn das Argument nicht so beginnt oder aus
    /// mehreren Wörtern besteht (`'--password' x` – die wertet `redactWords` einzeln aus).
    private static func redactQuoted(_ argument: String, depth: Int) -> Text? {
        guard let quote = argument.first, isQuote(quote), shellWordEnd(in: argument[...]) == argument.endIndex else {
            return nil
        }
        let body = argument.dropFirst()
        let isClosed = !body.isEmpty && body.last == quote
        let inner = redact(argument: String(isClosed ? body.dropLast() : body), depth: depth + 1)
        return Text(value: String(quote) + inner.value + (isClosed ? String(quote) : ""), containsSecret: inner.containsSecret)
    }

    private static func isQuote(_ character: Character) -> Bool {
        character == "'" || character == "\""
    }

    private static func isWhitespaceRun(_ run: Substring) -> Bool {
        run.first?.isWhitespace ?? false
    }

    /// Connection-String (`Server=x;User Id=sa;Password=y`): jedes Segment wie ein eigenes Argument, dessen Name
    /// Leerzeichen enthalten darf. Führende Leerzeichen vor einem Segment bleiben erhalten.
    private static func redactSegments(_ segments: [Substring], depth: Int) -> Text {
        var containsSecret = false
        let redactedSegments = segments.map { segment -> String in
            let content = segment.drop { $0 == " " }
            let result = redact(argument: String(content), depth: depth, inConnectionString: true)
            containsSecret = containsSecret || result.containsSecret
            return String(segment[..<content.startIndex]) + result.value
        }
        return Text(value: redactedSegments.joined(separator: ";"), containsSecret: containsSecret)
    }

    /// Zerlegt `text` an jedem `;`, das ein Segment trennt: außerhalb von Zitaten (`firstUnquotedIndex`, mit ODBC-`{…}`)
    /// und nicht im Userinfo einer URL. Mit `;` verbunden ergeben die Stücke den Text; ein einziges Stück heißt: kein
    /// Connection-String und kein Skript mit `;`.
    private static func connectionSegments(of text: String) -> [Substring] {
        var segments: [Substring] = []
        var segmentStart = text.startIndex
        var searchStart = text.startIndex
        while true {
            let separator = firstUnquotedIndex(in: text[searchStart...], bracesQuote: true) { $0 == ";" }
            guard separator < text.endIndex else { break }
            let next = text.index(after: separator)
            if let userinfoEnd = urlUserinfoEnd(before: text[segmentStart..<separator], after: text[next...]) {
                searchStart = userinfoEnd
                continue
            }
            segments.append(text[segmentStart..<separator])
            segmentStart = next
            searchStart = next
        }
        segments.append(text[segmentStart...])
        return segments
    }

    /// Steht ein `;` zwischen `before` und `after` im Userinfo einer URL (`postgres://u:pw;x@h/db`), der Index hinter dem
    /// letzten `@` der Authority – bis dorthin trennt kein `;` (wie `redactUserinfo` das Userinfo abgrenzt); sonst `nil`.
    private static func urlUserinfoEnd(before: Substring, after: Substring) -> String.Index? {
        guard let scheme = before.range(of: "://", options: .backwards),
              !before[scheme.upperBound...].contains(where: isURLAuthorityEnd) else { return nil }
        let authority = after.prefix { !isURLAuthorityEnd($0) }
        return authority.lastIndex(of: "@").map(authority.index(after:))
    }

    private static func isURLAuthorityEnd(_ character: Character) -> Bool {
        "/?#".contains(character) || character.isWhitespace
    }

    /// `--name=wert`, `-n=wert` oder `NAME=wert` (Name aus Buchstaben, Ziffern, `_`, `-`; in Connection-Strings auch
    /// Leerzeichen im Namen). Leerraum um den Namen und hinter dem `=` ist erlaubt und bleibt im Ergebnis erhalten
    /// (`Password = y`); sonst `nil`.
    private static func splitAssignment(
        _ argument: String, nameMayContainSpaces: Bool = false
    ) -> (name: String, value: String)? {
        guard let equals = argument.firstIndex(of: "=") else { return nil }
        let name = String(argument[..<equals])
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let bare = trimmed.drop { $0 == "-" }
        guard let first = bare.first, first.isLetter || first == "_",
              bare.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || (nameMayContainSpaces && $0 == " ") })
        else { return nil }
        return (name, String(argument[argument.index(after: equals)...]))
    }

    private static func isHeaderNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    /// `Bearer x` → `x`; ein Schema allein (`Bearer`) → leer. Für die Platzhalter-/Leerprüfung eines Header-Werts.
    private static func credentials(in value: String) -> String {
        let words = value.split(separator: " ", maxSplits: 1)
        if words.count == 2 { return words[1].trimmingCharacters(in: .whitespaces) }
        return authSchemes.contains(value.lowercased()) ? "" : value
    }

    // MARK: - URL

    /// Maskiert das Passwort im Userinfo (`user:pass@host` → `user:•••@host`) und einen Benutzernamen ohne Passwort
    /// ganz (`ghp_…@host` → `•••@host`) – die Anzeige braucht ihn nicht, und oft ist er ein Token. Ein Benutzername vor
    /// einem Passwort wird nur maskiert, wenn er wie ein Token aussieht (`ghp_…:x-oauth-basic@host`). Als Geheimnis
    /// gemeldet wird ein Passwort im Klartext oder ein Benutzername, der wie ein Token oder Geheimnis-Name aussieht.
    private static func redactUserinfo(in authority: String) -> Text {
        guard let at = authority.lastIndex(of: "@") else { return Text(value: authority, containsSecret: false) }
        let host = String(authority[at...])
        guard let colon = authority[..<at].firstIndex(of: ":") else {
            let user = String(authority[..<at])
            return Text(value: masked(user) + host, containsSecret: isSecretUser(user))
        }
        let user = String(authority[..<colon])
        let password = String(authority[authority.index(after: colon)..<at])
        let userIsToken = looksLikeToken(user)
        return Text(
            value: (userIsToken ? mask : user) + ":" + masked(password) + host,
            containsSecret: userIsToken || isPlaintextSecret(password)
        )
    }

    /// Benutzername im URL-Userinfo, der ein Geheimnis trägt: ein Token oder ein geheimnisartiger Name (`apikey`).
    private static func isSecretUser(_ user: String) -> Bool {
        looksLikeToken(user) || (SecretNames.looksSecret(user) && isPlaintextSecret(user))
    }

    /// Maskiert bei Webhook-/Bot-Hosts (`tokenPaths`) den Pfad ab dem Token. `rest` beginnt mit `/`, `?`, `#` oder ist leer.
    private static func redactTokenPath(in rest: String, host: String) -> Text {
        let pathEnd = rest.firstIndex { "?#".contains($0) } ?? rest.endIndex
        let path = rest[..<pathEnd]
        for entry in tokenPaths where host == entry.host || host.hasSuffix("." + entry.host) {
            guard let prefix = path.range(of: entry.prefix, options: [.anchored, .caseInsensitive]),
                  prefix.upperBound < pathEnd else { continue }
            return Text(value: String(rest[..<prefix.upperBound]) + mask + String(rest[pathEnd...]), containsSecret: true)
        }
        return Text(value: rest, containsSecret: false)
    }

    /// Maskiert die Werte aller `name=wert`-Paare in Query (hinter dem ersten `?`) und Fragment (hinter dem ersten `#`;
    /// steht darin ein `?`, zählen nur die Paare dahinter). Text ohne solche Paare bleibt unverändert.
    private static func redactParameters(in text: String) -> Text {
        let fragmentStart = text.firstIndex(of: "#")
        let queryStart = text[..<(fragmentStart ?? text.endIndex)].firstIndex(of: "?")
        guard fragmentStart != nil || queryStart != nil else { return Text(value: text, containsSecret: false) }
        var output = String(text[..<(fragmentStart ?? text.endIndex)])
        var containsSecret = false
        if let queryStart {
            let query = maskParameters(text[text.index(after: queryStart)..<(fragmentStart ?? text.endIndex)])
            output = String(text[...queryStart]) + query.value
            containsSecret = query.containsSecret
        }
        if let fragmentStart {
            let fragment = text[text.index(after: fragmentStart)...]
            let parametersStart = fragment.firstIndex(of: "?").map { fragment.index(after: $0) } ?? fragment.startIndex
            let parameters = maskParameters(fragment[parametersStart...])
            output += "#" + String(fragment[..<parametersStart]) + parameters.value
            containsSecret = containsSecret || parameters.containsSecret
        }
        return Text(value: output, containsSecret: containsSecret)
    }

    /// `a=1&b=2` → `a=•••&b=•••`; Paare ohne Wert bleiben unverändert.
    private static func maskParameters(_ parameters: Substring) -> Text {
        var containsSecret = false
        let maskedParameters = parameters.split(separator: "&", omittingEmptySubsequences: false).map { parameter -> String in
            guard let equals = parameter.firstIndex(of: "="), parameter.index(after: equals) < parameter.endIndex else {
                return String(parameter)
            }
            containsSecret = containsSecret || holdsSecret(parameter)
            return String(parameter[...equals]) + mask
        }
        return Text(value: maskedParameters.joined(separator: "&"), containsSecret: containsSecret)
    }

    /// Ein Paar enthält ein Geheimnis, wenn sein Name geheimnisartig und der Wert ein Klartext-Geheimnis ist oder der
    /// Wert wie ein bekanntes Token aussieht. Steht im Paar selbst ein `?` (verschachtelte URL,
    /// `redirect=/x?token=abc`), wird jedes Teilstück mit dem Namen direkt vor seinem `=` geprüft.
    private static func holdsSecret(_ parameter: Substring) -> Bool {
        parameter.split(separator: "?").contains { (chunk: Substring) -> Bool in
            guard let equals = chunk.firstIndex(of: "=") else { return false }
            let name = String(chunk.prefix(upTo: equals))
            let value = String(chunk.suffix(from: chunk.index(after: equals)))
            return looksLikeToken(value) || (SecretNames.looksSecret(name) && isPlaintextSecret(value))
        }
    }

    // MARK: - Werte

    /// Ersetzt einen Wert durch die Maske; ein leerer Wert bleibt leer (nichts zu verbergen).
    private static func masked(_ value: String) -> String {
        unquoted(value).isEmpty ? value : mask
    }

    /// Entfernt ein öffnendes Anführungszeichen und, falls vorhanden, das passende schließende (`'a b'` → `a b`).
    private static func unquoted(_ value: String) -> String {
        guard let quote = value.first, isQuote(quote) else { return value }
        let body = value.dropFirst()
        return String(body.last == quote ? body.dropLast() : body)
    }

    /// Wert, der im Klartext ein Geheimnis sein kann: nicht leer, kein Platzhalter, kein Pfad, keine reine Zahl und
    /// kein Schlüsselwort wie `true` oder `none`.
    private static func isPlaintextSecret(_ quotedValue: String) -> Bool {
        let value = unquoted(quotedValue)
        return !value.isEmpty && !isPlaceholder(value) && !looksLikePathOrNumber(value) && !isKeyword(value)
    }

    private static func isKeyword(_ value: String) -> Bool {
        value.utf8.count <= longestKeywordLength && nonSecretKeywords.contains(value.lowercased())
    }

    /// Platzhalter statt Geheimnis: `${…}`, `$VAR`, `{…}`, `<…>`.
    private static func isPlaceholder(_ value: String) -> Bool {
        value.hasPrefix("$") || value.hasPrefix("{") || value.hasPrefix("<")
    }

    /// Pfade (`/…`, `~/…`, `./…`, `../…`) und reine Zahlen: werden maskiert, gelten aber nicht als Geheimnis.
    private static func looksLikePathOrNumber(_ value: String) -> Bool {
        ["/", "~/", "./", "../"].contains { value.hasPrefix($0) } || value.allSatisfy(\.isNumber)
    }

    /// Das ganze Argument ist ein bekanntes Token: Präfix aus `tokenPrefixes`, mindestens `minimumTokenLength` Zeichen
    /// aus `A–Z a–z 0–9 _ - .` (bei `alphanumericBody` ohne `_ - .`), mindestens eine Ziffer hinter dem Präfix und
    /// optional `=`-Auffüllung am Ende (Base64).
    static func looksLikeToken(_ value: String) -> Bool {
        guard value.utf8.count >= minimumTokenLength else { return false }
        let candidates = tokenPrefixes.filter { value.hasPrefix($0.prefix) }
        guard !candidates.isEmpty else { return false }
        let core = value.prefix { $0 != "=" }
        guard core.utf8.count >= minimumTokenLength, value[core.endIndex..<value.endIndex].allSatisfy({ $0 == "=" }) else {
            return false
        }
        return candidates.contains { candidate in
            let body = core.dropFirst(candidate.prefix.count)
            return body.contains { $0.isASCII && $0.isNumber }
                && body.allSatisfy { isTokenCharacter($0, alphanumericOnly: candidate.alphanumericBody) }
        }
    }

    private static func isTokenCharacter(_ character: Character, alphanumericOnly: Bool) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || (!alphanumericOnly && (character == "_" || character == "-" || character == "."))
    }
}
