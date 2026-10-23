import Foundation
import Darwin

enum ExternalPluginTransport {
    static let protocolVersion = 1
    static let requestType = "dashboard"
    static let defaultTimeout: TimeInterval = 10
    static let maximumRequestBytes = 64 * 1024
    static let maximumResponseBytes = 512 * 1024
}

enum ExternalPluginTransportError: Error, Equatable, Sendable {
    case unsupportedTransport
    case invalidEntrypoint
    case invalidConfiguration
    case requestTooLarge
    case processLaunch
    case stdinWrite
    case stdoutRead
    case timeout
    case outputTooLarge
    case nonZeroExit(Int32)
    case invalidUTF8
    case invalidJSON
}

extension ExternalPluginTransportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedTransport:
            return "This plugin does not declare a supported external transport."
        case .invalidEntrypoint:
            return "The plugin executable is not a valid package entrypoint."
        case .invalidConfiguration:
            return "The plugin configuration is not a JSON object."
        case .requestTooLarge:
            return "The plugin request is too large."
        case .processLaunch:
            return "The plugin process could not be launched."
        case .stdinWrite:
            return "The plugin request could not be written."
        case .stdoutRead:
            return "The plugin response could not be read."
        case .timeout:
            return "The plugin did not respond before the refresh timeout."
        case .outputTooLarge:
            return "The plugin response is too large."
        case let .nonZeroExit(status):
            return "The plugin process exited with status \(status)."
        case .invalidUTF8:
            return "The plugin response is not valid UTF-8 JSON."
        case .invalidJSON:
            return "The plugin response is not a valid dashboard document."
        }
    }
}

enum PluginJSONValue: Codable, Equatable, Sendable {
    case object([String: PluginJSONValue])
    case array([PluginJSONValue])
    case string(String)
    case integer(Int64)
    case decimal(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var object = [String: PluginJSONValue]()
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(PluginJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var unkeyed = try? decoder.unkeyedContainer() {
            var values = [PluginJSONValue]()
            while !unkeyed.isAtEnd {
                values.append(try unkeyed.decode(PluginJSONValue.self))
            }
            self = .array(values)
            return
        }

        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? single.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? single.decode(Double.self), value.isFinite {
            self = .decimal(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .object(value):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, item) in value {
                try container.encode(item, forKey: DynamicCodingKey(stringValue: key))
            }
        case let .array(value):
            var container = encoder.unkeyedContainer()
            for item in value {
                try container.encode(item)
            }
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .integer(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .decimal(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .boolean(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

struct ExternalPluginRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let pluginID: String
    let configuration: PluginJSONValue?

    init(pluginID: String, configuration: PluginJSONValue? = nil) {
        protocolVersion = ExternalPluginTransport.protocolVersion
        type = ExternalPluginTransport.requestType
        self.pluginID = pluginID
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case type
        case pluginID
        case configuration
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(type, forKey: .type)
        try container.encode(pluginID, forKey: .pluginID)
        try container.encodeIfPresent(configuration, forKey: .configuration)
    }
}

struct ExternalPluginProcessResult: Equatable, Sendable {
    let stdout: Data
    let terminationStatus: Int32
}

protocol ExternalPluginProcessRunner: Sendable {
    func run(
        executableURL: URL,
        packageURL: URL,
        request: Data,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) async throws -> ExternalPluginProcessResult
}

struct SystemExternalPluginProcessRunner: ExternalPluginProcessRunner {
    func run(
        executableURL: URL,
        packageURL: URL,
        request: Data,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) async throws -> ExternalPluginProcessResult {
        let controller = ExternalPluginProcessController(
            executableURL: executableURL,
            packageURL: packageURL,
            request: request,
            maximumOutputBytes: maximumOutputBytes
        )

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ExternalPluginProcessResult.self) { group in
                group.addTask {
                    try await controller.execute()
                }
                group.addTask {
                    let nanoseconds = UInt64(max(timeout, 0.001) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                    throw ExternalPluginTransportError.timeout
                }

                do {
                    guard let result = try await group.next() else {
                        throw ExternalPluginTransportError.processLaunch
                    }
                    group.cancelAll()
                    return result
                } catch {
                    group.cancelAll()
                    controller.terminate()
                    throw error
                }
            }
        } onCancel: {
            controller.terminate()
        }
    }
}

private final class ExternalPluginProcessController: @unchecked Sendable {
    private let executableURL: URL
    private let packageURL: URL
    private let request: Data
    private let maximumOutputBytes: Int
    private let lock = NSLock()
    private var process: Process?
    private var processGroupID: pid_t?
    private var isCancelled = false

    init(executableURL: URL, packageURL: URL, request: Data, maximumOutputBytes: Int) {
        self.executableURL = executableURL
        self.packageURL = packageURL
        self.request = request
        self.maximumOutputBytes = maximumOutputBytes
    }

    func execute() async throws -> ExternalPluginProcessResult {
        try Task.checkCancellation()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = []
        process.currentDirectoryURL = packageURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }

        do {
            try launch(process)
            try makeNonblocking(input.fileHandleForWriting, writing: true)
            try makeNonblocking(output.fileHandleForReading, writing: false)
            try await writeRequest(to: input.fileHandleForWriting)
            try input.fileHandleForWriting.close()
            let stdout = try await readLimited(output.fileHandleForReading)
            while process.isRunning {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            process.waitUntilExit()
            return ExternalPluginProcessResult(
                stdout: stdout,
                terminationStatus: process.terminationStatus
            )
        } catch {
            terminate()
            throw error
        }
    }

    func terminate() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let process = self.process
        let processGroupID = self.processGroupID
        lock.unlock()
        // Foundation normally gives a child its own process group. Only kill
        // a group whose ownership was verified at launch; never target the
        // host's group. Descendants can hold stdout open after the parent exits.
        if let processGroupID {
            _ = Darwin.kill(-processGroupID, SIGKILL)
        }
        if let process, process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { throw CancellationError() }
        self.process = process
        do {
            try process.run()
        } catch {
            throw ExternalPluginTransportError.processLaunch
        }
        let pid = process.processIdentifier
        if getpgid(pid) != pid { _ = setpgid(pid, pid) }
        if getpgid(pid) == pid { processGroupID = pid }
    }

    private func makeNonblocking(_ handle: FileHandle, writing: Bool) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1,
              !writing || fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw writing ? ExternalPluginTransportError.stdinWrite : ExternalPluginTransportError.stdoutRead
        }
    }

    private func writeRequest(to handle: FileHandle) async throws {
        var offset = 0
        while offset < request.count {
            try Task.checkCancellation()
            let count = request.withUnsafeBytes { bytes in
                Darwin.write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), request.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count == -1, errno == EINTR {
                continue
            } else if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                try await Task.sleep(nanoseconds: 20_000_000)
            } else {
                throw ExternalPluginTransportError.stdinWrite
            }
        }
    }

    private func readLimited(_ handle: FileHandle) async throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                guard count <= maximumOutputBytes - result.count else {
                    throw ExternalPluginTransportError.outputTooLarge
                }
                result.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return result
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                try await Task.sleep(nanoseconds: 20_000_000)
            } else {
                throw ExternalPluginTransportError.stdoutRead
            }
        }
    }
}

