// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SaldimaCore
import SaldimaTestKit

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Fixtures/books/\(name)")
}

private func loadFixtureData(_ name: String) throws -> Data {
    let raw = try Data(contentsOf: fixture(name))
    return raw.starts(with: [0x1f, 0x8b]) ? try Gzip.inflate(raw) : raw
}

private let usd = CommodityRef(space: "CURRENCY", id: "USD")
private let eur = CommodityRef(space: "CURRENCY", id: "EUR")
private let aapl = CommodityRef(space: "NASDAQ", id: "AAPL")

private func priceGuid(_ character: Character) throws -> Guid {
    try #require(Guid(String(repeating: character, count: 32)))
}

/// Mirrors the web engine's locked `describe("prices", ...)` suite in
/// `packages/gnucash/src/xml-document.test.ts` (`johnarleyburns/saldima#104`/#107)
/// byte-for-byte where the assertions are about the on-disk XML shape.
@Suite("XMLBookDocument prices")
struct XMLBookDocumentPriceTests {
    private func openFixture() throws -> XMLBookDocument {
        try XMLBookDocument.parse(data: loadFixtureData("oracle-mini.gnucash"))
    }

    @Test("creates a price matching real GnuCash's on-disk shape, and reads it back")
    func createsPriceMatchingOnDiskShape() throws {
        let document = try openFixture()
        let guid = try priceGuid("1")
        let price = document.createPrice(
            guid: guid,
            commodity: eur,
            currency: usd,
            date: "2026-01-15",
            type: "",
            value: try Money(num: 108, denom: 100)
        )

        #expect(price.guid == guid)
        #expect(price.commodity == eur)
        #expect(price.currency == usd)
        #expect(price.date == "2026-01-15")
        #expect(price.source == "user:price-editor")
        #expect(price.type == "")
        #expect(price.value == (try Money(num: 108, denom: 100)))

        let xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(xml.contains("<gnc:pricedb version=\"1\">"))
        #expect(xml.contains("<price:id type=\"guid\">\(guid.rawValue)</price:id>"))
        #expect(xml.contains("<price:commodity><cmdty:space>CURRENCY</cmdty:space><cmdty:id>EUR</cmdty:id></price:commodity>"))
        #expect(xml.contains("<price:source>user:price-editor</price:source>"))
        #expect(!xml.contains("<price:type>"))
        #expect(xml.contains("<price:value>108/100</price:value>"))

        let reparsed = try XMLBookDocument.parse(data: document.serialize())
        #expect(reparsed.price(price.guid) == price)
    }

    @Test("writes price:type only when given, before price:value")
    func writesTypeOnlyWhenGivenBeforeValue() throws {
        let document = try openFixture()
        document.createPrice(
            guid: try priceGuid("2"),
            commodity: aapl,
            currency: usd,
            date: "2026-01-15",
            type: "last",
            value: try Money(num: 19_000, denom: 100)
        )
        let xml = String(decoding: document.serialize(), as: UTF8.self)
        #expect(xml.contains("<price:type>last</price:type><price:value>19000/100</price:value>"))
    }

    @Test("omits <gnc:pricedb> entirely when the book has no prices")
    func omitsPricedbWhenEmpty() throws {
        let document = try openFixture()
        #expect(!String(decoding: document.serialize(), as: UTF8.self).contains("gnc:pricedb"))
    }

    @Test("removes <gnc:pricedb> once the last price is deleted; deleting an unknown price is a silent no-op")
    func removesPricedbWhenLastPriceDeleted() throws {
        let document = try openFixture()
        let price = document.createPrice(
            guid: try priceGuid("1"),
            commodity: eur,
            currency: usd,
            date: "2026-01-15",
            type: "",
            value: try Money(num: 108, denom: 100)
        )
        #expect(String(decoding: document.serialize(), as: UTF8.self).contains("gnc:pricedb"))
        document.deletePrice(price.guid)
        #expect(document.prices().isEmpty)
        #expect(!String(decoding: document.serialize(), as: UTF8.self).contains("gnc:pricedb"))
        document.deletePrice(try priceGuid("f"))
        #expect(document.prices().isEmpty)
    }

    @Test("supports multiple prices across different commodity/currency pairs")
    func supportsMultiplePrices() throws {
        let document = try openFixture()
        document.createPrice(guid: try priceGuid("1"), commodity: eur, currency: usd, date: "2026-01-15", type: "", value: try Money(num: 108, denom: 100))
        document.createPrice(guid: try priceGuid("2"), commodity: aapl, currency: usd, date: "2026-01-15", type: "", value: try Money(num: 19_000, denom: 100))
        #expect(document.prices().count == 2)
    }

