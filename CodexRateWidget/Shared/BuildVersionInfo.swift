import Foundation

struct BuildVersionInfo: Equatable, Sendable {
    let shortVersion: String
    let buildNumber: String

    static var current: BuildVersionInfo? {
        BuildVersionInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init?(infoDictionary: [String: Any]) {
        guard
            let shortVersion = Self.clean(infoDictionary["CFBundleShortVersionString"]),
            let buildNumber = Self.clean(infoDictionary["CFBundleVersion"])
        else { return nil }

        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
    }

    var compactLabel: String {
        "v\(shortVersion)"
    }

    var accessibilityLabel: String {
        accessibilityLabel(locale: .current)
    }

    func accessibilityLabel(locale: Locale) -> String {
        AppLocalization.format("Version %@", locale: locale, shortVersion)
    }

    private static func clean(_ rawValue: Any?) -> String? {
        guard let rawValue = rawValue as? String else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}
