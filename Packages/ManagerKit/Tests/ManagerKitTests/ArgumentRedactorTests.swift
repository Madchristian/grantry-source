import Testing
@testable import ManagerKit

@Suite struct ArgumentRedactorTests {
    @Test(arguments: ["OPENAI_API_KEY", "GITHUB_TOKEN", "CLIENT_SECRET", "DB_PASSWORD", "GITLAB_PAT", "Authorization",
                      "x-api-key", "apiKey", "--token", "--password", "accessToken", "PGPASS", "--basic-auth", "Proxy-Authorization",
                      "PASSPHRASE", "SSH_KEY_PASSPHRASE", "DB_PWD", "GOOGLE_APPLICATION_CREDENTIALS", "WEBHOOK_SECRET_URL",
                      "User Password", "Access Key", "SharedAccessKey", "privateKey", "--tokens", "API_TOKENS", "TOKENS"])
    func secretNames(_ name: String) {
        #expect(SecretNames.looksSecret(name))
    }

    @Test(arguments: ["PATH", "HOME", "NODE_ENV", "KEYBOARD", "--verbose", "LOG_LEVEL", "BYPASS", "PWD", "--no-auth", "NO_AUTH",
                      "MAX_TOKENS", "--max-tokens", "maxTokens", "--tokenizer", "HF_TOKENIZER", "--token-file", "TOKEN_FILE",
                      "API_KEY_PATH", "AUTH_TYPE", "AUTH_MODE", "TOKEN_LIMIT", "SSH_KEY_DIR", "User Id", "--enable-auth", "--disable-auth",
                      "--skip-auth", "--require-auth", "WITHOUT_AUTH", "USE_AUTH", "NUM_TOKENS", "MIN_TOKENS", "MODEL_MAX_TOKENS"])
    func ordinaryNames(_ name: String) {
        #expect(!SecretNames.looksSecret(name))
    }

    @Test func masksUserinfoPasswordAndQueryValues() {
        let result = ArgumentRedactor.redact(url: "postgresql://admin:hunter2@db.local:5432/app?sslmode=require&token=abc#x")
        #expect(result.value == "postgresql://admin:•••@db.local:5432/app?sslmode=•••&token=•••#x")
        #expect(result.containsSecret)
    }

    @Test func nonSecretQueryIsMaskedButNotFlagged() {
        let result = ArgumentRedactor.redact(url: "https://example.com/mcp?region=eu")
        #expect(result.value == "https://example.com/mcp?region=•••")
        #expect(!result.containsSecret)
    }

    @Test func urlWithoutSecretsIsUnchanged() {
        let result = ArgumentRedactor.redact(url: "https://example.com/sse")
        #expect(result.value == "https://example.com/sse")
        #expect(!result.containsSecret)
    }

    /// Ein Benutzername ohne Passwort wird immer maskiert (die Anzeige braucht ihn nicht), gemeldet aber nur als Token
    /// oder geheimnisartiger Name.
    @Test func masksUserinfoWithoutPassword() {
        let plain = ArgumentRedactor.redact(url: "https://user@example.com/sse")
        #expect(plain.value == "https://•••@example.com/sse")
        #expect(!plain.containsSecret)
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        let github = ArgumentRedactor.redact(url: "https://\(token)@mcp.example.com/sse")
        #expect(github.value == "https://•••@mcp.example.com/sse")
        #expect(github.containsSecret)
        let named = ArgumentRedactor.redact(url: "https://apikey@mcp.example.com/sse")
        #expect(named.value == "https://•••@mcp.example.com/sse")
        #expect(named.containsSecret)
        let tokenWithPassword = ArgumentRedactor.redact(url: "https://\(token):x-oauth-basic@github.com/x")
        #expect(tokenWithPassword.value == "https://•••:•••@github.com/x")
        #expect(tokenWithPassword.containsSecret)
        let empty = ArgumentRedactor.redact(url: "https://@example.com/sse")
        #expect(empty.value == "https://@example.com/sse")
        #expect(!empty.containsSecret)
    }

    /// Nur URL-Userinfo hinter `://`: Eine E-Mail-Adresse als Argument bleibt unverändert.
    @Test func emailAddressWithoutSchemeIsUnchanged() {
        let result = ArgumentRedactor.redact(arguments: ["--contact", "user@example.com"])
        #expect(result.values == ["--contact", "user@example.com"])
        #expect(!result.containsSecret)
    }

