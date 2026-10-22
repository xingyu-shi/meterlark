import Foundation
import XCTest
@testable import MeterlarkApp

final class PluginLocalizationTests: XCTestCase {
    func testLocalizedTextResolvesExactBaseEnglishAndFallbackInOrder() throws {
        let text = try JSONDecoder().decode(
            PluginLocalizedText.self,
            from: Data("""
            {
              "fallback": "Fallback",
              "translations": {
                "en": "English",
                "zh": "中文",
                "fr-FR": "Français"
              }
            }
            """.utf8)
        )

        XCTAssertEqual(text.resolve(for: .english), "English")
        XCTAssertEqual(text.resolve(for: .chinese), "中文")
        XCTAssertEqual(text.resolve(localeIdentifier: "fr-FR"), "Français")
        XCTAssertEqual(text.resolve(localeIdentifier: "de-DE"), "English")
    }

    func testLegacyStringsRemainValidAndLocalizedManifestConfigurationRoundTrips() throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data("""
            {
              "manifestVersion": 1,
              "id": "com.example.localized",
              "displayName": {
                "fallback": "Usage",
                "translations": { "zh-Hans": "用量" }
              },
              "version": "1.0.0",
              "protocolVersion": 1,
              "transport": "stdio-json",
              "entrypoint": "bin/usage",
              "configuration": {
                "version": 1,
                "title": {
                  "fallback": "Account",
                  "translations": { "zh-Hans": "账户" }
                },
                "fields": [{
                  "id": "token",
                  "label": {
                    "fallback": "Token",
                    "translations": { "zh-Hans": "令牌" }
                  },
                  "kind": "secret",
                  "required": true,
                  "placeholder": {
                    "fallback": "Enter token",
                    "translations": { "zh-Hans": "输入令牌" }
                  }
                }]
              }
            }
            """.utf8)
        )

        XCTAssertNoThrow(try manifest.validate())
        XCTAssertEqual(manifest.displayName, "Usage")
        XCTAssertEqual(manifest.localizedDisplayName(for: .chinese), "用量")
        XCTAssertEqual(manifest.configuration?.localizedTitle(for: .chinese), "账户")
        XCTAssertEqual(
            manifest.configuration?.fields[0].localizedPlaceholder(for: .chinese),
            "输入令牌"
        )

        let roundTripped = try JSONDecoder().decode(
            PluginManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        XCTAssertEqual(roundTripped, manifest)

        let legacy = try JSONDecoder().decode(
            PluginLocalizedText.self,
            from: Data("\"Only English\"".utf8)
        )
        XCTAssertEqual(legacy.resolve(for: .chinese), "Only English")
    }

    func testInvalidLocalizedTextIsRejectedByPluginManifestValidation() throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data("""
            {
              "manifestVersion": 1,
              "id": "com.example.localized",
              "displayName": {
                "fallback": "Usage",
                "translations": { "zh--Hans": "用量" }
              },
              "version": "1.0.0",
              "protocolVersion": 1
            }
            """.utf8)
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .invalidDisplayName)
        }
    }
}
