import Foundation

enum AppMetadata {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development"
    }

    static var bundledCCUsageVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CCUsageVersion") as? String ?? "20.0.32"
    }

    static var bundledCCUsageSHA256: String {
        Bundle.main.object(forInfoDictionaryKey: "CCUsageSHA256") as? String ?? "unknown"
    }
}
