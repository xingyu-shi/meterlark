import Foundation

enum MenuBarFormatPart: Equatable, Sendable {
    case logo
    case money(precision: Int?, includeCurrency: Bool)
    case compactMoney(includeCurrency: Bool)
    case text(String)
    case cost(precision: Int?)
    case compactCost
}

struct MenuBarFormat: Equatable, Sendable {
    static let defaultValue = "[logo]$[cost]"
    static let legacyDefaultValue = "[logo]"
    static let maximumLength = 64

    enum ValidationError: Error, Equatable, Sendable {
        case empty
        case tooLong
        case unclosedToken
        case unsupportedToken(String)
        case invalidPrecision
        case missingToken
        case controlCharacter
    }

    let rawValue: String
    let parts: [MenuBarFormatPart]
    let validationError: ValidationError?

    var isValid: Bool { validationError == nil }

    init(rawValue: String) {
        let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = normalizedValue
        switch Self.parse(normalizedValue) {
        case let .success(parts):
            self.parts = parts
            self.validationError = nil
        case let .failure(error):
            self.parts = [.logo]
            self.validationError = error
        }
    }

    private static func parse(_ rawValue: String) -> Result<[MenuBarFormatPart], ValidationError> {
        let value = rawValue
        guard !value.isEmpty else { return .failure(.empty) }
        guard value.count <= maximumLength else { return .failure(.tooLong) }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.controlCharacter)
        }

        var parts: [MenuBarFormatPart] = []
        var literal = ""

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            parts.append(.text(literal))
            literal = ""
        }

        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "[" else {
                literal.append(character)
                index = value.index(after: index)
                continue
            }

            guard let closing = value[index...].firstIndex(of: "]") else {
                return .failure(.unclosedToken)
            }
            flushLiteral()

            let tokenStart = value.index(after: index)
            let token = String(value[tokenStart..<closing]).lowercased()
            switch token {
            case "logo":
                parts.append(.logo)
            case "money":
                parts.append(.money(precision: 0, includeCurrency: true))
            case "money:plain":
                parts.append(.money(precision: 0, includeCurrency: false))
            case "money:compact":
                parts.append(.compactMoney(includeCurrency: true))
            case "money:compact:plain":
                parts.append(.compactMoney(includeCurrency: false))
            case let token where token.hasPrefix("money:"):
                let components = token.split(separator: ":").map(String.init)
                guard components.count == 2 || components.count == 3,
                      components[0] == "money",
                      components.count == 2 || components[2] == "plain" else {
                    return .failure(.unsupportedToken(token))
                }
                let precisionText = components[1]
                guard let precision = Int(precisionText), (0...6).contains(precision) else {
                    return .failure(.invalidPrecision)
                }
                parts.append(.money(precision: precision, includeCurrency: components.count == 2))
            case "cost":
                parts.append(.cost(precision: nil))
            case "cost:compact":
                parts.append(.compactCost)
            case let token where token.hasPrefix("cost:"):
                let precisionText = String(token.dropFirst("cost:".count))
                guard let precision = Int(precisionText), (0...6).contains(precision) else {
                    return .failure(.invalidPrecision)
                }
                parts.append(.cost(precision: precision))
            default:
                return .failure(.unsupportedToken(token))
            }

            index = value.index(after: closing)
        }
        flushLiteral()

        let hasToken = parts.contains { part in
            switch part {
            case .logo, .money, .compactMoney, .cost, .compactCost:
                return true
            case .text:
                return false
            }
        }
        guard hasToken else { return .failure(.missingToken) }
        return .success(parts)
    }
}

struct MenuBarFormatPreviewState: Equatable, Sendable {
    let format: MenuBarFormat

    init(rawValue: String) {
        self.format = MenuBarFormat(rawValue: rawValue)
    }

    var canSave: Bool { format.isValid }
}
