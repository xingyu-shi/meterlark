import Foundation
import XCTest
@testable import MeterlarkApp

final class HTTPJSONPluginTests: XCTestCase {
    func testExampleGatewayManifestIsManifestOnlyAndUsesTheHostContract() throws {
        let manifest = try loadExampleGatewayManifest()

        XCTAssertEqual(manifest.displayName, "Example Gateway")
        XCTAssertEqual(
            manifest.localizedDisplayName(for: .chinese),
            "Example Gateway"
        )
        XCTAssertEqual(manifest.configuration?.title, "Example Gateway")
        XCTAssertEqual(
            manifest.configuration?.localizedTitle(for: .chinese),
            "Example Gateway"
        )
        XCTAssertEqual(manifest.transport, .httpJSON)
        XCTAssertNil(manifest.entrypoint)
        XCTAssertEqual(manifest.http?.method, .get)
        XCTAssertEqual(manifest.http?.urlField, "endpoint")
        XCTAssertEqual(manifest.version, "1.0.1")
        XCTAssertEqual(manifest.protocolVersion, 2)
        XCTAssertEqual(manifest.http?.headers.map(\.name), ["Accept"])
        XCTAssertEqual(manifest.http?.auth?.encoding, .json)
        XCTAssertEqual(manifest.http?.auth?.refreshTokenParameter, "refresh")
        XCTAssertEqual(manifest.http?.auth?.headerMode, .raw)
        XCTAssertEqual(manifest.http?.auth?.tokenExpiredStatusCodes, [400, 401])
        XCTAssertEqual(manifest.dashboard?.blocks.count, 2)
        XCTAssertNoThrow(try manifest.validate())

        let package = repoRoot().appendingPathComponent("Examples/Plugins/Gateway", isDirectory: true)
        let validated = try PluginPackageValidator().validate(packageURL: package)
        XCTAssertEqual(validated.manifest, manifest)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: package,
                includingPropertiesForKeys: [],
                options: [.skipsHiddenFiles]
            ).map(\.lastPathComponent),
            ["plugin.json"]
        )
        let manifestText = String(
            decoding: try Data(contentsOf: package.appendingPathComponent("plugin.json")),
            as: UTF8.self
        )
        XCTAssertFalse(manifestText.contains("secret-value"))
    }

    func testRefreshManifestRequiresProtocolV2AndOlderHostsRejectIt() throws {
        let manifest = try loadExampleGatewayManifest()
        XCTAssertThrowsError(try manifest.validate(supportedProtocolVersion: 1)) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .unsupportedProtocolVersion(2))
        }

        let protocolOne = PluginManifest(
            manifestVersion: manifest.manifestVersion,
            id: manifest.id,
            displayName: manifest.displayName,
            version: manifest.version,
            protocolVersion: 1,
            transport: manifest.transport,
            configuration: manifest.configuration,
            http: manifest.http,
            dashboard: manifest.dashboard,
            localizedDisplayName: manifest.displayNameText
        )
        XCTAssertThrowsError(try protocolOne.validate()) { error in
            XCTAssertEqual(error as? PluginManifestValidationError, .tokenRefreshRequiresProtocolV2)
        }
    }

    func testJSONPointerResolvesEscapedObjectKeysAndRejectsMalformedEscapes() throws {
        let root: PluginJSONValue = .object([
            "a/b": .object(["~key": .integer(7)])
        ])

        XCTAssertEqual(
            PluginJSONPointer.resolve(path: "/a~1b/~0key", in: root),
            .integer(7)
        )
        let array: PluginJSONValue = .array([.string("first"), .string("second")])
        XCTAssertNil(PluginJSONPointer.resolve(path: "/01", in: array))
        XCTAssertEqual(PluginJSONPointer.resolve(path: "/1", in: array), .string("second"))
        XCTAssertThrowsError(
            try PluginHTTPJSONValidation.pointer("/a~2b", path: "response.path")
        ) { error in
            XCTAssertEqual(error as? PluginHTTPJSONSchemaError, .invalid("response.path"))
        }
    }

    func testHTTPJSONProviderBuildsRequestAndMapsCompleteExampleGatewayResponse() async throws {
        let manifest = try staticManifest()
        let recorder = RequestRecorder()
        let body = """
        {
          "code": 0,
          "message": "Success",
          "data": {
            "username": "xingyus",
            "today_cost": 6.81,
            "daily_quota": 100,
            "daily_remaining_quota": 93.19,
            "monthly_cost": 77.06,
            "monthly_quota": 300,
            "monthly_remaining_quota": 222.94
          },
          "success": true
        }
        """
        let sender: HTTPJSONPluginProvider.RequestSender = { request in
            await recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }
        let provider = try HTTPJSONPluginProvider(
            manifest: manifest,
            configurationData: configurationData(endpoint: "https://api.example.test", token: "secret-value"),
            send: sender
        )

        let document = try await provider.fetchDashboard()
        _ = try document.makeModel(for: manifest)

        let recordedRequest = await recorder.request
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test")
        XCTAssertEqual(request.timeoutInterval, 20, accuracy: 0.001)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "secret-value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        guard case let .metricGrid(grid) = document.blocks[0] else {
            return XCTFail("Expected the summary metric grid first")
        }
        XCTAssertEqual(grid.columns, 2)
        XCTAssertEqual(grid.tiles.count, 4)
        XCTAssertEqual(grid.tiles[0].primary.kind, .currency)
        XCTAssertEqual(grid.tiles[0].primary.display.text, "$6.81")

        guard case let .progressList(list) = document.blocks[1] else {
            return XCTFail("Expected the quota progress list second")
        }
        XCTAssertEqual(list.header.subtitle?.text, "Account: xingyus")
        guard case let .progress(daily) = list.items[0] else {
            return XCTFail("Expected a derived daily progress row")
        }
        XCTAssertEqual(daily.current, 6.81, accuracy: 0.0001)
        XCTAssertEqual(daily.maximum, 100, accuracy: 0.0001)
        XCTAssertEqual(daily.status.kind, .normal)

        let chinese = try document.makeModel(for: manifest, language: .chinese)
        guard case let .metricGrid(_, chineseGrid) = chinese.blocks[0],
              case let .progressList(_, chineseList) = chinese.blocks[1] else {
            return XCTFail("Expected the ExampleGateway dashboard blocks")
        }
        XCTAssertEqual(chineseGrid.tiles[0].header.text, "今日费用")
        XCTAssertEqual(chineseGrid.tiles[0].detail?.text, "每日额度：$100")
        XCTAssertEqual(chineseList.header.title.text, "额度")
        XCTAssertEqual(chineseList.header.subtitle?.text, "账户：xingyus")
        guard case let .progress(chineseDaily) = chineseList.items[0] else {
            return XCTFail("Expected a Chinese daily progress row")
        }
        XCTAssertEqual(chineseDaily.label.text, "每日额度")
    }

    func testHTTPJSONStatusRuleMapsAReachedQuotaToAlert() async throws {
        let provider = try makeProvider(
            manifest: try staticManifest(),
            body: """
            {
              "code": 0,
              "success": true,
              "data": {
                "today_cost": 100,
                "daily_quota": 100,
                "monthly_cost": 301,
                "monthly_quota": 300
              }
            }
            """
        )

        let document = try await provider.fetchDashboard()
        guard case let .progressList(list) = document.blocks[1],
              case let .progress(daily) = list.items[0],
              case let .progress(monthly) = list.items[1] else {
            return XCTFail("Expected progress rows for both quotas")
        }
        XCTAssertEqual(daily.status.kind, .alert)
        XCTAssertEqual(monthly.status.kind, .alert)
    }

    func testHTTPJSONProviderPreservesExplicitMissingDataSemantics() async throws {
        let manifest = try staticManifest()
        let body = """
        { "code": 0, "success": true, "data": { "username": "xingyus" } }
        """
        let provider = try makeProvider(manifest: manifest, body: body)

        let document = try await provider.fetchDashboard()
        guard case let .metricGrid(grid) = document.blocks[0] else {
            return XCTFail("Expected a metric grid")
        }
        XCTAssertEqual(grid.tiles[0].primary.kind, .text)
        XCTAssertEqual(grid.tiles[0].primary.display.text, "—")

        guard case let .progressList(list) = document.blocks[1] else {
            return XCTFail("Expected a progress list")
        }
        guard case .status = list.items[0], case .status = list.items[1] else {
            return XCTFail("Missing maximum values must become status rows")
        }
    }

    func testHTTPJSONProviderRejectsUnsafeEndpointConditionsAndOversizedResponse() async throws {
        let manifest = try staticManifest()

        do {
            _ = try makeProvider(
                manifest: manifest,
                body: "{}",
                endpoint: "http://api.example.test"
            )
            XCTFail("Expected an insecure endpoint to be rejected")
        } catch {
            XCTAssertEqual(error as? HTTPJSONPluginError, .insecureURL)
        }

        let failedConditions = try makeProvider(
            manifest: manifest,
            body: "{\"code\":1,\"success\":false}"
        )
        do {
            _ = try await failedConditions.fetchDashboard()
            XCTFail("Expected response conditions to fail")
        } catch {
            XCTAssertEqual(error as? HTTPJSONPluginError, .responseConditionFailed)
        }

        let oversized = try makeProvider(
            manifest: manifest,
            body: String(repeating: "x", count: 128),
            maximumResponseBytes: 32
        )
        do {
            _ = try await oversized.fetchDashboard()
            XCTFail("Expected the response-size limit to be enforced")
        } catch {
            XCTAssertEqual(error as? HTTPJSONPluginError, .responseTooLarge)
        }
    }

    func testHTTPManifestRejectsAnInsecureDefaultEndpoint() throws {
        let source = try Data(contentsOf: repoRoot().appendingPathComponent("Examples/Plugins/Gateway/plugin.json"))
        let insecureText = String(decoding: source, as: UTF8.self)
            .replacingOccurrences(
                of: "https://gateway.example.test/v1/cost/current",
                with: "http://gateway.example.test/prod/aicost/api/v1/cost/current"
            )
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(insecureText.utf8))

        XCTAssertThrowsError(try manifest.validate()) { error in
            guard case let .invalidHTTPDefinition(detail) = error as? PluginManifestValidationError else {
                return XCTFail("Expected an HTTP definition validation error, got \(error)")
            }
            XCTAssertTrue(detail.contains("defaultValue"))
        }
    }

    func testHTTPManifestRequiresAConfiguredURLField() throws {
        let source = try staticManifest()
        let schema = PluginConfigurationSchema(fields: [
            PluginConfigurationField(
                id: "endpoint",
                label: "Endpoint",
                kind: .url
            ),
            PluginConfigurationField(
                id: "token",
                label: "Authorization",
                kind: .secret,
                required: true
            )
        ])
        let manifest = PluginManifest(
            manifestVersion: source.manifestVersion,
            id: source.id,
            displayName: source.displayName,
            version: source.version,
            protocolVersion: source.protocolVersion,
            transport: .httpJSON,
            configuration: schema,
            http: source.http,
            dashboard: source.dashboard
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            guard case let .invalidHTTPDefinition(detail) = error as? PluginManifestValidationError else {
                return XCTFail("Expected an HTTP definition validation error, got \(error)")
            }
            XCTAssertTrue(detail.contains("urlField"))
        }
    }

    func testHTTPRedirectPolicyAllowsOnlyTheSameHTTPSOrigin() {
        let origin = URL(string: "https://api.example.test/v1/current")!
        XCTAssertTrue(
            HTTPJSONRedirectPolicy.sameOrigin(
                origin,
                URL(string: "https://api.example.test/v1/next")!
            )
        )
        XCTAssertFalse(
            HTTPJSONRedirectPolicy.sameOrigin(
                origin,
                URL(string: "https://other.example.test/v1/next")!
            )
        )
        XCTAssertFalse(
            HTTPJSONRedirectPolicy.sameOrigin(
                origin,
                URL(string: "http://api.example.test/v1/next")!
            )
        )
        XCTAssertFalse(
            HTTPJSONRedirectPolicy.sameOrigin(
                origin,
                URL(string: "https://api.example.test:8443/v1/next")!
            )
        )
    }

    func testHTTPProviderReturnsSafeErrorsForHTTPStatusAndMalformedJSON() async throws {
        let manifest = try staticManifest()

        let unauthorized = try makeProvider(
            manifest: manifest,
            body: "{\"message\":\"do not expose credentials\"}",
            statusCode: 401
        )
        do {
            _ = try await unauthorized.fetchDashboard()
            XCTFail("Expected HTTP status failure")
        } catch {
            XCTAssertEqual(error as? HTTPJSONPluginError, .httpStatus(401))
            XCTAssertFalse(error.localizedDescription.contains("secret-value"))
        }

        let malformed = try makeProvider(
            manifest: manifest,
            body: "not-json"
        )
        do {
            _ = try await malformed.fetchDashboard()
            XCTFail("Expected malformed JSON failure")
        } catch {
            XCTAssertEqual(error as? HTTPJSONPluginError, .invalidJSON)
        }
    }

    func testOAuthRefreshUsesFormBodyBearerHeaderAndCachesValidToken() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access_token\":\"access-1\",\"refresh_token\":\"refresh-2\",\"expires_in\":3600}"),
            .init(body: dashboardBody()),
            .init(body: dashboardBody())
        ])
        let store = InMemoryRefreshCredentialStore()
        let now = Date(timeIntervalSince1970: 1_000)
        let provider = try makeAuthProvider(
            manifest: try standardOAuthManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-1",
                clientID: "client-1",
                clientSecret: "client-secret",
                scope: "cost.read"
            ),
            server: server,
            store: store,
            now: now
        )

        _ = try await provider.fetchDashboard()
        _ = try await provider.fetchDashboard()

        let requests = await server.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.example.test/token")
        XCTAssertEqual(
            String(data: try XCTUnwrap(requests[0].httpBody), encoding: .utf8),
            "refresh_token=refresh-1&grant_type=refresh_token&client_id=client-1&client_secret=client-secret&scope=cost.read"
        )
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded"
        )
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "Authorization"),
            "Bearer access-1"
        )
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "Authorization"),
            "Bearer access-1"
        )
        XCTAssertEqual(store.value(pluginID: "com.example.oauth", fieldID: "refreshToken"), "refresh-2")
    }

    func testExpirySkewRefreshesAnAccessTokenBeforeItsProviderTTL() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access_token\":\"access-near-expiry\",\"expires_in\":100}"),
            .init(body: dashboardBody()),
            .init(body: "{\"access_token\":\"access-renewed\",\"expires_in\":3600}"),
            .init(body: dashboardBody())
        ])
        let provider = try makeAuthProvider(
            manifest: try standardOAuthManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-skew",
                clientID: "client-1",
                clientSecret: "client-secret",
                scope: "cost.read"
            ),
            server: server,
            store: InMemoryRefreshCredentialStore(),
            now: Date(timeIntervalSince1970: 8_000)
        )

        _ = try await provider.fetchDashboard()
        _ = try await provider.fetchDashboard()

        let requests = await server.requests()
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "token" }.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer access-near-expiry")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer access-renewed")
    }

    func testExampleGatewayRefreshUsesJSONProviderParameterRawHeaderAndRotation() async throws {
        // The ExampleGateway UIM refresh contract is JSON {"refresh": ...} and returns
        // top-level {"access": ..., "refresh": ...}; it has no expiry field.
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access\":\"example-gateway-access\",\"refresh\":\"example-gateway-refresh-2\"}"),
            .init(body: dashboardBody())
        ])
        let store = InMemoryRefreshCredentialStore()
        let provider = try makeAuthProvider(
            manifest: try loadExampleGatewayManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "example-gateway-refresh-1"
            ),
            server: server,
            store: store,
            now: Date(timeIntervalSince1970: 2_000)
        )

        _ = try await provider.fetchDashboard()

        let requests = await server.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(
            try JSONDecoder().decode(PluginJSONValue.self, from: try XCTUnwrap(requests[0].httpBody)),
            .object(["refresh": .string("example-gateway-refresh-1")])
        )
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "Authorization"),
            "example-gateway-access"
        )
        XCTAssertEqual(
            store.value(pluginID: "com.example.meterlark.gateway", fieldID: "refreshToken"),
            "example-gateway-refresh-2"
        )
        let manifest = try loadExampleGatewayManifest()
        XCTAssertEqual(manifest.http?.auth?.accessTokenPath, "/access")
        XCTAssertEqual(manifest.http?.auth?.refreshTokenPath, "/refresh")
        XCTAssertNil(manifest.http?.auth?.expiresInPath)
    }

    func testExampleGatewayExpiredDataResponseRefreshesAfter400AndPersistsRotation() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access\":\"access-1\",\"refresh\":\"refresh-2\"}"),
            .init(body: dashboardBody()),
            .init(body: "{\"message\":\"invalid token: token is malformed\"}", statusCode: 400),
            .init(body: "{\"access\":\"access-2\",\"refresh\":\"refresh-3\"}"),
            .init(body: dashboardBody())
        ])
        let store = InMemoryRefreshCredentialStore()
        let provider = try makeAuthProvider(
            manifest: try loadExampleGatewayManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-1"
            ),
            server: server,
            store: store,
            now: Date(timeIntervalSince1970: 2_500)
        )

        _ = try await provider.fetchDashboard()
        _ = try await provider.fetchDashboard()

        let requests = await server.requests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(
            requests.map { $0.url?.lastPathComponent },
            ["token", "data", "data", "token", "data"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(PluginJSONValue.self, from: XCTUnwrap(requests[0].httpBody)),
            .object(["refresh": .string("refresh-1")])
        )
        XCTAssertEqual(
            try JSONDecoder().decode(PluginJSONValue.self, from: XCTUnwrap(requests[3].httpBody)),
            .object(["refresh": .string("refresh-2")])
        )
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "access-1")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "access-1")
        XCTAssertEqual(requests[4].value(forHTTPHeaderField: "Authorization"), "access-2")
        XCTAssertEqual(
            store.value(pluginID: "com.example.meterlark.gateway", fieldID: "refreshToken"),
            "refresh-3"
        )
    }

    func testExampleGatewayPersistent400DoesNotRefreshMoreThanOncePerFetch() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access\":\"access-1\",\"refresh\":\"refresh-2\"}"),
            .init(body: dashboardBody()),
            .init(body: "{\"message\":\"invalid token\"}", statusCode: 400),
            .init(body: "{\"access\":\"access-2\",\"refresh\":\"refresh-3\"}"),
            .init(body: "{\"message\":\"invalid token\"}", statusCode: 400)
        ])
        let provider = try makeAuthProvider(
            manifest: try loadExampleGatewayManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-1"
            ),
            server: server,
            store: InMemoryRefreshCredentialStore(),
            now: Date(timeIntervalSince1970: 2_600)
        )

        _ = try await provider.fetchDashboard()
        do {
            _ = try await provider.fetchDashboard()
            XCTFail("Expected the second 400 response to fail")
        } catch {
            XCTAssertEqual(error as? HTTPJSONPluginError, .httpStatus(400))
        }

        let requests = await server.requests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "token" }.count, 2)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "access-1")
        XCTAssertEqual(requests[4].value(forHTTPHeaderField: "Authorization"), "access-2")
    }

    func testExampleGatewayPermissionFailureDoesNotTriggerRefresh() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access\":\"access-permission\",\"refresh\":\"refresh-2\"}"),
            .init(body: "{\"message\":\"forbidden\"}", statusCode: 403)
        ])
        let provider = try makeAuthProvider(
            manifest: try loadExampleGatewayManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-1"
            ),
            server: server,
            store: InMemoryRefreshCredentialStore(),
            now: Date(timeIntervalSince1970: 2_700)
        )

        do {
            _ = try await provider.fetchDashboard()
            XCTFail("Expected a permission failure")
        } catch {
            XCTAssertEqual(error as? HTTPJSONPluginError, .permissionDenied)
        }

        let requests = await server.requests()
        XCTAssertEqual(requests.count, 2)
    }

    func testConcurrentFetchesShareOneRefreshExchange() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access_token\":\"access-concurrent\",\"expires_in\":3600}", delayNanoseconds: 50_000_000),
            .init(body: dashboardBody()),
            .init(body: dashboardBody())
        ])
        let provider = try makeAuthProvider(
            manifest: try standardOAuthManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-concurrent",
                clientID: "client-1",
                clientSecret: "client-secret",
                scope: "cost.read"
            ),
            server: server,
            store: InMemoryRefreshCredentialStore(),
            now: Date(timeIntervalSince1970: 3_000)
        )

        async let first = provider.fetchDashboard()
        async let second = provider.fetchDashboard()
        _ = try await (first, second)

        let requests = await server.requests()
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "token" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "data" }.count, 2)
    }

    func testProviderReconstructionReusesTheRegistryOwnedSession() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access_token\":\"access-reused\",\"expires_in\":3600}"),
            .init(body: dashboardBody()),
            .init(body: dashboardBody())
        ])
        let registry = HTTPJSONAuthSessionRegistry()
        let configuration = oauthConfigurationData(
            endpoint: "https://api.example.test/data",
            refreshEndpoint: "https://api.example.test/token",
            refreshToken: "refresh-reused",
            clientID: "client-1",
            clientSecret: "client-secret",
            scope: "cost.read"
        )
        let manifest = try standardOAuthManifest()
        let store = InMemoryRefreshCredentialStore()
        let first = try makeAuthProvider(
            manifest: manifest,
            configurationData: configuration,
            server: server,
            store: store,
            now: Date(timeIntervalSince1970: 9_000),
            registry: registry
        )
        _ = try await first.fetchDashboard()

        let second = try makeAuthProvider(
            manifest: manifest,
            configurationData: configuration,
            server: server,
            store: store,
            now: Date(timeIntervalSince1970: 9_000),
            registry: registry
        )
        _ = try await second.fetchDashboard()

        let requests = await server.requests()
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "token" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "data" }.count, 2)
    }

    func testProviderReconstructionAfterRotationKeepsTheCachedAccessToken() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access_token\":\"access-rotated\",\"refresh_token\":\"refresh-2\",\"expires_in\":3600}"),
            .init(body: dashboardBody()),
            .init(body: dashboardBody())
        ])
        let registry = HTTPJSONAuthSessionRegistry()
        let store = InMemoryRefreshCredentialStore()
        let manifest = try standardOAuthManifest()

        let first = try makeAuthProvider(
            manifest: manifest,
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-1",
                clientID: "client-1",
                clientSecret: "client-secret",
                scope: "cost.read"
            ),
            server: server,
            store: store,
            now: Date(timeIntervalSince1970: 9_500),
            registry: registry
        )
        _ = try await first.fetchDashboard()

        let second = try makeAuthProvider(
            manifest: manifest,
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-2",
                clientID: "client-1",
                clientSecret: "client-secret",
                scope: "cost.read"
            ),
            server: server,
            store: store,
            now: Date(timeIntervalSince1970: 9_500),
            registry: registry
        )
        _ = try await second.fetchDashboard()

        let requests = await server.requests()
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "token" }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "data" }.count, 2)
        XCTAssertEqual(store.value(pluginID: "com.example.oauth", fieldID: "refreshToken"), "refresh-2")
    }

    func testRefreshEndpointMustBeHTTPSBeforeProviderConstruction() throws {
        let server = ScriptedRequestServer(replies: [])
        let store = InMemoryRefreshCredentialStore()

        XCTAssertThrowsError(
            try makeAuthProvider(
                manifest: try standardOAuthManifest(),
                configurationData: oauthConfigurationData(
                    endpoint: "https://api.example.test/data",
                    refreshEndpoint: "http://api.example.test/token",
                    refreshToken: "refresh-insecure",
                    clientID: "client-1",
                    clientSecret: "client-secret",
                    scope: "cost.read"
                ),
                server: server,
                store: store,
                now: Date(timeIntervalSince1970: 9_600)
            )
        ) { error in
            XCTAssertEqual(error as? HTTPJSONPluginError, .insecureURL)
        }
    }

    func testExpiredDataResponseRefreshesOnceAndRetriesTheGET() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access_token\":\"access-1\",\"expires_in\":3600}"),
            .init(body: "{\"message\":\"expired\"}", statusCode: 401),
            .init(body: "{\"access_token\":\"access-2\",\"expires_in\":3600}"),
            .init(body: dashboardBody())
        ])
        let provider = try makeAuthProvider(
            manifest: try standardOAuthManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-retry",
                clientID: "client-1",
                clientSecret: "client-secret",
                scope: "cost.read"
            ),
            server: server,
            store: InMemoryRefreshCredentialStore(),
            now: Date(timeIntervalSince1970: 4_000)
        )

        _ = try await provider.fetchDashboard()

        let requests = await server.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer access-2")
    }

    func testPermissionFailureDoesNotTriggerRefresh() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access_token\":\"access-permission\",\"expires_in\":3600}"),
            .init(body: "{\"message\":\"forbidden\"}", statusCode: 403)
        ])
        let provider = try makeAuthProvider(
            manifest: try standardOAuthManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-permission",
                clientID: "client-1",
                clientSecret: "client-secret",
                scope: "cost.read"
            ),
            server: server,
            store: InMemoryRefreshCredentialStore(),
            now: Date(timeIntervalSince1970: 5_000)
        )

        do {
            _ = try await provider.fetchDashboard()
            XCTFail("Expected a permission failure")
        } catch {
            XCTAssertEqual(error as? HTTPJSONPluginError, .permissionDenied)
        }
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 2)
    }

    func testTransientRefreshFailureUsesBoundedBackoff() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "temporary", statusCode: 500),
            .init(body: "should-not-be-requested", statusCode: 200)
        ])
        let provider = try makeAuthProvider(
            manifest: try standardOAuthManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-backoff",
                clientID: "client-1",
                clientSecret: "client-secret",
                scope: "cost.read"
            ),
            server: server,
            store: InMemoryRefreshCredentialStore(),
            now: Date(timeIntervalSince1970: 6_000)
        )

        for _ in 0..<2 {
            do {
                _ = try await provider.fetchDashboard()
                XCTFail("Expected a temporary refresh failure")
            } catch {
                XCTAssertEqual(error as? HTTPJSONPluginError, .temporarilyUnavailable)
            }
        }
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testRefreshCredentialWriteFailurePublishesNoNewAccessToken() async throws {
        let server = ScriptedRequestServer(replies: [
            .init(body: "{\"access_token\":\"must-not-be-used\",\"refresh_token\":\"replacement\",\"expires_in\":3600}")
        ])
        let store = InMemoryRefreshCredentialStore(failsWrites: true)
        let provider = try makeAuthProvider(
            manifest: try standardOAuthManifest(),
            configurationData: oauthConfigurationData(
                endpoint: "https://api.example.test/data",
                refreshEndpoint: "https://api.example.test/token",
                refreshToken: "refresh-original",
                clientID: "client-1",
                clientSecret: "client-secret",
                scope: "cost.read"
            ),
            server: server,
            store: store,
            now: Date(timeIntervalSince1970: 7_000)
        )

        for _ in 0..<2 {
            do {
                _ = try await provider.fetchDashboard()
                XCTFail("Expected the credential persistence failure")
            } catch {
                XCTAssertEqual(error as? HTTPJSONPluginError, .authenticationRequired)
                XCTAssertFalse(error.localizedDescription.contains("must-not-be-used"))
            }
        }
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(store.value(pluginID: "com.example.oauth", fieldID: "refreshToken"))
    }

    func testAuthParameterCollisionIsRejectedBeforeRequestConstruction() throws {
        let source = try standardOAuthManifest()
        let sourceHTTP = try XCTUnwrap(source.http)
        let sourceAuth = try XCTUnwrap(sourceHTTP.auth)
        let fields = try XCTUnwrap(source.configuration?.fields)
        let collidingAuth = PluginHTTPJSONAuthDefinition(
            refreshURLField: sourceAuth.refreshURLField,
            refreshTokenField: sourceAuth.refreshTokenField,
            encoding: sourceAuth.encoding,
            refreshTokenParameter: "client_id",
            grantTypeParameter: sourceAuth.grantTypeParameter,
            grantTypeValue: sourceAuth.grantTypeValue,
            clientIDField: sourceAuth.clientIDField,
            clientSecretField: sourceAuth.clientSecretField,
            scopeField: sourceAuth.scopeField,
            accessTokenPath: sourceAuth.accessTokenPath,
            refreshTokenPath: sourceAuth.refreshTokenPath,
            expiresInPath: sourceAuth.expiresInPath,
            accessTokenHeader: sourceAuth.accessTokenHeader,
            headerMode: sourceAuth.headerMode,
            timeoutSeconds: sourceAuth.timeoutSeconds,
            expirySkewSeconds: sourceAuth.expirySkewSeconds,
            missingExpiryPolicy: sourceAuth.missingExpiryPolicy,
            fallbackTTLSeconds: sourceAuth.fallbackTTLSeconds,
            tokenExpiredStatusCodes: sourceAuth.tokenExpiredStatusCodes,
            tokenExpiredConditions: sourceAuth.tokenExpiredConditions
        )
        let manifest = PluginManifest(
            manifestVersion: source.manifestVersion,
            id: source.id,
            displayName: source.displayName,
            version: source.version,
            protocolVersion: source.protocolVersion,
            transport: source.transport,
            configuration: PluginConfigurationSchema(
                version: source.configuration?.version ?? 1,
                fields: fields
            ),
            http: PluginHTTPJSONDefinition(
                method: sourceHTTP.method,
                urlField: sourceHTTP.urlField,
                headers: sourceHTTP.headers,
                timeoutSeconds: sourceHTTP.timeoutSeconds,
                conditions: sourceHTTP.conditions,
                auth: collidingAuth
            ),
            dashboard: source.dashboard,
            localizedDisplayName: source.displayNameText
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            guard case let .invalidHTTPDefinition(detail) = error as? PluginManifestValidationError else {
                return XCTFail("Expected an invalid HTTP definition, got \(error)")
            }
            XCTAssertTrue(detail.contains("clientIDField"))
        }
    }

    func testConfigurationResetDeletesTheRotatedRefreshCredentialAccount() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.HTTPJSONResetTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let secretStore = InMemorySecretStore()
        let configurationStore = PluginConfigurationStore(
            baseURL: root.appendingPathComponent("config", isDirectory: true),
            secretStore: secretStore
        )
        let schema = try XCTUnwrap(try standardOAuthManifest().configuration)
        try configurationStore.save(
            PluginConfigurationSubmission(
                publicValues: [
                    "endpoint": .string("https://api.example.test/data"),
                    "refreshEndpoint": .string("https://api.example.test/token"),
                    "clientID": .string("client-1"),
                    "scope": .string("cost.read")
                ],
                secretValues: [
                    "refreshToken": "refresh-original",
                    "clientSecret": "client-secret"
                ],
                clearSecretIDs: []
            ),
            pluginID: "com.example.oauth",
            schema: schema
        )

        let credentialStore = PluginConfigurationCredentialStore(secretStore: secretStore)
        try credentialStore.write(
            "refresh-rotated",
            pluginID: "com.example.oauth",
            fieldID: "refreshToken"
        )
        XCTAssertEqual(
            try credentialStore.read(pluginID: "com.example.oauth", fieldID: "refreshToken"),
            "refresh-rotated"
        )

        try configurationStore.removeConfiguration(
            pluginID: "com.example.oauth",
            schema: schema
        )
        XCTAssertNil(try credentialStore.read(pluginID: "com.example.oauth", fieldID: "refreshToken"))
        XCTAssertNil(try credentialStore.read(pluginID: "com.example.oauth", fieldID: "clientSecret"))
    }

    func testRegistryInstallsConfiguresAndConstructsManifestOnlyHTTPProvider() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.HTTPJSONRegistryTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let installRoot = root.appendingPathComponent("Plugins", isDirectory: true)
        let configurationRoot = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifestData = try Data(contentsOf: repoRoot().appendingPathComponent("Examples/Plugins/Gateway/plugin.json"))
        try manifestData.write(to: source.appendingPathComponent("plugin.json"))

        let secrets = InMemorySecretStore()
        let registry = ExternalPluginRegistry(
            catalog: PluginCatalog(rootURL: installRoot),
            activationStore: PluginActivationStore(fileURL: root.appendingPathComponent("activations.json")),
            configurationStore: PluginConfigurationStore(
                baseURL: configurationRoot,
                secretStore: secrets
            )
        )

        _ = try registry.install(from: source)
        let initial = try XCTUnwrap(registry.discover().first)
        XCTAssertEqual(initial.manifest.transport, .httpJSON)
        XCTAssertFalse(initial.isValid)

        try registry.saveConfiguration(
            pluginID: initial.id,
            submission: PluginConfigurationSubmission(
                publicValues: [
                    "endpoint": .string("https://api.example.test")
                ],
                secretValues: ["refreshToken": "refresh-token"],
                clearSecretIDs: []
            )
        )
        try registry.setEnabled(true, pluginID: initial.id)

        let providers = registry.enabledProviders()
        XCTAssertEqual(providers.count, 1)
        XCTAssertTrue(providers[0] is HTTPJSONPluginProvider)
    }

    func testRegistryRejectsAnInsecureConfiguredEndpointBeforeActivation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meterlark.HTTPJSONInsecureRegistryTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let installRoot = root.appendingPathComponent("Plugins", isDirectory: true)
        let configurationRoot = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifestData = try Data(contentsOf: repoRoot().appendingPathComponent("Examples/Plugins/Gateway/plugin.json"))
        try manifestData.write(to: source.appendingPathComponent("plugin.json"))

        let registry = ExternalPluginRegistry(
            catalog: PluginCatalog(rootURL: installRoot),
            activationStore: PluginActivationStore(fileURL: root.appendingPathComponent("activations.json")),
            configurationStore: PluginConfigurationStore(
                baseURL: configurationRoot,
                secretStore: InMemorySecretStore()
            )
        )
        _ = try registry.install(from: source)
        let pluginID = "com.example.meterlark.gateway"

        try registry.saveConfiguration(
            pluginID: pluginID,
            submission: PluginConfigurationSubmission(
                publicValues: ["endpoint": .string("http://api.example.test")],
                secretValues: ["refreshToken": "refresh-token"],
                clearSecretIDs: []
            )
        )

        let record = try XCTUnwrap(registry.discover().first)
        XCTAssertFalse(record.isValid)
        XCTAssertNil(record.validationMessage)
        XCTAssertTrue(record.configurationValidationMessage?.contains("HTTPS") == true)
        XCTAssertThrowsError(try registry.setEnabled(true, pluginID: pluginID)) { error in
            XCTAssertEqual(error as? ExternalPluginRegistryError, .invalidConfiguration)
        }
        XCTAssertTrue(registry.enabledProviders().isEmpty)
    }

    private func staticManifest() throws -> PluginManifest {
        let source = try loadExampleGatewayManifest()
        let sourceHTTP = try XCTUnwrap(source.http)
        let configuration = PluginConfigurationSchema(
            version: source.configuration?.version ?? PluginConfigurationSchema.currentVersion,
            title: source.configuration?.title,
            description: source.configuration?.description,
            fields: [
                PluginConfigurationField(
                    id: "endpoint",
                    label: "Endpoint",
                    kind: .url,
                    required: true,
                    defaultValue: .string("https://gateway.example.test/v1/cost/current")
                ),
                PluginConfigurationField(
                    id: "token",
                    label: "Authorization",
                    kind: .secret,
                    required: true
                )
            ]
        )
        let http = PluginHTTPJSONDefinition(
            method: sourceHTTP.method,
            urlField: sourceHTTP.urlField,
            headers: [
                PluginHTTPHeader(name: "Authorization", valueField: "token"),
                PluginHTTPHeader(name: "Accept", value: "application/json")
            ],
            timeoutSeconds: sourceHTTP.timeoutSeconds,
            conditions: sourceHTTP.conditions
        )
        return PluginManifest(
            manifestVersion: source.manifestVersion,
            id: source.id,
            displayName: source.displayName,
            version: source.version,
            protocolVersion: 1,
            transport: .httpJSON,
            configuration: configuration,
            http: http,
            dashboard: source.dashboard,
            localizedDisplayName: source.displayNameText
        )
    }

    private func standardOAuthManifest() throws -> PluginManifest {
        let source = try loadExampleGatewayManifest()
        let sourceHTTP = try XCTUnwrap(source.http)
        let auth = PluginHTTPJSONAuthDefinition(
            refreshURLField: "refreshEndpoint",
            refreshTokenField: "refreshToken",
            encoding: .form,
            refreshTokenParameter: "refresh_token",
            grantTypeParameter: "grant_type",
            grantTypeValue: "refresh_token",
            clientIDField: "clientID",
            clientSecretField: "clientSecret",
            scopeField: "scope",
            accessTokenPath: "/access_token",
            refreshTokenPath: "/refresh_token",
            expiresInPath: "/expires_in",
            accessTokenHeader: "Authorization",
            headerMode: .bearer,
            expirySkewSeconds: 300,
            missingExpiryPolicy: .unauthorizedRetry,
            tokenExpiredStatusCodes: [401]
        )
        let configuration = PluginConfigurationSchema(fields: [
            PluginConfigurationField(
                id: "endpoint",
                label: "Endpoint",
                kind: .url,
                required: true
            ),
            PluginConfigurationField(
                id: "refreshEndpoint",
                label: "Refresh endpoint",
                kind: .url,
                required: true
            ),
            PluginConfigurationField(
                id: "refreshToken",
                label: "Refresh token",
                kind: .secret,
                required: true
            ),
            PluginConfigurationField(
                id: "clientID",
                label: "Client ID",
                kind: .text,
                required: true
            ),
            PluginConfigurationField(
                id: "clientSecret",
                label: "Client secret",
                kind: .secret,
                required: true
            ),
            PluginConfigurationField(
                id: "scope",
                label: "Scope",
                kind: .text,
                required: true
            )
        ])
        return PluginManifest(
            manifestVersion: source.manifestVersion,
            id: "com.example.oauth",
            displayName: "OAuth",
            version: source.version,
            protocolVersion: 2,
            transport: .httpJSON,
            configuration: configuration,
            http: PluginHTTPJSONDefinition(
                method: sourceHTTP.method,
                urlField: "endpoint",
                headers: [PluginHTTPHeader(name: "Accept", value: "application/json")],
                timeoutSeconds: sourceHTTP.timeoutSeconds,
                conditions: sourceHTTP.conditions,
                auth: auth
            ),
            dashboard: source.dashboard
        )
    }

    private func oauthConfigurationData(
        endpoint: String,
        refreshEndpoint: String,
        refreshToken: String,
        clientID: String? = nil,
        clientSecret: String? = nil,
        scope: String? = nil
    ) -> Data {
        var values: [String: PluginJSONValue] = [
            "endpoint": .string(endpoint),
            "refreshEndpoint": .string(refreshEndpoint),
            "refreshToken": .string(refreshToken)
        ]
        if let clientID { values["clientID"] = .string(clientID) }
        if let clientSecret { values["clientSecret"] = .string(clientSecret) }
        if let scope { values["scope"] = .string(scope) }
        return try! JSONEncoder().encode(PluginJSONValue.object(values))
    }

    private func dashboardBody() -> String {
        """
        {
          "code": 0,
          "success": true,
          "data": {
            "username": "test-user",
            "today_cost": 1,
            "daily_quota": 100,
            "monthly_cost": 2,
            "monthly_quota": 300
          }
        }
        """
    }

    private func makeAuthProvider(
        manifest: PluginManifest,
        configurationData: Data,
        server: ScriptedRequestServer,
        store: InMemoryRefreshCredentialStore,
        now: Date,
        registry: HTTPJSONAuthSessionRegistry = HTTPJSONAuthSessionRegistry()
    ) throws -> HTTPJSONPluginProvider {
        try HTTPJSONPluginProvider(
            manifest: manifest,
            configurationData: configurationData,
            send: { request in
                try await server.send(request)
            },
            credentialStore: store,
            sessionRegistry: registry,
            nowProvider: { now }
        )
    }

    private func loadExampleGatewayManifest() throws -> PluginManifest {
        let url = repoRoot().appendingPathComponent("Examples/Plugins/Gateway/plugin.json")
        return try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func configurationData(endpoint: String, token: String) -> Data {
        try! JSONEncoder().encode(PluginJSONValue.object([
            "endpoint": .string(endpoint),
            "token": .string(token)
        ]))
    }

    private func makeProvider(
        manifest: PluginManifest,
        body: String,
        endpoint: String = "https://api.example.test",
        statusCode: Int = 200,
        maximumResponseBytes: Int = ExternalPluginTransport.maximumResponseBytes
    ) throws -> HTTPJSONPluginProvider {
        let sender: HTTPJSONPluginProvider.RequestSender = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
        return try HTTPJSONPluginProvider(
            manifest: manifest,
            configurationData: configurationData(endpoint: endpoint, token: "secret-value"),
            maximumResponseBytes: maximumResponseBytes,
            send: sender
        )
    }

    private actor RequestRecorder {
        private(set) var request: URLRequest?

        func record(_ request: URLRequest) {
            self.request = request
        }
    }

    private final class InMemorySecretStore: PluginSecretStore, @unchecked Sendable {
        private var values = [String: Data]()

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

    private final class InMemoryRefreshCredentialStore: PluginRefreshCredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values = [String: String]()
        private let failsWrites: Bool

        init(failsWrites: Bool = false) {
            self.failsWrites = failsWrites
        }

        func read(pluginID: String, fieldID: String) throws -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[key(pluginID: pluginID, fieldID: fieldID)]
        }

        func write(_ value: String, pluginID: String, fieldID: String) throws {
            if failsWrites { throw PluginSecretStoreError.operationFailed(-1) }
            lock.lock()
            values[key(pluginID: pluginID, fieldID: fieldID)] = value
            lock.unlock()
        }

        func value(pluginID: String, fieldID: String) -> String? {
            try? read(pluginID: pluginID, fieldID: fieldID)
        }

        private func key(pluginID: String, fieldID: String) -> String {
            "\(pluginID)|\(fieldID)"
        }
    }

    private struct ScriptedReply: Sendable {
        let body: String
        let statusCode: Int
        let delayNanoseconds: UInt64

        init(body: String, statusCode: Int = 200, delayNanoseconds: UInt64 = 0) {
            self.body = body
            self.statusCode = statusCode
            self.delayNanoseconds = delayNanoseconds
        }
    }

    private actor ScriptedRequestServer {
        private var replies: [ScriptedReply]
        private var recordedRequests = [URLRequest]()

        init(replies: [ScriptedReply]) {
            self.replies = replies
        }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            recordedRequests.append(request)
            guard !replies.isEmpty else {
                throw HTTPJSONPluginError.requestFailed
            }
            let reply = replies.removeFirst()
            if reply.delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: reply.delayNanoseconds)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: reply.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(reply.body.utf8), response)
        }

        func requests() -> [URLRequest] {
            recordedRequests
        }
    }
}
