import Foundation
import SwiftUI

enum DisplayLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case english
    case japanese

    var locale: Locale {
        switch self {
        case .system:
            .autoupdatingCurrent
        case .english:
            Locale(identifier: "en")
        case .japanese:
            Locale(identifier: "ja_JP")
        }
    }

    func displayName(locale: Locale) -> String {
        switch self {
        case .system:
            AppLocalization.string("System Default", locale: locale)
        case .english:
            AppLocalization.string("English", locale: locale)
        case .japanese:
            AppLocalization.string("Japanese", locale: locale)
        }
    }
}

enum DisplayLanguagePreferences {
    private static let languageKey = "display-language-v1"

    static func load(defaults: UserDefaults? = SharedUsageStore.defaults) -> DisplayLanguage {
        guard
            let rawValue = defaults?.string(forKey: languageKey),
            let language = DisplayLanguage(rawValue: rawValue)
        else { return .system }
        return language
    }

    static func save(
        _ language: DisplayLanguage,
        defaults: UserDefaults? = SharedUsageStore.defaults
    ) {
        defaults?.set(language.rawValue, forKey: languageKey)
        defaults?.synchronize()
    }
}

enum AppLocalization {
    private static let japaneseBundle: Bundle? = {
        guard let path = Bundle.main.path(forResource: "ja", ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }()

    static func string(_ key: String, locale: Locale) -> String {
        guard locale.language.languageCode?.identifier == "ja" else {
            // English is the development language, so its source key is the
            // authoritative fallback and has no separate en.lproj bundle.
            return key
        }
        return japaneseBundle?.localizedString(
            forKey: key,
            value: key,
            table: nil
        ) ?? key
    }

    static func format(
        _ key: String,
        locale: Locale,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: string(key, locale: locale),
            locale: locale,
            arguments: arguments
        )
    }
}

/// Renders an English source key with the language selected in the host app.
///
/// SwiftUI's localized string literals resolve against the process language,
/// which can differ from the locale injected into a widget view. Keeping this
/// wrapper at the UI boundary prevents a Japanese system locale from leaking
/// into a widget whose explicit display language is English.
struct AppLocalizedText: View {
    @Environment(\.locale) private var locale

    private let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(verbatim: AppLocalization.string(key, locale: locale))
    }
}
