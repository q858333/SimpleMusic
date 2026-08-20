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

    func testFormatUsesMainBundleForEnglishFallback() {
        XCTAssertEqual(L10n.format("player.queue.position", 2, 4), "Track 2 of 4")
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

    func testTrackCountUsesEnglishPluralAndChineseCountFormat() throws {
        XCTAssertEqual(L10n.plural("tracks.count", count: 1, bundle: try languageBundle("en")), "1 song")
        XCTAssertEqual(L10n.plural("tracks.count", count: 2, bundle: try languageBundle("en")), "2 songs")
        XCTAssertEqual(L10n.plural("tracks.count", count: 2, bundle: try languageBundle("zh-Hans")), "2 首")
        XCTAssertEqual(L10n.plural("tracks.count", count: 2, bundle: try languageBundle("zh-Hant")), "2 首")
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

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
}
