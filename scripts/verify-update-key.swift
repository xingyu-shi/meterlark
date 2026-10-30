import CryptoKit
import Foundation

// Never print the private key or put it in a process argument.
do {
    let keyURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let infoURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let keyText = try String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
    guard let keyData = Data(base64Encoded: keyText), keyData.count == 32,
          let expected = info?["SUPublicEDKey"] as? String else {
        fputs("Invalid update signing key or missing app public key\n", stderr)
        exit(1)
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    guard privateKey.publicKey.rawRepresentation.base64EncodedString() == expected else {
        fputs("Update signing key does not match the app public key\n", stderr)
        exit(1)
    }
    print("Update signing key matches the app public key")
} catch {
    fputs("Could not read or verify update signing configuration\n", stderr)
    exit(1)
}