    @Test("updates date, value and type independently, adding and removing type")
    func updatesFieldsIndependently() throws {
        let document = try openFixture()
        let price = document.createPrice(
            guid: try priceGuid("1"),
            commodity: eur,
            currency: usd,
            date: "2026-01-15",
            type: "",
            value: try Money(num: 108, denom: 100)
        )

        document.updatePrice(price.guid, date: "2026-02-01", type: nil, value: nil)
        var updated = try #require(document.price(price.guid))
        #expect(updated.date == "2026-02-01")
        #expect(updated.value == (try Money(num: 108, denom: 100)))

        document.updatePrice(price.guid, date: nil, type: nil, value: try Money(num: 110, denom: 100))
        updated = try #require(document.price(price.guid))
        #expect(updated.value == (try Money(num: 110, denom: 100)))

        document.updatePrice(price.guid, date: nil, type: "last", value: nil)
        updated = try #require(document.price(price.guid))
        #expect(updated.type == "last")
        #expect(String(decoding: document.serialize(), as: UTF8.self).contains("<price:type>last</price:type><price:value>110/100</price:value>"))

        // Replacing an already-set type updates it in place.
        document.updatePrice(price.guid, date: nil, type: "transaction", value: nil)
        updated = try #require(document.price(price.guid))
        #expect(updated.type == "transaction")

        document.updatePrice(price.guid, date: nil, type: "", value: nil)
        updated = try #require(document.price(price.guid))
        #expect(updated.type == "")
        #expect(!String(decoding: document.serialize(), as: UTF8.self).contains("<price:type>"))

        // Setting the same (now-absent) type again is a no-op, not an error.
        document.updatePrice(price.guid, date: nil, type: "", value: nil)
        updated = try #require(document.price(price.guid))
        #expect(updated.type == "")
    }

    @Test("updating an unknown price is a silent no-op")
    func updatingUnknownPriceIsNoop() throws {
        let document = try openFixture()
        document.updatePrice(try priceGuid("f"), date: nil, type: nil, value: try Money(num: 1, denom: 1))
        #expect(document.prices().isEmpty)
    }

    @Test("returns nil for an unknown price guid")
    func returnsNilForUnknownGuid() throws {
        let document = try openFixture()
        #expect(document.price(try priceGuid("f")) == nil)
    }

    @Test("creates <gnc:pricedb> right after book:id when the book declares no commodities")
    func createsPricedbRightAfterBookIdWithNoCommodities() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8" ?>
        <gnc-v2 xmlns:gnc="http://www.gnucash.org/XML/gnc" xmlns:book="http://www.gnucash.org/XML/book" xmlns:cmdty="http://www.gnucash.org/XML/cmdty" xmlns:price="http://www.gnucash.org/XML/price" xmlns:ts="http://www.gnucash.org/XML/ts">
        <gnc:book version="2.0.0">
        <book:id type="guid">\(String(repeating: "b", count: 32))</book:id>
        </gnc:book>
        </gnc-v2>
        """
        let document = try XMLBookDocument.parse(data: Data(xml.utf8))
        let price = document.createPrice(
            guid: try priceGuid("1"),
            commodity: eur,
            currency: usd,
            date: "2026-01-15",
            type: "",
            value: try Money(num: 108, denom: 100)
        )
        #expect(document.price(price.guid) == price)
        let serialized = String(decoding: document.serialize(), as: UTF8.self)
        // After book:id (never before it), even with no commodity to anchor on.
        let bookIdIndex = try #require(serialized.range(of: "<book:id")?.lowerBound)
        let pricedbIndex = try #require(serialized.range(of: "<gnc:pricedb")?.lowerBound)
        #expect(bookIdIndex < pricedbIndex)
    }

    @Test("nearestPrice picks the candidate closest in time, directional only, nil when the pair has no price")
    func nearestPricePicksClosestCandidate() throws {
        let document = try openFixture()
        document.createPrice(guid: try priceGuid("1"), commodity: eur, currency: usd, date: "2026-01-01", type: "", value: try Money(num: 105, denom: 100))
        document.createPrice(guid: try priceGuid("2"), commodity: eur, currency: usd, date: "2026-01-20", type: "", value: try Money(num: 110, denom: 100))
        document.createPrice(guid: try priceGuid("3"), commodity: eur, currency: usd, date: "2026-02-01", type: "", value: try Money(num: 112, denom: 100))

        let nearestEarly = try document.nearestPrice(commodity: eur, currency: usd, asOf: "2026-01-05")
        #expect(nearestEarly?.date == "2026-01-01")

        let nearestMid = try document.nearestPrice(commodity: eur, currency: usd, asOf: "2026-01-16")
        #expect(nearestMid?.date == "2026-01-20")

        // Directional only -- no reciprocal-pair fallback.
        #expect(try document.nearestPrice(commodity: usd, currency: eur, asOf: "2026-01-16") == nil)

        // No price at all for a pair.
        #expect(try document.nearestPrice(commodity: aapl, currency: usd, asOf: "2026-01-16") == nil)
    }

    @Test("convertMoney returns the value unchanged for identical commodities, multiplies by the nearest price otherwise, and nil with no price")
    func convertMoneyMultipliesByNearestPrice() throws {
        let document = try openFixture()
        let value = try Money(num: 100, denom: 1)

        #expect(try document.convertMoney(value, from: usd, to: usd, asOf: "2026-01-15") == value)
        #expect(try document.convertMoney(value, from: eur, to: usd, asOf: "2026-01-15") == nil)

        document.createPrice(guid: try priceGuid("1"), commodity: eur, currency: usd, date: "2026-01-15", type: "", value: try Money(num: 108, denom: 100))
        let converted = try document.convertMoney(value, from: eur, to: usd, asOf: "2026-01-15")
        #expect(converted == (try Money.multiply(value, Money(num: 108, denom: 100))))
    }
}
