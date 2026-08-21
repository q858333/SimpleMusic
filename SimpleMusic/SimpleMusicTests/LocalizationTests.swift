import XCTest
@testable import SimpleMusic

final class LocalizationTests: XCTestCase {
    func testSupportedBundlesResolveRepresentativeCopy() throws {
        XCTAssertEqual(L10n.text("app.name", bundle: try languageBundle("en")), "DiskTone")
        XCTAssertEqual(L10n.text("app.name", bundle: try languageBundle("zh-Hans")), "听见")
        XCTAssertEqual(L10n.text("app.name", bundle: try languageBundle("zh-Hant")), "聽見")
        XCTAssertEqual(L10n.text("common.settings", bundle: try languageBundle("zh-Hant")), "設定")
    }

    func testLocalizableStringKeysMatchAcrossLanguages() throws {
        let english = try stringsDictionary(language: "en", name: "Localizable")
        XCTAssertEqual(Set(english.keys), Set(try stringsDictionary(language: "zh-Hans", name: "Localizable").keys))
        XCTAssertEqual(Set(english.keys), Set(try stringsDictionary(language: "zh-Hant", name: "Localizable").keys))
    }

    func testInfoPlistLocalizationsContainBrandAndPermissionCopy() throws {
        XCTAssertEqual(try stringsDictionary(language: "en", name: "InfoPlist")["CFBundleDisplayName"], "DiskTone")
        XCTAssertEqual(try stringsDictionary(language: "zh-Hans", name: "InfoPlist")["CFBundleDisplayName"], "听见")
        XCTAssertEqual(try stringsDictionary(language: "zh-Hant", name: "InfoPlist")["CFBundleDisplayName"], "聽見")
        for language in ["en", "zh-Hans", "zh-Hant"] {
            XCTAssertFalse(try XCTUnwrap(stringsDictionary(language: language, name: "InfoPlist")["NSAppleMusicUsageDescription"]).isEmpty)
        }
    }

    func testProjectUsesEnglishFallbackAndRegistersSupportedRegions() throws {
        let project = try String(contentsOf: projectRoot.appendingPathComponent("SimpleMusic.xcodeproj/project.pbxproj"))
        XCTAssertTrue(project.contains("developmentRegion = en;"))
        XCTAssertTrue(project.contains("zh-Hans,"))
        XCTAssertTrue(project.contains("zh-Hant,"))
    }

