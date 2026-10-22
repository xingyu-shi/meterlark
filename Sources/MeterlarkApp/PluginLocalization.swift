import Foundation

/// A text value supplied by a plugin.
///
/// The Codable representation deliberately accepts a plain string for
/// backwards compatibility. A localized value is represented as:
///
///     {
///       "fallback": "Today cost",
///       "translations": { "zh-Hans": "今日费用" }
///     }
///
/// The fallback is always retained. This lets the host safely render a
/// plugin when it does not have a translation for the selected language.
struct PluginLocalizedText: Codable, Equatable, Sendable {
    static let maximumTranslations = 16
    static let maximumLocaleIdentifierBytes = 64

    let fallback: String
    let translations: [String: String]

    init(fallback: String, translations: [String: String] = [:]) {
        self.fallback = fallback
        self.translations = translations
    }

    init(_ fallback: String, translations: [String: String] = [:]) {
        self.init(fallback: fallback, translations: translations)
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let value = try? singleValue.decode(String.self) {
            self.init(fallback: value)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fallback: try container.decode(String.self, forKey: .fallback),
            translations: try container.decodeIfPresent([String: String].self, forKey: .translations) ?? [:]
        )
    }

    func encode(to encoder: Encoder) throws {
        if translations.isEmpty {
            var container = encoder.singleValueContainer()
            try container.encode(fallback)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fallback, forKey: .fallback)
        try container.encode(translations, forKey: .translations)
    }

    func resolve(for language: AppLanguage) -> String {
        resolve(localeIdentifier: language.pluginLocaleIdentifier)
    }

    func resolve(localeIdentifier: String) -> String {
        let normalizedTarget = Self.normalizeLocaleIdentifier(localeIdentifier)
        let candidates = [
            normalizedTarget,
            Self.baseLanguage(of: normalizedTarget),
            "en"
        ].filter { !$0.isEmpty }

        for candidate in candidates {
            if let match = translations.first(where: {
                Self.normalizeLocaleIdentifier($0.key) == candidate
            }) {
                return match.value
            }
        }
        return fallback
    }

    /// Builds a localized string around a value produced from the provider's
    /// response. Every translation keeps the same dynamic value while using
    /// the translated prefix and suffix when available.
    static func composed(
        prefix: PluginLocalizedText?,
        value: String,
        suffix: PluginLocalizedText?
    ) -> PluginLocalizedText {
        let fallback = (prefix?.fallback ?? "") + value + (suffix?.fallback ?? "")
        let prefixLocales = prefix.map { Array($0.translations.keys) } ?? []
        let suffixLocales = suffix.map { Array($0.translations.keys) } ?? []
        let locales = Set(prefixLocales + suffixLocales)
        let translations = Dictionary(uniqueKeysWithValues: locales.map { locale in
            (
                locale,
                (prefix?.resolve(localeIdentifier: locale) ?? "")
                    + value
                    + (suffix?.resolve(localeIdentifier: locale) ?? "")
            )
        })
        return PluginLocalizedText(fallback: fallback, translations: translations)
    }

    private enum CodingKeys: String, CodingKey {
        case fallback
        case translations
    }

    private static func normalizeLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func baseLanguage(of identifier: String) -> String {
        identifier.split(separator: "-").first.map(String.init) ?? identifier
    }
}

enum PluginLocalizedTextValidation {
    /// Returns the first invalid schema path, or nil when the value is valid.
    static func invalidPath(
        _ value: PluginLocalizedText,
        path: String,
        maximumUTF8Length: Int,
        allowEmpty: Bool = false,
        trimWhitespace: Bool = false
    ) -> String? {
        guard value.translations.count <= PluginLocalizedText.maximumTranslations else {
            return "(path).translations"
        }
        guard validText(
            value.fallback,
            maximumUTF8Length: maximumUTF8Length,
            allowEmpty: allowEmpty,
            trimWhitespace: trimWhitespace
        ) else {
            return path
        }

        var normalizedLocales = Set<String>()
        for (locale, translation) in value.translations {
            guard validLocaleIdentifier(locale),
                  normalizedLocales.insert(locale.replacingOccurrences(of: "_", with: "-").lowercased()).inserted else {
                return "(path).translations"
            }
            guard validText(
                translation,
                maximumUTF8Length: maximumUTF8Length,
                allowEmpty: allowEmpty,
                trimWhitespace: trimWhitespace
            ) else {
                return "(path).translations.\(locale)"
            }
        }
        return nil
    }

    static func validLocaleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= PluginLocalizedText.maximumLocaleIdentifierBytes,
              !value.hasPrefix("-"),
              !value.hasSuffix("-"),
              !value.contains("--") else {
            return false
        }
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
        }
    }

    private static func validText(
        _ value: String,
        maximumUTF8Length: Int,
        allowEmpty: Bool,
        trimWhitespace: Bool
    ) -> Bool {
        guard (allowEmpty || !value.isEmpty),
              value.utf8.count <= maximumUTF8Length,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        if trimWhitespace && value != value.trimmingCharacters(in: .whitespacesAndNewlines) {
            return false
        }
        return true
    }
}

extension AppLanguage {
    var pluginLocaleIdentifier: String {
        switch resolved {
        case .chinese: return "zh-Hans"
        case .english, .system: return "en"
        }
    }
}
