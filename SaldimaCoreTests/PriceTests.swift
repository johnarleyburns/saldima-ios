// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SaldimaCore
@testable import SaldimaTestKit

private func priceBook() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("price-\(UUID().uuidString).gnucash")
    try BookWriter.create(at: url, template: BookTemplates.personal, ids: SeededIDGenerator())
    return url
}

private let usd = CommodityRef(space: "CURRENCY", id: "USD")
private let eur = CommodityRef(space: "CURRENCY", id: "EUR")
private let aapl = CommodityRef(space: "NASDAQ", id: "AAPL")

/// `BookStore`-level tests for desktop GnuCash's Price Editor / exchange-rate
/// database, mirroring the web engine's locked design
/// (`johnarleyburns/saldima#104`/#107): a commodity/currency pair, a date, an
/// optional free-text type and a value; the pair is immutable after creation
/// (same convention as scheduled transactions and budgets); `nearestPrice`
/// and `convertMoney` as the read-side engine (no conversion UI this
/// milestone).
@Suite("Prices")
struct PriceTests {
    private func openBook() async throws -> BookStore {
        try BookStore(url: try priceBook())
    }

    private func draft(
        commodity: CommodityRef = eur,
        currency: CommodityRef = usd,
        date: String = "2026-01-15",
        type: String = "",
        value: Money = try! Money(num: 108, denom: 100)
    ) -> PriceDraft {
        PriceDraft(commodity: commodity, currency: currency, date: date, type: type, value: value)
    }

    @Test("creates a price and reads it back")
    func createsAndReads() async throws {
        let store = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createPrice(draft(), ids: ids)

        let all = try await store.prices()
        #expect(all.count == 1)
        #expect(all.first?.guid == guid)
        #expect(all.first?.commodity == eur)
        #expect(all.first?.currency == usd)
        #expect(all.first?.date == "2026-01-15")
        #expect(all.first?.source == "user:price-editor")
        #expect(all.first?.type == "")

        let one = try await store.price(guid)
        #expect(one?.value == (try Money(num: 108, denom: 100)))
    }

    @Test("rejects an invalid date on create and on update")
    func rejectsInvalidDate() async throws {
        let store = try await openBook()
        let ids = SeededIDGenerator(start: 900)

        var badDraft = draft()
        badDraft.date = "01/15/2026"
        await #expect(throws: PriceError.invalidDate) {
            try await store.createPrice(badDraft, ids: ids)
        }

        let guid = try await store.createPrice(draft(), ids: ids)
        await #expect(throws: PriceError.invalidDate) {
            try await store.updatePrice(guid, with: PriceEditDraft(date: "not-a-date", value: try Money(num: 1, denom: 1)))
        }
    }

    @Test("supports multiple prices across different commodity/currency pairs")
    func supportsMultiplePrices() async throws {
        let store = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        try await store.createPrice(draft(commodity: eur, currency: usd), ids: ids)
        try await store.createPrice(draft(commodity: aapl, currency: usd, value: try Money(num: 19_000, denom: 100)), ids: ids)
        let all = try await store.prices()
        #expect(all.count == 2)
    }

    @Test("updates date, type and value independently, and rejects an unknown price")
    func updatesRestrictedFields() async throws {
        let store = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createPrice(draft(), ids: ids)

        try await store.updatePrice(guid, with: PriceEditDraft(date: "2026-02-01", value: try Money(num: 108, denom: 100)))
        var updated = try await store.price(guid)
        #expect(updated?.date == "2026-02-01")

        try await store.updatePrice(guid, with: PriceEditDraft(date: "2026-02-01", type: "last", value: try Money(num: 110, denom: 100)))
        updated = try await store.price(guid)
        #expect(updated?.type == "last")
        #expect(updated?.value == (try Money(num: 110, denom: 100)))

        // The commodity/currency pair never changes.
        #expect(updated?.commodity == eur)
        #expect(updated?.currency == usd)

        let unknown = try #require(Guid(String(repeating: "c", count: 32)))
        await #expect(throws: PriceError.unknownPrice(unknown)) {
            try await store.updatePrice(unknown, with: PriceEditDraft(date: "2026-01-01", value: try Money(num: 1, denom: 1)))
        }
    }

    @Test("deletes a price, and rejects an unknown one")
    func deletes() async throws {
        let store = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let guid = try await store.createPrice(draft(), ids: ids)
        try await store.deletePrice(guid)
        #expect(try await store.prices().isEmpty)

        await #expect(throws: PriceError.unknownPrice(guid)) {
            try await store.deletePrice(guid)
        }
    }

    @Test("nearestPrice picks the candidate closest in time, directional only")
    func nearestPricePicksClosestCandidate() async throws {
        let store = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        try await store.createPrice(draft(date: "2026-01-01", value: try Money(num: 105, denom: 100)), ids: ids)
        try await store.createPrice(draft(date: "2026-02-01", value: try Money(num: 112, denom: 100)), ids: ids)

        let nearest = try await store.nearestPrice(commodity: eur, currency: usd, asOf: "2026-01-10")
        #expect(nearest?.date == "2026-01-01")

        // Directional only -- no reciprocal-pair fallback.
        #expect(try await store.nearestPrice(commodity: usd, currency: eur, asOf: "2026-01-10") == nil)
    }

    @Test("convertMoney returns the value unchanged for identical commodities, multiplies by the nearest price otherwise, and nil with no price")
    func convertMoneyMultipliesByNearestPrice() async throws {
        let store = try await openBook()
        let ids = SeededIDGenerator(start: 900)
        let value = try Money(num: 100, denom: 1)

        #expect(try await store.convertMoney(value, from: usd, to: usd, asOf: "2026-01-15") == value)
        #expect(try await store.convertMoney(value, from: eur, to: usd, asOf: "2026-01-15") == nil)

        try await store.createPrice(draft(date: "2026-01-15", value: try Money(num: 108, denom: 100)), ids: ids)
        let converted = try await store.convertMoney(value, from: eur, to: usd, asOf: "2026-01-15")
        #expect(converted == (try Money.multiply(value, Money(num: 108, denom: 100))))
    }
}