    func testFormattedCopyKeepsParametersAcrossLanguages() throws {
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let bundle = try languageBundle(language)
            let queue = L10n.formatted("player.queue.position", bundle: bundle, arguments: [2, 4])
            XCTAssertTrue(queue.contains("2"))
            XCTAssertTrue(queue.contains("4"))
            XCTAssertFalse(queue.contains("player.queue.position"))
        }
    }

    func testFormatUsesMainBundleLocalization() throws {
        let expectedByLanguage = [
            "en": "Track 2 of 4",
            "zh-Hans": "第 2 / 4 首",
            "zh-Hant": "第 2 / 4 首",
        ]
        XCTAssertEqual(
            L10n.format("player.queue.position", 2, 4),
            try XCTUnwrap(expectedByLanguage[activeLanguage])
        )
    }

    func testDownloadSuccessMessageUsesFirstPositionalObjectParameterAcrossLanguages() throws {
        let expected = ["%1$@"]

        for language in ["en", "zh-Hans", "zh-Hant"] {
            let copy = try XCTUnwrap(
                stringsDictionary(language: language, name: "Localizable")["download.success_message"]
            )
            XCTAssertEqual(formatSpecifiers(in: copy), expected, "language=\(language)")
        }
    }

    func testDownloadQueueProgressUsesLocalizedIntegerFormatAcrossLanguages() throws {
        let expectedByLanguage = [
            "en": "37% downloaded",
            "zh-Hans": "已下载 37%",
            "zh-Hant": "已下載 37%",
        ]

        for language in ["en", "zh-Hans", "zh-Hant"] {
            XCTAssertEqual(
                L10n.formatted(
                    "download.queue.progress",
                    bundle: try languageBundle(language),
                    arguments: [37]
                ),
                expectedByLanguage[language],
                "language=\(language)"
            )
        }
    }

    func testDownloadQueueLocalizationsExposeCompleteSharedKeySet() throws {
        let requiredKeys: Set<String> = [
            "download.queue.add",
            "download.queue.empty",
            "download.queue.waiting",
            "download.queue.interrupted",
            "download.queue.cancelled",
            "download.queue.retry",
            "download.queue.remove",
            "download.queue.progress",
            "download.queue.accessibility.progress",
            "download.queue.error.recovery",
        ]

        for language in ["en", "zh-Hans", "zh-Hant"] {
            let values = try stringsDictionary(language: language, name: "Localizable")
            XCTAssertTrue(requiredKeys.isSubset(of: Set(values.keys)), "language=\(language)")
        }
    }

    func testDeletionMessageUsesFirstPositionalObjectParameterAcrossLanguages() throws {
        let expected = ["%1$@"]

        for language in ["en", "zh-Hans", "zh-Hant"] {
            let copy = try XCTUnwrap(
                stringsDictionary(language: language, name: "Localizable")["deletion.message"]
            )
            XCTAssertEqual(formatSpecifiers(in: copy), expected, "language=\(language)")
        }
    }

    func testTrackAccessibilityFormatUsesLocalizedPunctuationAcrossLanguages() throws {
        let expectedByLanguage = [
            "en": "Title, Artist, Album",
            "zh-Hans": "Title，Artist，Album",
            "zh-Hant": "Title，Artist，Album",
        ]

        for language in ["en", "zh-Hans", "zh-Hant"] {
            XCTAssertEqual(
                L10n.formatted(
                    "track.accessibility",
                    bundle: try languageBundle(language),
                    arguments: ["Title", "Artist", "Album"]
                ),
                expectedByLanguage[language],
                "language=\(language)"
            )
        }
    }

    func testTrackCountUsesActiveLanguagePluralFormat() throws {
        let expectedByLanguage = [
            "en": ["1 song", "2 songs"],
            "zh-Hans": ["1 首", "2 首"],
            "zh-Hant": ["1 首", "2 首"],
        ]
        let expected = try XCTUnwrap(expectedByLanguage[activeLanguage])
        XCTAssertEqual(L10n.plural("tracks.count", count: 1), expected[0])
        XCTAssertEqual(L10n.plural("tracks.count", count: 2), expected[1])
    }

    func testLocalizableStringParametersMatchAcrossLanguages() throws {
        let english = try stringsDictionary(language: "en", name: "Localizable")
        for language in ["zh-Hans", "zh-Hant"] {
            let localized = try stringsDictionary(language: language, name: "Localizable")
            for key in english.keys {
                XCTAssertEqual(
                    formatParameters(in: try XCTUnwrap(english[key])),
                    formatParameters(in: try XCTUnwrap(localized[key])),
                    "key=\(key), language=\(language)"
                )
            }
        }
    }

    func testStringsdictTopLevelKeysMatchTrackCountContract() throws {
        for language in ["en", "zh-Hans", "zh-Hant"] {
            XCTAssertEqual(Set(try stringsdictDictionary(language: language).keys), Set(["tracks.count"]))
        }
    }

    func testProductionSwiftHasNoUnlocalizedHanStringLiterals() throws {
        let sourceRoot = projectRoot.appendingPathComponent("SimpleMusic", isDirectory: true)
        let sourceURLs = try XCTUnwrap(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        var failures: [String] = []

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let relativePath = sourceURL.path.replacingOccurrences(
                of: projectRoot.path + "/",
                with: ""
            )
            failures.append(contentsOf: try unlocalizedHanStringLiterals(in: source, relativePath: relativePath))
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Unlocalized production Swift Han string literals:\n\(failures.joined(separator: "\n"))"
        )
    }

    func testScannerFindsHanAcrossSwiftStringLiteralFormsAndInterpolation() throws {
        let source = ####"""
        let single = "单行"
        let multiline = """
        普通多行
        """
        let rawOne = #"""
        原始一层
        """#
        let rawTwo = ##"""
        原始二层
        """##
        let interpolated = "prefix \(value) 插值片段"
        let rawInterpolated = #"prefix \#(value) 原始插值片段"#
        NSLog("\(userFacing("嵌套用户文案"))")
        """####

        XCTAssertEqual(
            try unlocalizedHanStringLiterals(in: source, relativePath: "Fixtures.swift"),
            [
                "Fixtures.swift:1 \"单行\"",
                "Fixtures.swift:2 \"\"\"\n普通多行\n\"\"\"",
                "Fixtures.swift:5 #\"\"\"\n原始一层\n\"\"\"#",
                "Fixtures.swift:8 ##\"\"\"\n原始二层\n\"\"\"##",
                "Fixtures.swift:11 \"prefix \\(value) 插值片段\"",
                "Fixtures.swift:12 #\"prefix \\#(value) 原始插值片段\"#",
                "Fixtures.swift:13 \"嵌套用户文案\"",
            ]
        )
    }

    func testScannerAllowsOnlyDirectDiagnosticCallLiterals() throws {
        let source = ###"""
        NSLog("诊断")
        fatalError(#"致命诊断"#)
        preconditionFailure("""
        前置条件诊断
        """)
        // NSLog("注释不是字符串")
        let visible = NSLog(makeMessage("用户文案"))
        """###

        XCTAssertEqual(
            try unlocalizedHanStringLiterals(in: source, relativePath: "Diagnostics.swift"),
            ["Diagnostics.swift:7 \"用户文案\""]
        )
    }

    func testScannerSkipsBlockAndNestedBlockCommentsButFindsFollowingLiteral() throws {
        let source = ####"""
        /* “普通注释” #"伪原始字面量"#
           /* ##"嵌套注释中文"## */
        */
        let visible = #"注释后用户文案"#
        """####

        XCTAssertEqual(
            try unlocalizedHanStringLiterals(in: source, relativePath: "BlockComments.swift"),
            ["BlockComments.swift:4 #\"注释后用户文案\"#"]
        )
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var activeLanguage: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    private func languageBundle(_ language: String) throws -> Bundle {
        let appBundle = Bundle(for: AppDelegate.self)
        let resourceURL = try XCTUnwrap(appBundle.resourceURL)
        let languageURL = resourceURL.appendingPathComponent("\(language).lproj")
        return try XCTUnwrap(Bundle(url: languageURL))
    }

    private func stringsDictionary(language: String, name: String) throws -> [String: String] {
        let bundle = try languageBundle(language)
        let fileURL = try XCTUnwrap(bundle.url(forResource: name, withExtension: "strings"))
        let data = try Data(contentsOf: fileURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(propertyList as? [String: String])
    }

    private func stringsdictDictionary(language: String) throws -> [String: Any] {
        let bundle = try languageBundle(language)
        let fileURL = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "stringsdict"))
        let data = try Data(contentsOf: fileURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(propertyList as? [String: Any])
    }

    private func formatParameters(in value: String) -> [String] {
        let pattern = "%(?:(\\d+)\\$)?([@d])"
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        var nextIndex = 1
        return expression.matches(in: value, range: range).map { match in
            let index: Int
            if let indexRange = Range(match.range(at: 1), in: value) {
                index = Int(value[indexRange])!
            } else {
                index = nextIndex
                nextIndex += 1
            }
            let typeRange = Range(match.range(at: 2), in: value)!
            return "\(index):\(value[typeRange])"
        }
    }

    private func formatSpecifiers(in value: String) -> [String] {
        let pattern = "%(?:(?:\\d+)\\$)?[@d]"
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }
    }

    private func containsHanCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private func unlocalizedHanStringLiterals(in source: String, relativePath: String) throws -> [String] {
        var scanner = SwiftHanStringScanner(
            source: source,
            relativePath: relativePath,
            containsHanCharacter: containsHanCharacter
        )
        return scanner.scan()
    }

    private struct SwiftHanStringScanner {
        private enum Token: Equatable {
            case identifier(String)
            case leftParenthesis
            case dot
            case other
        }

        private let characters: [Character]
        private let relativePath: String
        private let containsHanCharacter: (String) -> Bool
        private var index = 0
        private var line = 1
        private var failures: [String] = []

        init(
            source: String,
            relativePath: String,
            containsHanCharacter: @escaping (String) -> Bool
        ) {
            characters = Array(source)
            self.relativePath = relativePath
            self.containsHanCharacter = containsHanCharacter
        }

        mutating func scan() -> [String] {
            scanCode(untilInterpolationEnd: false)
            return failures
        }

        private mutating func scanCode(untilInterpolationEnd: Bool) {
            var recentTokens: [Token] = []
            var nestedParentheses = 0

            while index < characters.count {
                if matches("//") {
                    skipLineComment()
                } else if matches("/*") {
                    skipBlockComment()
                } else if let opening = stringOpening() {
                    let isAllowed = isDirectDiagnosticArgument(recentTokens)
                    scanString(hashCount: opening.hashCount, isMultiline: opening.isMultiline, isAllowed: isAllowed)
                    append(.other, to: &recentTokens)
                } else if isIdentifierStart(characters[index]) {
                    append(.identifier(scanIdentifier()), to: &recentTokens)
                } else {
                    let character = characters[index]
                    advance()
                    switch character {
                    case "(":
                        nestedParentheses += 1
                        append(.leftParenthesis, to: &recentTokens)
                    case ")" where untilInterpolationEnd && nestedParentheses == 0:
                        return
                    case ")":
                        nestedParentheses -= 1
                        append(.other, to: &recentTokens)
                    case ".":
                        append(.dot, to: &recentTokens)
                    default:
                        if !character.isWhitespace {
                            append(.other, to: &recentTokens)
                        }
                    }
                }
            }
        }

        private mutating func scanString(hashCount: Int, isMultiline: Bool, isAllowed: Bool) {
            let startIndex = index
            let startLine = line
            let quoteCount = isMultiline ? 3 : 1
            index += hashCount + quoteCount
            var hasHanLiteralSegment = false

            while index < characters.count {
                if matchesStringClose(hashCount: hashCount, quoteCount: quoteCount) {
                    index += quoteCount + hashCount
                    break
                }

                if matchesInterpolationStart(hashCount: hashCount) {
                    index += hashCount + 2
                    scanCode(untilInterpolationEnd: true)
                    continue
                }

                if characters[index] == "\\" {
                    if hashCount == 0 {
                        advance()
                        if index < characters.count { advance() }
                        continue
                    }
                    if matchesRawEscapePrefix(hashCount: hashCount) {
                        index += hashCount + 1
                        if index < characters.count { advance() }
                        continue
                    }
                }

                if containsHanCharacter(String(characters[index])) {
                    hasHanLiteralSegment = true
                }
                advance()
            }

            if hasHanLiteralSegment && !isAllowed {
                failures.append("\(relativePath):\(startLine) \(String(characters[startIndex..<index]))")
            }
        }

        private func stringOpening() -> (hashCount: Int, isMultiline: Bool)? {
            var cursor = index
            while cursor < characters.count, characters[cursor] == "#" {
                cursor += 1
            }
            guard cursor < characters.count, characters[cursor] == "\"" else { return nil }
            let hashCount = cursor - index
            let isMultiline = cursor + 2 < characters.count
                && characters[cursor + 1] == "\""
                && characters[cursor + 2] == "\""
            return (hashCount, isMultiline)
        }

        private func matchesStringClose(hashCount: Int, quoteCount: Int) -> Bool {
            matches(String(repeating: "\"", count: quoteCount) + String(repeating: "#", count: hashCount))
        }

        private func matchesInterpolationStart(hashCount: Int) -> Bool {
            matches("\\" + String(repeating: "#", count: hashCount) + "(")
        }

        private func matchesRawEscapePrefix(hashCount: Int) -> Bool {
            matches("\\" + String(repeating: "#", count: hashCount))
        }

        private mutating func skipLineComment() {
            while index < characters.count, characters[index] != "\n" {
                index += 1
            }
        }

        private mutating func skipBlockComment() {
            var depth = 0
            while index < characters.count {
                if matches("/*") {
                    depth += 1
                    index += 2
                } else if matches("*/") {
                    depth -= 1
                    index += 2
                    if depth == 0 { return }
                } else {
                    advance()
                }
            }
        }

        private mutating func scanIdentifier() -> String {
            let start = index
            while index < characters.count, isIdentifierContinuation(characters[index]) {
                index += 1
            }
            return String(characters[start..<index])
        }

        private func isDirectDiagnosticArgument(_ tokens: [Token]) -> Bool {
            guard tokens.count >= 2,
                  tokens[tokens.count - 1] == .leftParenthesis,
                  case let .identifier(name) = tokens[tokens.count - 2],
                  ["NSLog", "fatalError", "preconditionFailure"].contains(name)
            else { return false }
            return tokens.count < 3 || tokens[tokens.count - 3] != .dot
        }

        private func isIdentifierStart(_ character: Character) -> Bool {
            character == "_" || character.isLetter
        }

        private func isIdentifierContinuation(_ character: Character) -> Bool {
            isIdentifierStart(character) || character.isNumber
        }

        private mutating func append(_ token: Token, to tokens: inout [Token]) {
            tokens.append(token)
            if tokens.count > 3 {
                tokens.removeFirst(tokens.count - 3)
            }
        }

        private func matches(_ text: String) -> Bool {
            let expected = Array(text)
            guard index + expected.count <= characters.count else { return false }
            return Array(characters[index..<(index + expected.count)]) == expected
        }

        private mutating func advance() {
            if characters[index] == "\n" {
                line += 1
            }
            index += 1
        }
    }
}