    @Test func masksSecretFlagsEnvAssignmentsAndHeaders() {
        let result = ArgumentRedactor.redact(arguments: [
            "-y", "pkg", "--api-key=sk-123", "--token", "abc", "--verbose", "GITHUB_TOKEN=ghp_x", "MODE=fast",
            "--header", "Authorization: Bearer xyz", "postgresql://u:p@h/db",
        ])
        #expect(result.values == [
            "-y", "pkg", "--api-key=•••", "--token", "•••", "--verbose", "GITHUB_TOKEN=•••", "MODE=fast",
            "--header", "Authorization: •••", "postgresql://u:•••@h/db",
        ])
        #expect(result.containsSecret)
    }

    @Test func placeholdersAreMaskedWithoutFlag() {
        let result = ArgumentRedactor.redact(arguments: ["--token", "${input:token}", "API_KEY=$API_KEY"])
        #expect(result.values == ["--token", "•••", "API_KEY=•••"])
        #expect(!result.containsSecret)
    }

    /// Regression (Codex-Review 2026.10.6, #155): Der Wert hinter einem geheimnisartigen Flag wird auch maskiert, wenn er
    /// mit `-` beginnt – Passwörter dürfen so anfangen. Ein nachfolgendes Flag wird dafür in Kauf genommen.
    @Test func secretFlagMasksAValueStartingWithADash() {
        let result = ArgumentRedactor.redact(arguments: ["--password", "-abc123", "--token", "--verbose", "--port", "8080"])
        #expect(result.values == ["--password", "•••", "--token", "•••", "--port", "8080"])
        #expect(result.containsSecret)
        let shell = ArgumentRedactor.redact(arguments: ["sh", "-c", "run --password -abc123 --port 8080"])
        // Skript hinter `sh -c`: ganz maskiert (#137).
        #expect(shell.values == ["sh", "-c", "•••"])
        #expect(shell.containsSecret)
    }

    /// Regression (Codex-Review zu #155, Folge): Ein geheimnisartiges Flag, das selbst als Wert eines vorigen maskiert
    /// wurde (`--auth --password x`), maskiert seinerseits den nächsten Wert – auch in Shell-Strings. Sonst stünde das
    /// Passwort hinter dem zweiten Flag im Klartext im Snapshot.
    @Test func consecutiveSecretFlagsMaskTheValueAfterTheLast() {
        let result = ArgumentRedactor.redact(arguments: ["--auth", "--password", "aZ7!geheim", "--port", "8080"])
        #expect(result.values == ["--auth", "•••", "•••", "--port", "8080"])
        #expect(result.containsSecret)
        let shell = ArgumentRedactor.redact(arguments: ["sh", "-c", "run --auth --password aZ7!geheim --port 8080"])
        #expect(shell.values == ["sh", "-c", "•••"])
        #expect(shell.containsSecret)
    }

    /// Regression (Codex-Review zu #155, Runde 3): In Shell-Strings zählt das Wort, wie das Programm es bekommt –
    /// Anführungszeichen (einfach, doppelt, mitten im Wort) und Backslash-Escapes entfernt. Ein so geschriebenes
    /// geheimnisartiges Flag maskiert seinen Wert, auch wenn es selbst als Wert eines vorigen Flags maskiert wurde.
    @Test(arguments: [
        "run --auth '--password' aZ7!geheim",
        "run --auth \"--password\" aZ7!geheim",
        "run '--password' aZ7!geheim",
        "run \"--password\" aZ7!geheim",
        "run --pass'word' aZ7!geheim",
        "run \"--pass\"'word' aZ7!geheim",
        "run \\--password aZ7!geheim",
        "run --auth \\-\\-password aZ7!geheim",
        "run '--password=aZ7!geheim'",
        "run \"--password=aZ7!geheim\" --port 1",
        "run --'password'=aZ7!geheim",
        "run \"--password\"=aZ7!geheim",
        "run --password=\"aZ7!geheim\"",
        "run --password aZ7\\ geheim",
        "run --password \"aZ7 \\\"x\\\" geheim\"",
        "run --api-key=aZ7\"ge heim\"",
        "sh -c \"run --auth '--password' aZ7!geheim\"",
    ])
    func quotedOrEscapedSecretFlagsMaskTheirValueInShellStrings(_ command: String) {
        let result = ArgumentRedactor.redact(arguments: [command])
        #expect(!result.values[0].contains("geheim"))
        #expect(!result.values[0].contains("heim"))
        #expect(result.containsSecret)
    }

    @Test func quotedSecondFlagMasksTheValueAfterIt() {
        let shell = ArgumentRedactor.redact(arguments: ["sh", "-c", "run --auth '--password' aZ7!geheim --port 8080"])
        #expect(shell.values == ["sh", "-c", "•••"])
        #expect(shell.containsSecret)
        let quotedAssignment = ArgumentRedactor.redact(arguments: ["run --'password'=aZ7!geheim --port 8080"])
        #expect(quotedAssignment.values == ["run --password=••• --port 8080"])
    }

    /// Quotierte Wörter ohne Geheimnis bleiben unverändert, auch mit Anführungszeichen mitten im Wort und Escapes.
    @Test func quotedOrdinaryWordsStayUnchanged() {
        let input = ["run --na'me' x \\-\\-verbose \"a\\\"b\" c\\ d", "echo don't panic"]
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    /// `--password -` liest das Passwort von der Standardeingabe: maskiert, aber kein Geheimnis im Klartext.
    @Test func secretFlagFollowedByStdinMarkerIsNoPlaintextSecret() {
        let result = ArgumentRedactor.redact(arguments: ["--password", "-"])
        #expect(result.values == ["--password", "•••"])
        #expect(!result.containsSecret)
    }

    @Test func headerInsideFlagAssignmentIsMasked() {
        let result = ArgumentRedactor.redact(arguments: ["--header=Authorization: Bearer xyz", "--header=X-Api-Key:abc"])
        #expect(result.values == ["--header=Authorization: •••", "--header=X-Api-Key: •••"])
        #expect(result.containsSecret)
    }

    @Test func headerPlaceholderInsideFlagAssignmentIsMaskedWithoutFlag() {
        let result = ArgumentRedactor.redact(arguments: ["--header=Authorization: Bearer ${TOKEN}"])
        #expect(result.values == ["--header=Authorization: •••"])
        #expect(!result.containsSecret)
    }

    @Test func assignmentValueIsRedactedLikeAnArgument() {
        let result = ArgumentRedactor.redact(arguments: [
            "DATABASE_URL=postgresql://u:p@h/db", "--endpoint=https://example.com/mcp?token=abc", "MODE=fast",
        ])
        #expect(result.values == [
            "DATABASE_URL=postgresql://u:•••@h/db", "--endpoint=https://example.com/mcp?token=•••", "MODE=fast",
        ])
        #expect(result.containsSecret)
    }

    @Test func masksQueryWithoutScheme() {
        let single = ArgumentRedactor.redact(url: "localhost:3000?token=abc")
        #expect(single.value == "localhost:3000?token=•••")
        #expect(single.containsSecret)

        let result = ArgumentRedactor.redact(arguments: ["host/path?api_key=x&mode=y", "host/p?token=abc#frag"])
        #expect(result.values == ["host/path?api_key=•••&mode=•••", "host/p?token=•••#frag"])
        #expect(result.containsSecret)
    }

    @Test func nonSecretQueryWithoutSchemeIsMaskedButNotFlagged() {
        let plain = ArgumentRedactor.redact(url: "host/path?mode=y")
        #expect(plain.value == "host/path?mode=•••")
        #expect(!plain.containsSecret)

        let placeholder = ArgumentRedactor.redact(url: "host/path?token=${TOKEN}")
        #expect(placeholder.value == "host/path?token=•••")
        #expect(!placeholder.containsSecret)
    }

    @Test func argumentsWithoutQueryAreUnchanged() {
        let input = ["-y", "pkg", "host:3000", "src/index.js", "what?", "a?b", "user@example.com", "key:", "a&b=c"]
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    @Test func emptyValuesAreNeitherMaskedNorFlagged() {
        let input = ["--token", "", "pkg", "TOKEN=", "--password=", "Authorization:"]
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    // MARK: - Namen für Connection-Strings

    @Test(arguments: ["PWD", "Pwd", "Password", "api_key", "Access Key"])
    func connectionStringSecretKeys(_ name: String) {
        #expect(SecretNames.isConnectionStringSecret(name))
    }

    @Test(arguments: ["Server", "User Id", "Data Source", "Driver", "UID"])
    func connectionStringOrdinaryKeys(_ name: String) {
        #expect(!SecretNames.isConnectionStringSecret(name))
    }

    // MARK: - Connection-Strings

    @Test func masksPasswordInConnectionString() {
        let result = ArgumentRedactor.redact(arguments: [
            "Server=x;User Id=sa;Password=hunter2;", "--connection-string=Server=x;Password=y",
        ])
        #expect(result.values == ["Server=x;User Id=sa;Password=•••;", "--connection-string=Server=x;Password=•••"])
        #expect(result.containsSecret)
    }

    @Test func connectionStringKeepsSpacesAndHandlesFirstSegmentWithSpaces() {
        let result = ArgumentRedactor.redact(arguments: ["Data Source=db; User Id=sa; Password=hunter2"])
        #expect(result.values == ["Data Source=db; User Id=sa; Password=•••"])
        #expect(result.containsSecret)
    }

    @Test func masksOdbcPwdOnlyInsideConnectionStrings() {
        let odbc = ArgumentRedactor.redact(arguments: ["Driver={SQL};UID=sa;PWD=secret"])
        #expect(odbc.values == ["Driver={SQL};UID=sa;PWD=•••"])
        #expect(odbc.containsSecret)

        // Ein Passwort im ersten Segment maskiert den ganzen Rest (lieber zu viel).
        let first = ArgumentRedactor.redact(arguments: ["PWD=x;Server=y"])
        #expect(first.values == ["PWD=•••"])
        #expect(first.containsSecret)

        // Als eigenständige Umgebungsvariable ist PWD das Arbeitsverzeichnis.
        let directory = ArgumentRedactor.redact(arguments: ["PWD=/Users/x"])
        #expect(directory.values == ["PWD=/Users/x"])
        #expect(!directory.containsSecret)
    }

    @Test func connectionStringSegmentsMayContainUrls() {
        let result = ArgumentRedactor.redact(arguments: ["Endpoint=sb://bus.example.net/;SharedAccessKey=abc"])
        #expect(result.values == ["Endpoint=sb://bus.example.net/;SharedAccessKey=•••"])
        #expect(result.containsSecret)
    }

    @Test func connectionStringPlaceholderIsMaskedWithoutFlag() {
        let result = ArgumentRedactor.redact(arguments: ["Server=x;Password=${DB_PASS}"])
        #expect(result.values == ["Server=x;Password=•••"])
        #expect(!result.containsSecret)
    }

    @Test func semicolonsInOrdinaryArgumentsAreUnchanged() {
        let input = ["console.log(1);console.log(2)", "a=1;b=2", "x;y;", ";"]
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    @Test func semicolonScriptWithSecretAssignmentMasksTheRest() {
        // Ein geheimnisartiger Name maskiert den ganzen Wert, falls das Geheimnis selbst ein ";" enthält.
        let result = ArgumentRedactor.redact(arguments: ["export API_TOKEN=abc123; run --fast", "run; export API_TOKEN=abc123"])
        #expect(result.values == ["export API_TOKEN=•••", "run; export API_TOKEN=•••"])
        #expect(result.containsSecret)
    }

    @Test func cookieHeaderIsMaskedCompletely() {
        let result = ArgumentRedactor.redact(arguments: ["Cookie: session=abc; theme=dark", "Cookie: session=abc"])
        #expect(result.values == ["Cookie: •••", "Cookie: •••"])
        #expect(result.containsSecret)
    }

    // MARK: - Bekannte Token-Präfixe

    @Test(arguments: [
        "sk-ant-api03-fakefakefakefake", "sk-fakefakefake0123456789", "ghp_fakefakefakefakefakefake0123",
        "gho_fakefakefakefakefakefake0123", "ghs_fakefakefakefakefakefake0123", "ghu_fakefakefakefakefakefake0123",
        "github_pat_11FAKE0fakefakefake_fakefake", "glpat-fakefakefakefake0123", "xoxb-0000000000-fakefakefake",
        "xoxp-0000000000-fakefakefake", "xapp-1-A0000-0000-fakefakefake", "AKIAFAKEFAKEFAKE0123",
        "AIzaFakeFakeFakeFake-Fake_0123", "hf_fakefakefakefake0123456789", "npm_fakefakefakefakefakefake0123",
        "sk-ant-fakefake0123456789==",
    ])
    func masksKnownTokenPrefixes(_ token: String) {
        let result = ArgumentRedactor.redact(arguments: [token])
        #expect(result.values == ["•••"])
        #expect(result.containsSecret)
    }

    @Test func shortTokenLookalikesAreUnchanged() {
        let input = ["sk-123", "ghp_short", "AKIA1234", "hf_abc", "xoxb-1"]
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    @Test func tokenLookalikesInsideOtherArgumentsAreUnchanged() {
        let input = ["npm_config_cache=/tmp/some-long-directory", "sk-learn-demo-project-name=1", "ghp_fakefakefakefakefake/path"]
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    @Test func masksTokenAsAssignmentValueAndQueryValue() {
        let result = ArgumentRedactor.redact(arguments: [
            "FOO=ghp_fakefakefakefakefakefake0123", "https://example.com/p?x=ghp_fakefakefakefakefakefake0123",
        ])
        #expect(result.values == ["FOO=•••", "https://example.com/p?x=•••"])
        #expect(result.containsSecret)
    }

    // MARK: - Fehlalarme

    @Test func tokenCountsAndFileNamesAreNotReported() {
        let input = ["MAX_TOKENS=4096", "--tokenizer", "x", "--token-file", "/p", "--max-tokens", "512"]
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    @Test func pathAndNumberValuesAreMaskedButNotReported() {
        let result = ArgumentRedactor.redact(arguments: [
            "GOOGLE_APPLICATION_CREDENTIALS=/a.json", "--token", "4096", "--password", "~/pw.txt", "TOKEN=./t", "X_KEY=../k",
        ])
        #expect(result.values == [
            "GOOGLE_APPLICATION_CREDENTIALS=•••", "--token", "•••", "--password", "•••", "TOKEN=•••", "X_KEY=•••",
        ])
        #expect(!result.containsSecret)
    }

    @Test func authFlagsAreMaskedButNegationsAreNot() {
        let masked = ArgumentRedactor.redact(arguments: ["--basic-auth", "u:p", "Proxy-Authorization: Basic x"])
        #expect(masked.values == ["--basic-auth", "•••", "Proxy-Authorization: •••"])
        #expect(masked.containsSecret)

        let negation = ArgumentRedactor.redact(arguments: ["--no-auth", "server.js"])
        #expect(negation.values == ["--no-auth", "server.js"])
        #expect(!negation.containsSecret)
    }

    // MARK: - Webhook- und Bot-Token im Pfad

    @Test(arguments: [
        (input: "https://hooks.slack.com/services/T000/B000/XXXX", expected: "https://hooks.slack.com/services/•••"),
        (input: "https://discord.com/api/webhooks/123/abc-def", expected: "https://discord.com/api/webhooks/•••"),
        (input: "https://discordapp.com/api/webhooks/123/abc-def", expected: "https://discordapp.com/api/webhooks/•••"),
        (input: "https://api.telegram.org/bot123:ABC/sendMessage", expected: "https://api.telegram.org/bot•••"),
        (input: "https://api.telegram.org/file/bot123:ABC/doc.pdf", expected: "https://api.telegram.org/file/bot•••"),
        (input: "https://HOOKS.SLACK.COM:443/services/T/B/X", expected: "https://HOOKS.SLACK.COM:443/services/•••"),
        (input: "https://hooks.slack.com/services/T/B/X?mode=1#f", expected: "https://hooks.slack.com/services/•••?mode=•••#f"),
        // Host wie `MCPTransport.remoteHost`: ein abschließender Punkt ändert nichts.
        (input: "https://hooks.slack.com./services/T/B/X", expected: "https://hooks.slack.com./services/•••"),
    ])
    func masksTokenInUrlPath(input: String, expected: String) {
        let result = ArgumentRedactor.redact(url: input)
        #expect(result.value == expected)
        #expect(result.containsSecret)
    }

    @Test(arguments: [
        "https://hooks.slack.com/other/x", "https://example.com/services/T/B/X", "https://hooks.slack.com/services/",
        "https://api.telegram.org/bot", "https://discord.com/channels/1/2",
    ])
    func otherUrlPathsAreUnchanged(_ input: String) {
        let result = ArgumentRedactor.redact(url: input)
        #expect(result.value == input)
        #expect(!result.containsSecret)
    }

    // MARK: - Bearer, Header, Zuweisungen

    @Test func bearerIsFoundCaseInsensitively() {
        let result = ArgumentRedactor.redact(arguments: ["bearer abc", "Authorization: bearer abc", "BEARER abc"])
        #expect(result.values == ["bearer •••", "Authorization: •••", "BEARER •••"])
        #expect(result.containsSecret)
    }

    @Test func loneBearerWordIsNotASecret() {
        let word = ArgumentRedactor.redact(arguments: ["Bearer"])
        #expect(word.values == ["Bearer"])
        #expect(!word.containsSecret)

        let header = ArgumentRedactor.redact(arguments: ["Authorization: Bearer"])
        #expect(header.values == ["Authorization: •••"])
        #expect(!header.containsSecret)
    }

    @Test func headerGivenAsFollowUpArgumentIsMasked() {
        let result = ArgumentRedactor.redact(arguments: ["-H", "Authorization: Bearer xyz", "-H", "Accept: text/plain"])
        #expect(result.values == ["-H", "Authorization: •••", "-H", "Accept: text/plain"])
        #expect(result.containsSecret)
    }

    @Test func secretAssignmentBehindOrdinaryFlagIsMasked() {
        let result = ArgumentRedactor.redact(arguments: ["--env=X_TOKEN=y"])
        #expect(result.values == ["--env=X_TOKEN=•••"])
        #expect(result.containsSecret)
    }

    @Test func nonSecretQueryInsideFlagValueIsMaskedButNotReported() {
        let result = ArgumentRedactor.redact(arguments: ["--allowed-origins=http://a?b=c"])
        #expect(result.values == ["--allowed-origins=http://a?b=•••"])
        #expect(!result.containsSecret)
    }

    // MARK: - Fragment und mehrere Fragezeichen

    @Test func masksFragmentParametersLikeQuery() {
        let oauth = ArgumentRedactor.redact(url: "https://h/cb#access_token=abc&state=xyz")
        #expect(oauth.value == "https://h/cb#access_token=•••&state=•••")
        #expect(oauth.containsSecret)

        let route = ArgumentRedactor.redact(url: "https://h/app#/route?token=abc")
        #expect(route.value == "https://h/app#/route?token=•••")
        #expect(route.containsSecret)

        let schemeless = ArgumentRedactor.redact(url: "host/p#access_token=abc")
        #expect(schemeless.value == "host/p#access_token=•••")
        #expect(schemeless.containsSecret)
    }

    @Test func plainFragmentAndQuestionMarkInFragmentStayHarmless() {
        let anchor = ArgumentRedactor.redact(url: "https://h/app#section")
        #expect(anchor.value == "https://h/app#section")
        #expect(!anchor.containsSecret)

        let inFragment = ArgumentRedactor.redact(url: "https://h/p#frag?x=1")
        #expect(inFragment.value == "https://h/p#frag?x=•••")
        #expect(!inFragment.containsSecret)
    }

    @Test func checksTheInnermostNameWhenQuestionMarksRepeat() {
        let nested = ArgumentRedactor.redact(url: "https://h/cb?redirect=/x?token=abc")
        #expect(nested.value == "https://h/cb?redirect=•••")
        #expect(nested.containsSecret)

        let harmless = ArgumentRedactor.redact(url: "https://h/cb?redirect=/x?mode=abc")
        #expect(harmless.value == "https://h/cb?redirect=•••")
        #expect(!harmless.containsSecret)
    }

    // MARK: - Unicode und Laufzeit

    @Test func handlesUnicodeArguments() {
        let secret = ArgumentRedactor.redact(arguments: ["--token", "pässwörd-日本語"])
        #expect(secret.values == ["--token", "•••"])
        #expect(secret.containsSecret)

        let names = ArgumentRedactor.redact(arguments: ["Ünï=çödé", "SCHLÜSSEL_KEY=wert", "名前=値", "🔑=abc"])
        #expect(names.values == ["Ünï=çödé", "SCHLÜSSEL_KEY=•••", "名前=値", "🔑=abc"])
        #expect(names.containsSecret)
    }

    @Test func veryLongArgumentsAreRedactedQuickly() {
        let plain = String(repeating: "a", count: 300_000)
        let assignments = String(repeating: "a=", count: 100_000) + "b"
        let parameters = "https://h/p?" + (0..<30_000).map { "p\($0)=v" }.joined(separator: "&")
        let segments = (0..<30_000).map { "k\($0)=v" }.joined(separator: ";")
        let longFlag = "--" + plain
        let words = (0..<30_000).map { "w\($0)" }.joined(separator: " ")
        var results: [ArgumentRedactor.Arguments] = []
        let elapsed = ContinuousClock().measure {
            results = [plain, assignments, parameters, segments, longFlag, words].map { ArgumentRedactor.redact(arguments: [$0]) }
        }
        #expect(elapsed < .seconds(5))
        #expect(results[0].values == [plain])
        #expect(results[1].values[0].count < 100 && results[1].values[0].hasSuffix("•••"))
        #expect(results[2].values[0].hasPrefix("https://h/p?p0=•••&p1=•••"))
        #expect(!results[3].containsSecret)
        #expect(results[4].values == [longFlag])
        #expect(results[5].values == [words])
        #expect(!results[5].containsSecret)
    }

    // MARK: - Schalter, Auth-Modi und Token-Listen

    @Test(arguments: [
        ["--enable-auth", "dist/index.js"], ["--disable-auth", "server.js"], ["--skip-auth", "x"], ["--require-auth", "true"],
    ])
    func switchFlagsDoNotMaskTheNextArgument(_ input: [String]) {
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    @Test(arguments: ["none", "oauth", "OAuth2", "true", "False", "yes", "No", "on", "OFF", "basic", "bearer"])
    func keywordValuesAreMaskedButNotReported(_ keyword: String) {
        let result = ArgumentRedactor.redact(arguments: ["--auth", keyword, "API_KEY=\(keyword)"])
        #expect(result.values == ["--auth", "•••", "API_KEY=•••"])
        #expect(!result.containsSecret)
    }

    @Test func tokenListsAreSecrets() {
        let result = ArgumentRedactor.redact(arguments: ["--tokens", "abc,def", "API_TOKENS=abcd,efgh"])
        #expect(result.values == ["--tokens", "•••", "API_TOKENS=•••"])
        #expect(result.containsSecret)
    }

    @Test func counterNamesStayHarmless() {
        let input = ["NUM_TOKENS=12", "--min-tokens", "3", "MODEL_MAX_TOKENS=100"]
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    // MARK: - Shell-Wrapper

    /// In einem Shell-Aufruf mit `-c` gilt jedes Argument als mögliches Skript und steht ganz oder gar nicht da (#137);
    /// außerhalb einer Shell werden Argumente mit Leerraum wie bisher wortweise ausgewertet.
    @Test func masksSecretsInsideShellStrings() {
        let result = ArgumentRedactor.redact(arguments: [
            "sh", "-c", "export GITHUB_TOKEN=abc && npx server",
            "cd /x && API_KEY=abc node s.js",
            "node s.js --api-key abc",
        ])
        #expect(result.values == ["sh", "-c", "•••", "•••", "•••"])
        let plain = ArgumentRedactor.redact(arguments: ["run", "cd /x && API_KEY=abc node s.js", "node s.js --api-key abc"])
        #expect(plain.values == ["run", "cd /x && API_KEY=••• node s.js", "node s.js --api-key •••"])
        #expect(result.containsSecret)
    }

    @Test func shellStringWithoutSecretsIsUnchanged() {
        let input = ["node server.js --port 3000", "  leading and   multiple   spaces ", " ", "a\tb\nc", "Accept: text/plain"]
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    @Test func shellStringKeepsItsWhitespaceLayout() {
        let result = ArgumentRedactor.redact(arguments: ["export  A=1\n\tTOKEN=x   run"])
        #expect(result.values == ["export  A=1\n\tTOKEN=•••   run"])
        #expect(result.containsSecret)
    }

    @Test func shellStringBehindOrdinaryFlagIsMasked() {
        let result = ArgumentRedactor.redact(arguments: ["--cmd=node s.js --api-key abc"])
        #expect(result.values == ["--cmd=node s.js --api-key •••"])
        #expect(result.containsSecret)
    }

    @Test func shellStringWordsAreRedactedLikeArguments() {
        let result = ArgumentRedactor.redact(arguments: ["curl https://u:pw@h/x?token=a --max-tokens 5 --enable-auth y"])
        #expect(result.values == ["curl https://u:•••@h/x?token=••• --max-tokens 5 --enable-auth y"])
        #expect(result.containsSecret)
    }

    // MARK: - Engere Token-Präfixe

    @Test(arguments: [
        "sk-learn-is-a-package", "hf_hub_enable_transfer", "ghp_fake_underscore_0123456789", "hf_fake-dash-0123456789",
        "AKIAFAKEFAKEFAKEFAKE", "glpat-fakefakefakefakefake", "npm_fakefakefakefakefakefake",
    ])
    func tokenLookalikesWithoutDigitOrWithWrongCharactersAreUnchanged(_ input: String) {
        let result = ArgumentRedactor.redact(arguments: [input])
        #expect(result.values == [input])
        #expect(!result.containsSecret)
    }

    // MARK: - Leerraum um "="

    @Test func keepsWhitespaceAroundEqualsSign() {
        let result = ArgumentRedactor.redact(arguments: [
            "Password = y", "Password= y", "Server = x; Password = y", "API_KEY =", "PWD = /Users/x", "name = value",
        ])
        #expect(result.values == [
            "Password = •••", "Password= •••", "Server = x; Password = •••", "API_KEY =", "PWD = /Users/x", "name = value",
        ])
        #expect(result.containsSecret)
    }

    // MARK: - Quotierte Geheimnisse in Shell-Strings

    @Test func masksQuotedSecretAssignmentInShellString() {
        let result = ArgumentRedactor.redact(arguments: ["sh", "-c", "PASSWORD='my secret' node s.js"])
        #expect(result.values == ["sh", "-c", "•••"])
        #expect(ArgumentRedactor.redact(arguments: ["PASSWORD='my secret' node s.js"]).values == ["PASSWORD=••• node s.js"])
        #expect(result.containsSecret)
    }

    @Test func masksQuotedFlagValueInShellString() {
        let result = ArgumentRedactor.redact(arguments: ["sh", "-c", "node s.js --token \"a b c\" --port 1"])
        #expect(result.values == ["sh", "-c", "•••"])
        #expect(ArgumentRedactor.redact(arguments: ["node s.js --token \"a b c\" --port 1"]).values == ["node s.js --token ••• --port 1"])
        #expect(result.containsSecret)
    }

    @Test func masksQuotedHeaderInShellString() {
        let wrapped = ArgumentRedactor.redact(arguments: ["curl -H \"X-Api-Key: abc def\" https://h/x"])
        #expect(wrapped.values == ["curl -H \"X-Api-Key: •••\" https://h/x"])
        #expect(wrapped.containsSecret)

        let quotedValue = ArgumentRedactor.redact(arguments: ["curl -H X-Api-Key:'abc def' https://h/x"])
        #expect(quotedValue.values == ["curl -H X-Api-Key: ••• https://h/x"])
        #expect(quotedValue.containsSecret)
    }

    @Test func unbalancedQuoteMasksUpToTheEndOfTheArgument() {
        let result = ArgumentRedactor.redact(arguments: [
            "export API_KEY='abc def && run it", "node s.js --token \"abc def", "API_KEY='abc def",
        ])
        #expect(result.values == ["export API_KEY=•••", "node s.js --token •••", "API_KEY=•••"])
        #expect(result.containsSecret)
    }

    @Test func quotedValueMayContinueAfterTheClosingQuoteAndMayContainEscapedQuotes() {
        let result = ArgumentRedactor.redact(arguments: ["PASSWORD='ab cd'ef run", "PASSWORD=\"ab\\\"cd ef\" run"])
        #expect(result.values == ["PASSWORD=••• run", "PASSWORD=••• run"])
        #expect(result.containsSecret)
    }

    @Test func quotedPlaceholdersAndEmptyQuotesAreNotReported() {
        let result = ArgumentRedactor.redact(arguments: ["PASSWORD=\"$PW\" run", "PASSWORD=\"\" run", "--token '${TOKEN}'"])
        #expect(result.values == ["PASSWORD=••• run", "PASSWORD=\"\" run", "--token •••"])
        #expect(!result.containsSecret)
    }

    @Test func ordinaryQuotedWordsKeepTheirWhitespace() {
        let input = ["echo 'hello world' --name \"a b\"", "say \"two  words\"   now", "--opt='a b' x"]
        let result = ArgumentRedactor.redact(arguments: input)
        #expect(result.values == input)
        #expect(!result.containsSecret)
    }

    @Test func masksSecretAssignmentButKeepsOtherQuotedWords() {
        let result = ArgumentRedactor.redact(arguments: ["export API_KEY='a b' && echo 'hi there'"])
        #expect(result.values == ["export API_KEY=••• && echo 'hi there'"])
        #expect(result.containsSecret)
    }

    @Test func secretInsideUnbalancedOrdinaryQuoteIsStillMasked() {
        let result = ArgumentRedactor.redact(arguments: ["echo 'abc && export API_KEY=xyz"])
        #expect(result.values == ["echo 'abc && export API_KEY=•••"])
        #expect(result.containsSecret)
    }

    @Test func apostropheInProseDoesNotBreakAnything() {
        let result = ArgumentRedactor.redact(arguments: ["--description", "don't use --token flag"])
        #expect(result.values.count == 2)
        #expect(result.values[1].hasPrefix("don't use --token"))
        #expect(!result.values[1].contains("flag"))
    }

    // MARK: - Trenner in quotierten oder escapten Werten (#155)

    @Test(arguments: [
        ("run '--password' 'aZ7;geheim'", "run '--password' •••"),
        ("run \"--password\" \"aZ7;geheim\"", "run \"--password\" •••"),
        ("run --password aZ7\\;geheim", "run --password •••"),
        ("run --token 'a;b&c,d' ; echo ok; ls", "run --token ••• ; echo ok; ls"),
        ("run --password='a;b' x", "run --password=••• x"),
        ("run --password=\"a;b\" x", "run --password=••• x"),
        ("run PASSWORD='a;b;c' && echo 'x;y'", "run PASSWORD=••• && echo 'x;y'"),
        ("run --url 'postgres://u:pw;x@h/db'", "run --url 'postgres://u:•••@h/db'"),
    ])
    func separatorInsideQuotedOrEscapedShellValueDoesNotSplitTheSecret(_ shell: String, _ expected: String) {
        // Als Skript hinter `sh -c` ganz maskiert (#137) …
        let script = ArgumentRedactor.redact(arguments: ["sh", "-c", shell])
        #expect(script.values == ["sh", "-c", "•••"])
        #expect(script.containsSecret)
        // … als gewöhnliches Argument mit Leerraum wortweise wie bisher.
        let result = ArgumentRedactor.redact(arguments: [shell])
        #expect(result.values == [expected])
        #expect(result.containsSecret)
        #expect(!result.values[0].contains("geheim"))
    }

    @Test func separatorInsideQuotedValueOfArgumentDoesNotSplitTheSecret() {
        let result = ArgumentRedactor.redact(arguments: [
            "--password='a;b'", "--password=\"a;b\"", "postgres://u:pw;x@h/db",
            "Server=x;Password='a;b';Database=d", "Driver={SQL};PWD={a;b};UID=sa",
        ])
        #expect(result.values == [
            "--password=•••", "--password=•••", "postgres://u:•••@h/db",
            "Server=x;Password=•••;Database=d", "Driver={SQL};PWD=•••;UID=sa",
        ])
        #expect(result.containsSecret)
    }

    @Test func separatorOutsideTheURLUserinfoStillSplitsTheConnectionString() {
        let result = ArgumentRedactor.redact(arguments: [
            "Endpoint=sb://bus.example.net/;SharedAccessKey=abc", "Server=tcp://h;Password=y", "postgres://u:pw;x@h;Password=y",
        ])
        #expect(result.values == [
            "Endpoint=sb://bus.example.net/;SharedAccessKey=•••", "Server=tcp://h;Password=•••", "postgres://u:•••@h;Password=•••",
        ])
        #expect(result.containsSecret)
    }

    @Test func ordinaryShellCommandsWithSeparatorsStayUnchanged() {
        let input = [
            "cd /tmp; echo 'a;b'; ls -la", "find . -name '*.js' -exec rm {} \\;", "echo \"x;y\" && run --port 3000",
            "for f in *; do echo $f; done",
        ]
        let result = ArgumentRedactor.redact(arguments: ["sh", "-c"] + input)
        #expect(result.values == ["sh", "-c"] + input)
        #expect(!result.containsSecret)
    }

    @Test func manyQuotesAreRedactedQuickly() {
        let quotes = String(repeating: "\"", count: 100_000)
        let nested = String(repeating: "'a b' ", count: 30_000)
        let unbalanced = "'" + String(repeating: "a b ", count: 50_000)
        var results: [ArgumentRedactor.Arguments] = []
        let elapsed = ContinuousClock().measure {
            results = [quotes, nested, unbalanced].map { ArgumentRedactor.redact(arguments: [$0]) }
        }
        #expect(elapsed < .seconds(5))
        #expect(results.count == 3)
        #expect(!results[1].containsSecret)
    }
}
