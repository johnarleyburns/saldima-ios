// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

private func isoDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func dateFromIso(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: text) ?? Date()
}

/// Desktop GnuCash's own Price Editor / exchange-rate database (Actions ->
/// Price Editor): list, create, edit and delete prices -- mirrors the web
/// engine's locked design (`johnarleyburns/saldima#104`). The
/// commodity/currency pair is immutable once created, the same convention
/// scheduled transactions and budgets use: change it by deleting and
/// recreating the price. Milestone 1: no online quote fetching, and no
/// report/transaction-entry currency-conversion UI -- just the price
/// database itself.
struct PricesView: View {
    let session: BookSession
    @State private var composing = false
    @State private var editing: Price?

    private var sortedPrices: [Price] {
        // Newest first, matching the web engine's own `pricesPage` listing.
        session.prices.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.prices.isEmpty {
                    ContentUnavailableView {
                        Label("No prices", systemImage: "arrow.left.arrow.right")
                    } description: {
                        Text("Record manual exchange rates and security prices, like desktop GnuCash's Price Editor.")
                    } actions: {
                        Button("New price") { composing = true }
                            .buttonStyle(.glassProminent)
                            .disabled(!session.isOpen)
                    }
                } else {
                    List {
                        ForEach(sortedPrices) { price in
                            Button {
                                editing = price
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(price.commodity.id) in \(price.currency.id)")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(price.date) \u{00b7} \(session.formatted(price.value))\(price.type.isEmpty ? "" : " \u{00b7} \(price.type)")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    Task { await session.delete(price) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Prices")
            .toolbar {
                if session.isOpen {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            composing = true
                        } label: {
                            Label("New price", systemImage: "plus")
                        }
                        .accessibilityIdentifier("prices.add")
                    }
                }
            }
            .sheet(isPresented: $composing) {
                NewPriceSheet(session: session)
            }
            .sheet(item: $editing) { price in
                EditPriceSheet(session: session, price: price)
            }
        }
    }
}

private struct NewPriceSheet: View {
    let session: BookSession

    @Environment(\.dismiss) private var dismiss
    @State private var commoditySpace = "CURRENCY"
    @State private var commodityId = ""
    @State private var currencySpace = "CURRENCY"
    @State private var currencyId: String
    @State private var date = Date()
    @State private var type = ""
    @State private var valueText = ""
    @State private var localError: String?

    init(session: BookSession) {
        self.session = session
        _currencyId = State(initialValue: session.currencyCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Commodity") {
                    TextField("Space (e.g. CURRENCY, NASDAQ)", text: $commoditySpace)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    TextField("Commodity (e.g. EUR, AAPL)", text: $commodityId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("prices.commodity")
                }
                Section("Currency") {
                    TextField("Space", text: $currencySpace)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    TextField("Currency", text: $currencyId)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("prices.currency")
                }
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Type (optional)", text: $type)
                    TextField("Value (currency per unit of commodity)", text: $valueText)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("prices.value")
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New price")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private func save() {
        let space = commoditySpace.trimmingCharacters(in: .whitespacesAndNewlines)
        let commodity = commodityId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !space.isEmpty, !commodity.isEmpty else {
            localError = "Enter the commodity."
            return
        }
        let curSpace = currencySpace.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = currencyId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !curSpace.isEmpty, !currency.isEmpty else {
            localError = "Enter the currency."
            return
        }
        guard let value = try? Money.parseHalfUp(valueText.trimmingCharacters(in: .whitespacesAndNewlines), fraction: session.fraction) else {
            localError = "Enter a valid value like 1.08."
            return
        }
        let draft = PriceDraft(
            commodity: CommodityRef(space: space, id: commodity),
            currency: CommodityRef(space: curSpace, id: currency),
            date: isoDate(date),
            type: type.trimmingCharacters(in: .whitespacesAndNewlines),
            value: value
        )
        Task {
            if await session.savePrice(draft) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

/// Only date, type and value are editable here -- the commodity/currency
/// pair is shown read-only; change it by deleting and recreating the price,
/// matching the web engine's own `UpdatePriceInput`.
private struct EditPriceSheet: View {
    let session: BookSession
    let price: Price

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var type: String
    @State private var valueText: String
    @State private var localError: String?

    init(session: BookSession, price: Price) {
        self.session = session
        self.price = price
        _date = State(initialValue: dateFromIso(price.date))
        _type = State(initialValue: price.type)
        _valueText = State(initialValue: session.formatted(price.value))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(price.commodity.id) in \(price.currency.id)")
                        .foregroundStyle(.secondary)
                    Text("To change the commodity or currency, delete this price and create a new one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Type (optional)", text: $type)
                    TextField("Value", text: $valueText)
                        .keyboardType(.decimalPad)
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Edit price")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private func save() {
        guard let value = try? Money.parseHalfUp(valueText.trimmingCharacters(in: .whitespacesAndNewlines), fraction: session.fraction) else {
            localError = "Enter a valid value like 1.08."
            return
        }
        let draft = PriceEditDraft(
            date: isoDate(date),
            type: type.trimmingCharacters(in: .whitespacesAndNewlines),
            value: value
        )
        Task {
            if await session.updatePrice(price.guid, with: draft) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

#Preview {
    PricesView(session: BookSession())
}
