import Foundation
import XCTest
@testable import MeterlarkApp

final class PluginConfigurationTests: XCTestCase {
    func testPluginConfigurationIsIsolatedByPluginIDAndRequiresJSONObject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.PluginConfigurationTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginConfigurationStore(baseURL: root)

        let gateway = Data("{\"endpoint\":\"https://example.test\"}".utf8)
        let other = Data("{\"enabled\":true}".utf8)
        try store.save(gateway, pluginID: "com.example.meterlark.gateway")
        try store.save(other, pluginID: "com.example.other")

        XCTAssertEqual(try store.load(pluginID: "com.example.meterlark.gateway"), gateway)
        XCTAssertEqual(try store.load(pluginID: "com.example.other"), other)
        XCTAssertNil(try store.load(pluginID: "com.example.missing"))
        XCTAssertThrowsError(try store.save(Data("[1,2,3]".utf8), pluginID: "com.example.other")) { error in
            XCTAssertEqual(error as? PluginConfigurationError, .invalidJSON)
        }
        for identifier in ["../escape", ".", "..", "com..example"] {
            XCTAssertThrowsError(try store.load(pluginID: identifier)) { error in
                XCTAssertEqual(error as? PluginConfigurationError, .invalidPluginIdentifier)
            }
        }
    }

    func testDeclarativeSchemaValidatesSupportedKindsAndRejectsSecretDefaults() throws {
        let schema = PluginConfigurationSchema(fields: [
            PluginConfigurationField(
                id: "endpoint",
                label: "Endpoint",
                kind: .url,
                required: true,
                defaultValue: .string("https://example.test")
            ),
            PluginConfigurationField(
                id: "enabled",
                label: "Enabled",
                kind: .boolean,
                defaultValue: .boolean(true)
            ),
            PluginConfigurationField(
                id: "mode",
                label: "Mode",
                kind: .choice,
                defaultValue: .string("daily"),
                options: [
                    PluginConfigurationOption(id: "daily", label: "Daily"),
                    PluginConfigurationOption(id: "monthly", label: "Monthly")
                ]
            ),
            PluginConfigurationField(id: "token", label: "Token", kind: .secret)
        ])

        XCTAssertNoThrow(try schema.validate())

        let effective = try schema.makeEffectiveValues(
            publicValues: ["mode": .string("monthly")],
            secretValues: ["token": "secret-value"]
        )
        XCTAssertEqual(effective["endpoint"], .string("https://example.test"))
        XCTAssertEqual(effective["mode"], .string("monthly"))
        XCTAssertEqual(effective["token"], .string("secret-value"))
        XCTAssertNoThrow(try schema.validateEffectiveValues(effective))
        XCTAssertThrowsError(
            try schema.validateEffectiveValues([
                "endpoint": .string("https://example.test"),
                "token": .string("secret-value"),
                "unknown": .boolean(true)
            ])
        ) { error in
            XCTAssertEqual(
                error as? PluginConfigurationSchemaError,
                .invalidValue("configuration.unknown")
            )
        }

        let invalid = PluginConfigurationSchema(fields: [
            PluginConfigurationField(
                id: "token",
                label: "Token",
                kind: .secret,
                defaultValue: .string("must-not-be-here")
            )
        ])
        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(error as? PluginConfigurationSchemaError, .secretDefault("token"))
        }
    }

    func testPublicValuesAndSecretsAreSeparatedAndMergedOnlyForRequests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.PluginConfigurationSchemaTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secrets = InMemorySecretStore()
        let store = PluginConfigurationStore(baseURL: root, secretStore: secrets)
        let schema = PluginConfigurationSchema(fields: [
            PluginConfigurationField(id: "endpoint", label: "Endpoint", kind: .url, required: true),
            PluginConfigurationField(id: "token", label: "Token", kind: .secret, required: true)
        ])

        try store.save(
            PluginConfigurationSubmission(
                publicValues: ["endpoint": .string("https://example.test")],
                secretValues: ["token": "secret-value"],
                clearSecretIDs: []
            ),
            pluginID: "com.example.plugin",
            schema: schema
        )

        let publicData = try XCTUnwrap(try store.load(pluginID: "com.example.plugin"))
        XCTAssertFalse(String(decoding: publicData, as: UTF8.self).contains("secret-value"))
        let draft = try store.loadDraft(pluginID: "com.example.plugin", schema: schema)
        XCTAssertEqual(draft.publicValues["endpoint"], .string("https://example.test"))
        XCTAssertEqual(draft.configuredSecretIDs, ["token"])

        let requestData = try XCTUnwrap(
            try store.loadEffectiveConfigurationData(
                pluginID: "com.example.plugin",
                schema: schema
            )
        )
        let request = try JSONDecoder().decode(PluginJSONValue.self, from: requestData)
        guard case let .object(values) = request else {
            return XCTFail("Expected an object configuration")
        }
        XCTAssertEqual(values["token"], .string("secret-value"))
    }

    func testSecretPersistenceFailureDoesNotCommitNewPublicConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.PluginConfigurationAtomicityTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let secrets = FaultingSecretStore()
        let store = PluginConfigurationStore(baseURL: root, secretStore: secrets)
        let schema = PluginConfigurationSchema(fields: [
            PluginConfigurationField(id: "endpoint", label: "Endpoint", kind: .url, required: true),
            PluginConfigurationField(id: "token", label: "Token", kind: .secret, required: true)
        ])

        try store.save(
            PluginConfigurationSubmission(
                publicValues: ["endpoint": .string("https://old.example")],
                secretValues: ["token": "old-secret"],
                clearSecretIDs: []
            ),
            pluginID: "com.example.plugin",
            schema: schema
        )

        secrets.failWrites = true
        XCTAssertThrowsError(
            try store.save(
                PluginConfigurationSubmission(
                    publicValues: ["endpoint": .string("https://new.example")],
                    secretValues: ["token": "new-secret"],
                    clearSecretIDs: []
                ),
                pluginID: "com.example.plugin",
                schema: schema
            )
        ) { error in
            XCTAssertEqual(error as? PluginConfigurationError, .secretPersistenceFailed)
        }

        let publicData = try XCTUnwrap(try store.load(pluginID: "com.example.plugin"))
        let publicValue = try JSONDecoder().decode(PluginJSONValue.self, from: publicData)
        guard case let .object(values) = publicValue else {
            return XCTFail("Expected an object configuration")
        }
        XCTAssertEqual(values["endpoint"], .string("https://old.example"))

        let effectiveData = try XCTUnwrap(
            try store.loadEffectiveConfigurationData(pluginID: "com.example.plugin", schema: schema)
        )
        let effective = try JSONDecoder().decode(PluginJSONValue.self, from: effectiveData)
        guard case let .object(effectiveValues) = effective else {
            return XCTFail("Expected an object configuration")
        }
        XCTAssertEqual(effectiveValues["token"], .string("old-secret"))
    }

    func testSecretDeletionFailureDoesNotRemovePublicConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.PluginConfigurationResetAtomicityTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let secrets = FaultingSecretStore()
        let store = PluginConfigurationStore(baseURL: root, secretStore: secrets)
        let schema = PluginConfigurationSchema(fields: [
            PluginConfigurationField(id: "endpoint", label: "Endpoint", kind: .url),
            PluginConfigurationField(id: "token", label: "Token", kind: .secret)
        ])
        try store.save(
            PluginConfigurationSubmission(
                publicValues: ["endpoint": .string("https://example.test")],
                secretValues: ["token": "secret-value"],
                clearSecretIDs: []
            ),
            pluginID: "com.example.plugin",
            schema: schema
        )

        secrets.failDeletes = true
        XCTAssertThrowsError(try store.removeConfiguration(pluginID: "com.example.plugin", schema: schema)) { error in
            XCTAssertEqual(error as? PluginConfigurationError, .secretPersistenceFailed)
        }
        XCTAssertNotNil(try store.load(pluginID: "com.example.plugin"))
        let effectiveData = try XCTUnwrap(
            try store.loadEffectiveConfigurationData(pluginID: "com.example.plugin", schema: schema)
        )
        let effective = try JSONDecoder().decode(PluginJSONValue.self, from: effectiveData)
        guard case let .object(values) = effective else {
            return XCTFail("Expected an object configuration")
        }
        XCTAssertEqual(values["token"], .string("secret-value"))
    }

    func testRequiredConfigurationDoesNotBecomeEffectiveUntilComplete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.PluginConfigurationRequiredTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = PluginConfigurationSchema(fields: [
            PluginConfigurationField(id: "token", label: "Token", kind: .secret, required: true)
        ])
        let store = PluginConfigurationStore(baseURL: root, secretStore: InMemorySecretStore())

        XCTAssertThrowsError(
            try store.loadEffectiveConfigurationData(
                pluginID: "com.example.plugin",
                schema: schema
            )
        ) { error in
            XCTAssertEqual(error as? PluginConfigurationSchemaError, .missingRequiredValue("token"))
        }
    }

    private final class InMemorySecretStore: PluginSecretStore, @unchecked Sendable {
        private(set) var values = [String: Data]()

        func read(service: String, account: String) throws -> Data? {
            values["\(service):\(account)"]
        }

        func write(_ data: Data, service: String, account: String) throws {
            values["\(service):\(account)"] = data
        }

        func delete(service: String, account: String) throws {
            values.removeValue(forKey: "\(service):\(account)")
        }
    }

    private final class FaultingSecretStore: PluginSecretStore, @unchecked Sendable {
        private var values = [String: Data]()
        var failWrites = false
        var failDeletes = false

        func read(service: String, account: String) throws -> Data? {
            values["\(service):\(account)"]
        }

        func write(_ data: Data, service: String, account: String) throws {
            if failWrites {
                throw PluginSecretStoreError.operationFailed(-1)
            }
            values["\(service):\(account)"] = data
        }

        func delete(service: String, account: String) throws {
            if failDeletes {
                throw PluginSecretStoreError.operationFailed(-1)
            }
            values.removeValue(forKey: "\(service):\(account)")
        }
    }
}