struct StdioJSONPluginProvider: DashboardPluginProvider {
    let manifest: PluginManifest
    let packageURL: URL
    let executableURL: URL
    let configurationData: Data?
    let timeout: TimeInterval
    let maximumResponseBytes: Int
    let runner: any ExternalPluginProcessRunner

    init(
        manifest: PluginManifest,
        packageURL: URL,
        configurationData: Data? = nil,
        timeout: TimeInterval = ExternalPluginTransport.defaultTimeout,
        maximumResponseBytes: Int = ExternalPluginTransport.maximumResponseBytes,
        runner: any ExternalPluginProcessRunner = SystemExternalPluginProcessRunner()
    ) throws {
        try manifest.validate()
        guard manifest.transport == .stdioJSON,
              let entrypoint = manifest.entrypoint else {
            throw ExternalPluginTransportError.unsupportedTransport
        }
        let validatedPackage: ValidatedPluginPackage
        do {
            validatedPackage = try PluginPackageValidator().validate(packageURL: packageURL)
        } catch {
            throw ExternalPluginTransportError.invalidEntrypoint
        }
        guard validatedPackage.manifest == manifest else {
            throw ExternalPluginTransportError.invalidEntrypoint
        }
        let executableURL = validatedPackage.packageURL
            .appendingPathComponent(entrypoint)
            .standardizedFileURL
        guard maximumResponseBytes > 0 else {
            throw ExternalPluginTransportError.outputTooLarge
        }
        self.manifest = manifest
        self.packageURL = validatedPackage.packageURL
        self.executableURL = executableURL
        self.configurationData = configurationData
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : ExternalPluginTransport.defaultTimeout
        self.maximumResponseBytes = maximumResponseBytes
        self.runner = runner
    }

    func fetchDashboard() async throws -> PluginDashboardDocument {
        let request = try makeRequest()
        let result = try await runner.run(
            executableURL: executableURL,
            packageURL: packageURL,
            request: request,
            timeout: timeout,
            maximumOutputBytes: maximumResponseBytes
        )
        guard result.terminationStatus == 0 else {
            throw ExternalPluginTransportError.nonZeroExit(result.terminationStatus)
        }
        guard String(data: result.stdout, encoding: .utf8) != nil else {
            throw ExternalPluginTransportError.invalidUTF8
        }
        do {
            return try JSONDecoder().decode(PluginDashboardDocument.self, from: result.stdout)
        } catch {
            throw ExternalPluginTransportError.invalidJSON
        }
    }

    private func makeRequest() throws -> Data {
        let configuration: PluginJSONValue?
        if let configurationData {
            let decoded = try JSONDecoder().decode(PluginJSONValue.self, from: configurationData)
            guard case .object = decoded else {
                throw ExternalPluginTransportError.invalidConfiguration
            }
            configuration = decoded
        } else {
            configuration = nil
        }

        var request = try JSONEncoder().encode(ExternalPluginRequest(
            pluginID: manifest.id,
            configuration: configuration
        ))
        request.append(0x0A)
        guard request.count <= ExternalPluginTransport.maximumRequestBytes else {
            throw ExternalPluginTransportError.requestTooLarge
        }
        return request
    }

}
