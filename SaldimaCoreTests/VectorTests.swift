// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import SaldimaCore

private struct WireMoney: Decodable {
    let num: String
    let denom: String

    func money() throws -> Money {
        guard let numerator = Int64(num), let denominator = Int64(denom) else {
            throw MoneyError.overflow
        }
        return try Money(num: numerator, denom: denominator)
    }
}

private enum ExpectedValue: Decodable {
    case money(WireMoney)
    case text(String)

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        self = .money(try WireMoney(from: decoder))
    }
}

private struct VectorCase: Decodable {
    let id: String
    let op: String
    let left: WireMoney?
    let right: WireMoney?
    let value: WireMoney?
    let fraction: String?
    let text: String?
    let expected: ExpectedValue
}

private struct MoneyVectors: Decodable {
    let schemaVersion: Int
    let fraction: String
    let cases: [VectorCase]
}

private struct GuidVectors: Decodable {
    let schemaVersion: Int
    let pattern: String
    let valid: [String]
    let invalid: [String]
}

private enum Fixture {
    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent("Fixtures/vectors/\(name)")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private func requireMoney(_ wire: WireMoney?) throws -> Money {
    guard let wire else { throw MoneyError.invalidDecimal }
    return try wire.money()
}

private func requireFraction(_ text: String?) throws -> Int64 {
    guard let text, let fraction = Int64(text) else { throw MoneyError.invalidDecimal }
    return fraction
}

private func requireExpectedMoney(_ expected: ExpectedValue) throws -> Money {
    guard case .money(let wire) = expected else { throw MoneyError.invalidDecimal }
    return try wire.money()
}

@Suite("Golden vectors: money")
struct MoneyVectorTests {
    @Test("the vector schema is the one this app understands")
    func schemaVersion() throws {
        let vectors = try Fixture.decode(MoneyVectors.self, "money.json")
        #expect(vectors.schemaVersion == 1)
        #expect(vectors.fraction == "100")
        #expect(!vectors.cases.isEmpty)
    }

    @Test("every money vector replays")
    func replay() throws {
        let vectors = try Fixture.decode(MoneyVectors.self, "money.json")
        for testCase in vectors.cases {
            switch testCase.op {
            case "add":
                let actual = try Money.add(try requireMoney(testCase.left), try requireMoney(testCase.right))
                #expect(actual == (try requireExpectedMoney(testCase.expected)), "\(testCase.id)")
            case "subtract":
                let actual = try Money.subtract(try requireMoney(testCase.left), try requireMoney(testCase.right))
                #expect(actual == (try requireExpectedMoney(testCase.expected)), "\(testCase.id)")
            case "multiply":
                let actual = try Money.multiply(try requireMoney(testCase.left), try requireMoney(testCase.right))
                #expect(actual == (try requireExpectedMoney(testCase.expected)), "\(testCase.id)")
            case "round":
                let actual = try requireMoney(testCase.value)
                    .rounded(toFraction: try requireFraction(testCase.fraction))
                #expect(actual == (try requireExpectedMoney(testCase.expected)), "\(testCase.id)")
            case "parse":
                guard let text = testCase.text else {
                    Issue.record("\(testCase.id): missing text")
                    continue
                }
                let actual = try Money.parse(text, fraction: try requireFraction(testCase.fraction))
                #expect(actual == (try requireExpectedMoney(testCase.expected)), "\(testCase.id)")
            case "format":
                let actual = try requireMoney(testCase.value)
                    .formatted(fraction: try requireFraction(testCase.fraction))
                guard case .text(let expected) = testCase.expected else {
                    Issue.record("\(testCase.id): expected text")
                    continue
                }
                #expect(actual == expected, "\(testCase.id)")
            default:
                Issue.record("\(testCase.id): unknown op \(testCase.op)")
            }
        }
    }
}

@Suite("Golden vectors: GUID")
struct GuidVectorTests {
    @Test("every GUID vector replays")
    func replay() throws {
        let vectors = try Fixture.decode(GuidVectors.self, "guid.json")
        #expect(vectors.schemaVersion == 1)
        for value in vectors.valid {
            #expect(Guid(value) != nil, "expected valid: \(value)")
        }
        for value in vectors.invalid {
            #expect(Guid(value) == nil, "expected invalid: \(value)")
        }
        #expect(Set(vectors.valid).count == vectors.valid.count)
    }
}
