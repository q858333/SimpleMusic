import Foundation

enum L10n {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        formatted(key, bundle: .main, arguments: arguments)
    }

    static func formatted(
        _ key: String,
        bundle: Bundle,
        arguments: [CVarArg]
    ) -> String {
        String(
            format: text(key, bundle: bundle),
            locale: Locale.current,
            arguments: arguments
        )
    }

    static func plural(
        _ key: String,
        count: Int,
        bundle: Bundle = .main
    ) -> String {
        // stringsdict 由 Foundation 按 count 选择英文单复数；简繁中文共享同一数量格式。
        String.localizedStringWithFormat(text(key, bundle: bundle), count)
    }
}
