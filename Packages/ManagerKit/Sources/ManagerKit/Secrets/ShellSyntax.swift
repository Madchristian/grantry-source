/// Skripte in Argumentlisten (#137, #173): Shells sowie Inline-Code in Python, Node, Perl, Ruby und osascript; ob er
/// verborgen werden muss.
///
/// Bewusst kein Shell-Parser: Ein Skript wird entweder vollständig angezeigt oder vollständig maskiert. Verborgen wird
/// es, sobald der rohe Text – auch ohne Anführungszeichen und `\` gelesen, ohne Rücksicht auf Groß-/Kleinschreibung –
/// einen Geheimnis-Indikator (`secretIndicator(in:)`) oder ein Konstrukt enthält, dessen Wirkung sich ohne Ausführung
/// nicht sicher ablesen lässt (`unanalyzableConstruct(in:)`). Redirections, Verschachtelung oder künftige Lücken eines
/// Teil-Parsers können so nichts mehr durchreichen.
enum ShellSyntax {
    /// Shell-Interpreter (Basename); alles hinter ihnen kann Skript sein.
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "csh", "tcsh", "ash", "yash"]

    /// Namensbestandteile, die im Skripttext (kleingeschrieben) auf Zugangsdaten deuten – großzügiger als
    /// `SecretNames`, ohne Ausnahmen: lieber ein lesbares Skript zu viel verborgen.
    private static let secretFragments = [
        "pass", "pwd", "secret", "token", "key", "auth", "cred", "api", "cookie", "bearer", "session", "private",
    ]
    /// Konstrukte, deren Wirkung sich ohne Ausführung nicht ablesen lässt: Befehlsersetzung, ANSI-C-/Locale-Quoting,
    /// Here-Documents, Zeilenfortsetzung mit `\` (`--to\⏎ken` ist `--token`).
    private static let unanalyzableFragments = ["$(", "`", "$'", "$\"", "<<", "\\\n", "\\\r", "\\\r\n"]

    // MARK: - Skript-Argumente

    /// Indizes der Argumente, die nach Skriptregeln geprüft werden (jedes einzeln ganz oder gar nicht, `hidesScript`):
    /// alle Argumente hinter der ersten Shell bzw. einem unterstützten Inline-Code-Aufruf bis zum Ende. Der Interpreter ist das tatsächliche Programm
    /// (`program`, sonst `arguments[0]`; `arguments[0]` ist neben `program` nur der Prozessname) oder ein späteres
    /// Argument, das eine Shell nennt (`env bash …`, `sudo -u x sh …`).
    ///
    /// Bewusst ganz ohne Optionsauswertung (#137, Codex Runden 4 und 5): Ob `-c`, ein Cluster wie `-oc` oder `-c5`,
    /// `+o`, `--` oder ein Skriptpfad (`bash script.sh --token x`) folgt – jedes Argument des Aufrufs gilt als mögliches
    /// Skript.
    ///
    /// Ein späteres Argument mit Leerraum, dessen Wörter (entquotet) eine Shell nennen (`env -S "sh -c '…'"`), macht
    /// sich selbst und alle folgenden zu Skriptkandidaten. Dasselbe gilt für angeklebtes `-Ssh …` und
    /// die unterstützten Inline-Aufrufe (Python, Node, Perl, Ruby, osascript).
    ///
    /// - Parameter resolvingPath: löst einen Pfad samt Symlinks auf, wenn die Quelle das kann (`/usr/local/bin/mysh` →
    ///   `/bin/zsh`); das Ergebnis zählt zusätzlich zum Namen selbst, nie statt seiner. `nil` heißt: nicht auflösbar.
    static func scriptIndices(
        in arguments: [String], program: String? = nil, resolvingPath: ((String) -> String?)? = nil
    ) -> Set<Int> {
        guard !arguments.isEmpty else { return [] }
        let names = { (path: String) in [path] + [resolvingPath?(path)].compactMap(\.self) }
        func startsScript(_ executable: String, following: ArraySlice<String>) -> Bool {
            names(executable).contains { isShell($0) || hasInlineCode(program: $0, arguments: following) }
        }
        if startsScript(program ?? arguments[0], following: arguments.dropFirst()) {
            return Set(1..<arguments.endIndex)
        }
        for index in arguments.indices.dropFirst() {
            if startsScript(arguments[index], following: arguments.dropFirst(index + 1)) {
                return Set((index + 1)..<arguments.endIndex)
            }
            // env erlaubt sowohl `-S sh …` als auch `-Ssh …` / `--split-string=sh …`.
            var split = arguments[index]
            if split.hasPrefix("-S") { split = String(split.dropFirst(2)) }
            if split.hasPrefix("--split-string=") { split = String(split.dropFirst("--split-string=".count)) }
            let words = split.filter { !"'\"\\".contains($0) }.split(whereSeparator: \.isWhitespace).map(String.init)
            if !words.isEmpty, (words.count > 1 || split != arguments[index]), words.indices.contains(where: {
                startsScript(words[$0], following: (Array(words.dropFirst($0 + 1)) + arguments.dropFirst(index + 1))[...])
            }) { return Set(index..<arguments.endIndex) }
        }
        return []
    }

    /// Nur Inline-Aufrufe der unterstützten Sprachen; `python server.py` / `node server.js` bleiben normale argv.
    /// Hinter einer Skriptdatei oder `--` werden Optionen nicht mehr als Interpreter-Optionen gelesen.
    private static func hasInlineCode(program: String, arguments: ArraySlice<String>) -> Bool {
        let name = (program.split(separator: "/").last.map(String.init) ?? program).lowercased()
        let python = name.wholeMatch(of: /python[0-9.]*/) != nil
        let perl = name.wholeMatch(of: /perl[0-9.]*/) != nil
        let ruby = name.wholeMatch(of: /ruby[0-9.]*/) != nil
        let node = name == "node" || name == "nodejs"
        guard python || perl || ruby || node || name == "osascript" else { return false }
        let takesValue: Set<String> = python ? ["-W", "-X"]
            : node ? ["-r", "--require", "--import", "--loader", "--input-type"]
            : name == "osascript" ? ["-l", "-s"] : ["-I", "-r", "-M", "-m", "-F"]
        var skipValue = false
        for argument in arguments {
            if skipValue { skipValue = false; continue }
            guard argument.hasPrefix("-"), argument != "--", argument != "-" else { return false }
            if takesValue.contains(argument) { skipValue = true; continue }
            if node, ["--eval", "--print"].contains(where: { argument == $0 || argument.hasPrefix($0 + "=") }) { return true }
            guard !argument.hasPrefix("--") else { continue }
            let options = argument.dropFirst()
            if python && options.contains("c") { return true }
            if (perl || ruby) && (options.contains("e") || (perl && options.contains("E"))) { return true }
            if node && (options.hasPrefix("e") || options.hasPrefix("p")) { return true }
            if name == "osascript", argument.hasPrefix("-e") { return true }
        }
        return false
    }

    /// Ob ein Shell-Skript verborgen werden muss; `indicatesSecret`, wenn ein Geheimnis-Indikator der Grund ist.
    static func hidesScript(_ script: String) -> (hides: Bool, indicatesSecret: Bool) {
        // Erst die Konstrukte: Eine verschachtelte Shell landet so nie in der Redactor-Prüfung (`secretIndicator`).
        guard !unanalyzableConstruct(in: script) else { return (true, secretIndicator(in: script, usingRedactor: false)) }
        let indicatesSecret = secretIndicator(in: script)
        return (indicatesSecret, indicatesSecret)
    }

    /// Ob `arguments` ein Skript enthält, das als Ganzes maskiert ist (`ArgumentRedactor.mask`) – für Hinweise in der
    /// Anzeige.
    static func hasHiddenScript(in arguments: [String], program: String? = nil) -> Bool {
        scriptIndices(in: arguments, program: program).contains { arguments[$0] == ArgumentRedactor.mask }
    }

    /// Basename eines Shell-Programms, auch als Login-Shell-Name (`-bash`). Ohne Rücksicht auf Groß-/Kleinschreibung:
    /// Auf dem üblichen APFS startet `/bin/SH` dieselbe Shell wie `/bin/sh`.
    static func isShell(_ argument: String) -> Bool {
        let name = (argument.split(separator: "/").last.map(String.init) ?? argument).lowercased()
        return shells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }

    // MARK: - Indikatoren

    /// Lesarten des Skripts: roh, ohne Anführungszeichen und `\` (`TO""KEN`, `pass\word`), ohne Zeilenfortsetzungen
    /// (`\⏎`) und mit zu Leerzeichen zusammengefügten Zeilen.
    private static func readings(of script: String) -> [String] {
        let continued = script.replacingOccurrences(of: "\\\r\n", with: "").replacingOccurrences(of: "\\\n", with: "")
        let candidates = [
            script, script.filter { !"'\"\\".contains($0) }, continued, continued.filter { !"'\"\\".contains($0) },
            continued.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " "),
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// Geheimnis-Indikator in einer Lesart (`readings`): Der gesamte `ArgumentRedactor` (Namen, Token, Webhook-Pfade,
    /// URL-Userinfo, Connection-Strings …) ändert die Lesart als ein Argument oder als Folge ihrer Wörter – damit bleibt
    /// die Prüfung nie hinter dem Redactor zurück. Zusätzlich und großzügiger: ein Namensbestandteil
    /// (`secretFragments`), ein geheimnisartiger Name laut `SecretNames` (`GH_PAT`), ein bekanntes Token
    /// (`ArgumentRedactor.looksLikeToken`) oder Zugangsdaten in einer URL (`://…@`). `usingRedactor: false` nur für
    /// Skripte, die ohnehin verborgen werden (dort zählt der Befund nur für die Geheimnis-Meldung).
    static func secretIndicator(in script: String, usingRedactor: Bool = true) -> Bool {
        readings(of: script).contains { text in
            let lowered = text.lowercased()
            // `•••` steht nur in einem schon maskierten Skript (älterer Snapshot, teilmaskiert) – ganz verbergen.
            return text.contains(ArgumentRedactor.mask)
                || secretFragments.contains { lowered.contains($0) } || hasURLUserinfo(lowered)
                || words(of: text).contains { SecretNames.looksSecret($0) || ArgumentRedactor.looksLikeToken($0) }
                || (usingRedactor && ArgumentRedactor.changes(text))
        }
    }

    /// Nicht sicher lesbares Konstrukt: `unanalyzableFragments`, `${…}` mit mehr als einem Namen (`${T:-x}`), eine
    /// verschachtelte Shell (`bash -c …` im Skript), `eval`/`source`, ein offenes Zitat oder ein abschließendes `\`.
    static func unanalyzableConstruct(in script: String) -> Bool {
        unanalyzableFragments.contains { script.contains($0) } || hasComplexParameterExpansion(script)
            || words(of: script).contains { isShell($0) || $0 == "eval" || $0 == "source" }
            || !hasBalancedQuotes(script)
    }

    /// Wörter aus Buchstaben, Ziffern und `_ - . /` (ohne Anführungszeichen und `\` gelesen) – für Namen und Token.
    private static func words(of script: String) -> [String] {
        script.filter { !"'\"\\".contains($0) }
            .split { !($0.isLetter || $0.isNumber || "_-./".contains($0)) }
            .map(String.init)
    }

    /// `://` mit einem `@` dahinter vor dem nächsten Leerraum oder `/`.
    private static func hasURLUserinfo(_ text: String) -> Bool {
        var rest = text[...]
        while let scheme = rest.range(of: "://") {
            let authority = rest[scheme.upperBound...].prefix { !$0.isWhitespace && $0 != "/" }
            if authority.contains("@") { return true }
            rest = rest[scheme.upperBound...]
        }
        return false
    }

    /// `${…}` mit mehr als einem schlichten Namen (`${HOME}` ist lesbar, `${T:-x}`, `${!x}`, `${#x}` nicht).
    private static func hasComplexParameterExpansion(_ script: String) -> Bool {
        var rest = script[...]
        while let open = rest.range(of: "${") {
            let body = rest[open.upperBound...]
            guard let close = body.firstIndex(of: "}") else { return true }
            let name = body[..<close]
            guard let first = name.first, first.isASCII, first.isLetter || first == "_",
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return true }
            rest = body[body.index(after: close)...]
        }
        return false
    }

    /// Jedes Zitat geschlossen und kein `\` am Ende (Shell-Regeln: in `'…'` schützt `\` nichts).
    private static func hasBalancedQuotes(_ script: String) -> Bool {
        var openQuote: Character?
        var isEscaped = false
        for character in script {
            if isEscaped {
                isEscaped = false
            } else if openQuote == "'" {
                if character == "'" { openQuote = nil }
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                openQuote = openQuote == nil ? "\"" : nil
            } else if character == "'", openQuote == nil {
                openQuote = "'"
            }
        }
        return openQuote == nil && !isEscaped
    }
}
