// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A live, mutable GnuCash XML book. Keeps the original parsed element tree
/// and mutates known objects (accounts, transactions, splits) in place, so
/// prices, lots, scheduled transactions, business objects and unmodelled
/// slots survive a parse/edit/serialize round trip untouched -- unlike
/// `XMLBookWriter`, which always regenerates a minimal document from a
/// narrow `BookSnapshot` and only ever exported, never lived behind edits.
///
/// This is `BookStore`'s live model once XML (not SQLite) is the canonical
/// on-disk format; it never imports SQLite -- `SQLiteBookReader` and
/// `BookImporter` sit at that import boundary.
///
/// The tree is a hand-rolled `XNode`, not Foundation's `XMLDocument`/
/// `XMLElement`: those DOM classes exist on macOS and on Linux's
/// swift-corelibs-foundation, but not on iOS, which only ships the SAX
/// `XMLParser`. A pure-Swift tree (String/Array/Dictionary only) behaves
/// identically on every platform this app ships to or tests on.
/// One template split of a scheduled transaction: a real posting account
/// and a signed, fixed numeric amount (positive debit, negative credit).
/// Milestone-1 scope, mirroring the web's locked design
/// (`johnarleyburns/saldima#98`): formulas are written for file
/// compatibility but never evaluated -- only this fixed numeric amount is
/// used when a due instance is posted. Top-level (not nested in
/// `XMLBookDocument`) because `BookStore` passes these across the same
/// boundary `BookSnapshot`/`SnapshotSplit` already do.
struct ScheduledSplitRow: Sendable, Hashable {
    let accountGuid: Guid
    let value: Money
}

/// A schedule's end condition -- mutually exclusive on disk
/// (`sx:num-occur`/`sx:rem-occur` vs `sx:end`), `nil` for "no end".
enum ScheduledEnd: Sendable, Hashable {
    case occurrences(Int)
    case date(String)
}

/// A `gnc:schedxaction`, read back from (or about to be written to) the
/// document. `start`/`recurrence`/`templateSplits` are immutable once
/// created -- matching the web's own `UpdateScheduledTransactionInput`,
/// which patches only the six fields `updateScheduledTransaction` accepts.
struct ScheduledTransactionRow: Sendable, Hashable, Identifiable {
    let guid: Guid
    let name: String
    let enabled: Bool
    let autoCreate: Bool
    let autoCreateNotify: Bool
    let advanceCreateDays: Int
    let advanceRemindDays: Int
    let instanceCount: Int
    let start: String
    let last: String?
    let end: ScheduledEnd?
    let templateAccountGuid: Guid
    let recurrence: Recurrence
    let templateSplits: [ScheduledSplitRow]
    var id: Guid { guid }
}

/// A GnuCash `GncBudget` (desktop's "Budgets"): a recurrence plus a count of
/// periods. Per-account-per-period budgeted amounts live on the budget's own
/// KVP frame (`budgetAmount`/`setBudgetAmount`), not here -- matching real
/// GnuCash, where an unset period is simply absent, never a zero. Mirrors
/// the web engine's locked design (`johnarleyburns/saldima#102`). Milestone
/// 1 scope: no per-period notes, no book-level default-budget option, no
/// estimate-from-actuals autofill.
struct BudgetRow: Sendable, Hashable, Identifiable {
    let guid: Guid
    let name: String
    let description: String
    let periodCount: Int
    let recurrence: Recurrence
    var id: Guid { guid }
}

/// One period's `[start, end)` range, from `XMLBookDocument.periodRange`.
struct BudgetPeriodRangeRow: Sendable, Hashable {
    let start: String
    let end: String
}

/// A commodity or currency reference: GnuCash's `cmdty:space`/`cmdty:id`
/// pair (e.g. `CURRENCY`/`USD`, `NASDAQ`/`AAPL`). Shared by `XMLBookDocument`
/// and `BookStore`'s public price API -- mirrors the web engine's
/// `CommodityRef` (`johnarleyburns/saldima#104`).
public struct CommodityRef: Sendable, Hashable, Codable {
    public let space: String
    public let id: String

    public init(space: String, id: String) {
        self.space = space
        self.id = id
    }
}

/// A GnuCash `GNCPrice`: one entry in the book's price database (desktop's
/// own Price Editor / exchange-rate database), recording `value` units of
/// `currency` per unit of `commodity` as of `date`. Milestone 1 (mirrors the
/// web engine's locked design, `johnarleyburns/saldima#104`): every price
/// this engine creates carries `source == "user:price-editor"` -- no online
/// quote fetching. The commodity/currency pair is immutable once created,
/// the same convention scheduled transactions and budgets use.
struct PriceRow: Sendable, Hashable, Identifiable {
    let guid: Guid
    let commodity: CommodityRef
    let currency: CommodityRef
    /// Plain `YYYY-MM-DD`, truncated from the on-disk `HH:MM:SS +ZZZZ`
    /// timestamp -- matching `TransactionRow.date`; this engine always
    /// writes midnight UTC, so no intra-day precision is ever lost.
    let date: String
    let source: String
    /// Free text on the wire (desktop writes `last`/`bid`/`ask`/`nav`/etc.); `""` if unset.
    let type: String
    let value: Money

    var id: Guid { guid }
}

/// Thrown only by the budget engine's own computed reads
/// (`periodRange`/`budgetActual`) -- every budget mutation is otherwise
/// non-throwing, trusting `BookStore` to validate first, the same split of
/// responsibility scheduled transactions already use.
enum BudgetRangeError: Error, Equatable, Sendable {
    case unknownBudget
    case invalidPeriodIndex
    /// A period's end needs one more recurrence instance than exists --
    /// only reachable with a non-repeating ("once") recurrence, which
    /// desktop GnuCash's own budget editor never offers.
    case recurrenceExhausted
}

final class XMLBookDocument {
    struct AccountRow: Sendable, Hashable {
        let guid: Guid
        let name: String
        let type: String
        let parentGuid: Guid?
        let code: String
        let description: String
        let hidden: Bool
        let placeholder: Bool
    }

    struct SplitRow: Sendable, Hashable {
        let accountGuid: Guid
        let value: Money
        let guid: Guid?
        let memo: String
        /// `"n"` not reconciled, `"c"` cleared, `"y"` reconciled, `"v"` voided -- GnuCash's own codes.
        let reconcileState: String
        /// Set only once `reconcileState` is `"y"`; `YYYY-MM-DD HH:MM:SS +ZZZZ`.
        let reconcileDate: String?
        /// Pre-void value, set only while the parent transaction is voided.
        let voidFormerValue: Money?

        init(
            accountGuid: Guid,
            value: Money,
            guid: Guid? = nil,
            memo: String = "",
            reconcileState: String = "n",
            reconcileDate: String? = nil,
            voidFormerValue: Money? = nil
        ) {
            self.accountGuid = accountGuid
            self.value = value
            self.guid = guid
            self.memo = memo
            self.reconcileState = reconcileState
            self.reconcileDate = reconcileDate
            self.voidFormerValue = voidFormerValue
        }
    }

    struct TransactionRow: Sendable, Hashable {
        let guid: Guid
        let date: String
        let description: String
        let splits: [SplitRow]
        /// GnuCash's "Associate File/Location": a transaction-level
        /// `assoc_uri` slot. Saldima always writes a path relative to the
        /// book's own directory (so it survives the sandbox container
        /// moving between app launches), but reads whatever is there.
        let docLink: String?
        /// True once `voidTransaction` has run; every split's value is zeroed.
        let voided: Bool
        let voidReason: String?
        /// `YYYY-MM-DD HH:MM:SS +ZZZZ`, set only while voided.
        let voidTime: String?

        init(
            guid: Guid,
            date: String,
            description: String,
            splits: [SplitRow],
            docLink: String? = nil,
            voided: Bool = false,
            voidReason: String? = nil,
            voidTime: String? = nil
        ) {
            self.guid = guid
            self.date = date
            self.description = description
            self.splits = splits
            self.docLink = docLink
            self.voided = voided
            self.voidReason = voidReason
            self.voidTime = voidTime
        }
    }

    struct CurrencyInfo: Sendable, Hashable {
        let code: String
        let fullName: String
        let fraction: Int64
        let guid: Guid?
    }

    /// A `gnc:GncCustomer` business object: who an invoice is billed to.
    struct CustomerRow: Sendable, Hashable, Identifiable {
        let guid: Guid
        let name: String
        let customerNumber: String
        let addressName: String
        let addressLine1: String
        let addressLine2: String
        let phone: String
        let email: String
        let notes: String
        let active: Bool
        var id: Guid { guid }
    }

    /// A `gnc:GncEntry` line item on an invoice.
    struct InvoiceEntryRow: Sendable, Hashable, Identifiable {
        let guid: Guid
        let invoiceGuid: Guid
        let date: String
        let description: String
        let quantity: Money
        let unitPrice: Money
        let incomeAccountGuid: Guid
        var id: Guid { guid }
        var amount: Money { (try? Money.multiply(quantity, unitPrice)) ?? .zero }
    }

    /// A `gnc:GncInvoice` business object. `datePosted == nil` is a draft:
    /// desktop GnuCash's own distinction between an open and a posted
    /// invoice, mirrored here rather than invented.
    struct InvoiceRow: Sendable, Hashable, Identifiable {
        let guid: Guid
        let invoiceNumber: String
        let customerGuid: Guid
        let dateOpened: String
        let datePosted: String?
        let notes: String
        let active: Bool
        let postedTransactionGuid: Guid?
        let receivableAccountGuid: Guid?
        var id: Guid { guid }
        var isPosted: Bool { datePosted != nil }
    }

    /// A `gnc:GncVendor` business object: who a bill is owed to.
    struct VendorRow: Sendable, Hashable, Identifiable {
        let guid: Guid
        let name: String
        let vendorNumber: String
        let addressLine1: String
        let phone: String
        let email: String
        let notes: String
        let active: Bool
        var id: Guid { guid }
    }

    /// A `gnc:GncEntry` line item on a bill, using its bill-side fields
    /// (`entry:bill`/`entry:b-acct`/`entry:b-price`) -- distinct from an
    /// invoice line's `entry:invoice`/`entry:i-acct`/`entry:i-price`, even
    /// though both share the same element.
    struct BillEntryRow: Sendable, Hashable, Identifiable {
        let guid: Guid
        let billGuid: Guid
        let date: String
        let description: String
        let quantity: Money
        let unitPrice: Money
        let expenseAccountGuid: Guid
        var id: Guid { guid }
        var amount: Money { (try? Money.multiply(quantity, unitPrice)) ?? .zero }
    }

    /// A vendor bill: GnuCash stores it as a `gnc:GncInvoice` exactly like
    /// a customer invoice, distinguished only by `invoice:owner`'s
    /// `owner:type` (`"gncVendor"` here, `"gncCustomer"` for an invoice).
    struct BillRow: Sendable, Hashable, Identifiable {
        let guid: Guid
        let billNumber: String
        let vendorGuid: Guid
        let dateOpened: String
        let datePosted: String?
        let notes: String
        let active: Bool
        let postedTransactionGuid: Guid?
        let payableAccountGuid: Guid?
        var id: Guid { guid }
        var isPosted: Bool { datePosted != nil }
    }

    private let root: XNode
    private let book: XNode
    private var accountIndex: [Guid: XNode] = [:]
    private var transactionIndex: [Guid: XNode] = [:]
    private var customerIndex: [Guid: XNode] = [:]
    private var invoiceIndex: [Guid: XNode] = [:]
    private var vendorIndex: [Guid: XNode] = [:]
    private var scheduledTransactionIndex: [Guid: XNode] = [:]
    private var budgetIndex: [Guid: XNode] = [:]
    private var priceIndex: [Guid: XNode] = [:]

    /// Decoded `transactions()` result, memoized until a mutation that could
    /// change it invalidates the cache by setting this back to `nil`. `nil`
    /// doubles as the dirty flag -- there is no separate bool to keep in
    /// sync, matching how `accountIndex`/`transactionIndex` above are the
    /// only record of whether this document's indexes are current.
    private var cachedTransactions: [TransactionRow]?

    /// Counts every real `transactionRow` decode, independent of how many
    /// times `transactions()`/`balances()` are called. Exposed only for
    /// tests to assert the cache is actually skipping redundant decodes --
    /// a deterministic alternative to timing the call, which would be flaky.
    private(set) var transactionDecodeCountForTesting = 0

    private init(root: XNode, book: XNode) {
        self.root = root
        self.book = book
        reindex()
    }

    // MARK: - Loading

    static func parse(data: Data) throws -> XMLBookDocument {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw BookFormatError.malformedXML
        }
        let root: XNode
        do {
            root = try parseXMLTree(xml)
        } catch {
            throw BookFormatError.malformedXML
        }
        guard let book = findDescendant(root, localName: "book") else {
            throw BookFormatError.malformedXML
        }
        return XMLBookDocument(root: root, book: book)
    }

    /// Builds a fresh document from a format-neutral snapshot (an XML file
    /// another reader produced, or a SQLite-dialect file `SQLiteBookReader`
    /// converted) -- the import/materialize boundary.
    static func build(
        from snapshot: BookSnapshot,
        templateRootGuid: Guid,
        ids: any IDGenerator
    ) -> XMLBookDocument {
        let currencyCode = snapshot.currencyCode ?? "USD"
        let fraction = snapshot.fraction ?? 100

        let root = XNode(name: "#document")
        let gncRoot = XNode(name: "gnc-v2", attributes: namespaceAttributes)
        root.addChild(gncRoot)

        let countData = leaf("gnc:count-data", "1", attributes: ["cd:type": "book"])
        gncRoot.addChild(countData)

        let book = XNode(name: "gnc:book", attributes: ["version": "2.0.0"])
        gncRoot.addChild(book)

        book.addChild(leaf("book:id", snapshot.bookGuid.rawValue, attributes: ["type": "guid"]))

        let currencyCommodity = XNode(name: "gnc:commodity", attributes: ["version": "2.0.0"])
        currencyCommodity.addChild(leaf("cmdty:space", "CURRENCY"))
        currencyCommodity.addChild(leaf("cmdty:id", currencyCode))
        currencyCommodity.addChild(leaf("cmdty:fraction", String(fraction)))
        book.addChild(currencyCommodity)

        let rootAccount = snapshot.accounts.first { $0.type == "ROOT" }
        let rootGuid = rootAccount?.guid ?? ids.guid()
        book.addChild(accountNode(
            guid: rootGuid,
            name: rootAccount?.name ?? "Root Account",
            type: "ROOT",
            parentGuid: nil,
            code: "",
            description: "",
            hidden: false,
            placeholder: false
        ))
        book.addChild(accountNode(
            guid: templateRootGuid,
            name: "Template Root",
            type: "ROOT",
            parentGuid: nil,
            code: "",
            description: "",
            hidden: false,
            placeholder: false
        ))

        for account in snapshot.accounts where account.guid != rootGuid {
            book.addChild(accountNode(
                guid: account.guid,
                name: account.name,
                type: account.type,
                parentGuid: account.parentGuid,
                code: account.code,
                description: account.description,
                hidden: account.hidden,
                placeholder: account.placeholder
            ))
        }

        for transaction in snapshot.transactions {
            let splits = transaction.splits.map { split in
                (guid: ids.guid(), accountGuid: split.accountGuid, value: split.value)
            }
            book.addChild(transactionNode(
                guid: transaction.guid,
                date: transaction.date,
                description: transaction.description,
                splits: splits
            ))
        }

        return XMLBookDocument(root: root, book: book)
    }

    func serialize() -> Data {
        var output = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n"
        for child in root.children {
            serializeNode(child, into: &output)
        }
        return Data(output.utf8)
    }

    // MARK: - Reading

    private func reindex() {
        invalidateTransactionsCache()
        accountIndex.removeAll()
        transactionIndex.removeAll()
        customerIndex.removeAll()
        invoiceIndex.removeAll()
        vendorIndex.removeAll()
        for node in children(book, localName: "account") {
            if let guid = guidValue(node, localName: "id") {
                accountIndex[guid] = node
            }
        }
        for node in children(book, localName: "transaction") {
            if let guid = guidValue(node, localName: "id") {
                transactionIndex[guid] = node
            }
        }
        for node in children(book, localName: "GncCustomer") {
            if let guid = guidValue(node, localName: "guid") {
                customerIndex[guid] = node
            }
        }
        // Customer invoices and vendor bills are both `gnc:GncInvoice`,
        // distinguished only by `invoice:owner`'s `owner:type` -- this
        // index holds both; `invoices()`/`bills()` filter by owner type.
        for node in children(book, localName: "GncInvoice") {
            if let guid = guidValue(node, localName: "guid") {
                invoiceIndex[guid] = node
            }
        }
        for node in children(book, localName: "GncVendor") {
            if let guid = guidValue(node, localName: "guid") {
                vendorIndex[guid] = node
            }
        }
        scheduledTransactionIndex.removeAll()
        for node in children(book, localName: "schedxaction") {
            if let guid = guidValue(node, localName: "id") {
                scheduledTransactionIndex[guid] = node
            }
        }
        budgetIndex.removeAll()
        for node in children(book, localName: "budget") {
            if let guid = guidValue(node, localName: "id") {
                budgetIndex[guid] = node
            }
        }
        priceIndex.removeAll()
        if let pricedbNode = firstChild(book, localName: "pricedb") {
            for node in children(pricedbNode, localName: "price") {
                if let guid = guidValue(node, localName: "id") {
                    priceIndex[guid] = node
                }
            }
        }
    }

    private func ownerType(_ node: XNode) -> String? {
        firstChild(node, localName: "owner").flatMap { firstChild($0, localName: "type") }.map(decodedText)
    }

    var bookGuid: Guid? {
        guard let idNode = firstChild(book, localName: "id") else { return nil }
        return Guid(decodedText(idNode))
    }

    func accounts() -> [AccountRow] {
        children(book, localName: "account").compactMap(accountRow)
    }

    func account(_ guid: Guid) -> AccountRow? {
        accountIndex[guid].flatMap(accountRow)
    }

    private func accountRow(_ node: XNode) -> AccountRow? {
        guard let guid = guidValue(node, localName: "id"),
              let name = firstChild(node, localName: "name").map(decodedText),
              let type = firstChild(node, localName: "type").map(decodedText)
        else {
            return nil
        }
        let parent = guidValue(node, localName: "parent")
        let code = firstChild(node, localName: "code").map(decodedText) ?? ""
        let description = firstChild(node, localName: "description").map(decodedText) ?? ""
        let (hidden, placeholder) = readFlags(node)
        return AccountRow(
            guid: guid,
            name: name,
            type: type,
            parentGuid: parent,
            code: code,
            description: description,
            hidden: hidden,
            placeholder: placeholder
        )
    }

    private func readFlags(_ accountNode: XNode) -> (hidden: Bool, placeholder: Bool) {
        guard let slots = firstChild(accountNode, localName: "slots") else { return (false, false) }
        var hidden = false
        var placeholder = false
        for slot in children(slots, localName: "slot") {
            guard let key = firstChild(slot, localName: "key").map(decodedText) else { continue }
            let value = firstChild(slot, localName: "value").map(decodedText) ?? ""
            if key == "hidden" { hidden = value == "true" }
            if key == "placeholder" { placeholder = value == "true" }
        }
        return (hidden, placeholder)
    }

    /// The CURRENCY-namespace commodity GnuCash would show first, preferring
    /// USD when more than one exists (matches the SQLite-era query order).
    func currency() -> CurrencyInfo? {
        let commodities = children(book, localName: "commodity").filter { commodity in
            firstChild(commodity, localName: "space").map(decodedText) == "CURRENCY"
        }
        guard !commodities.isEmpty else { return nil }
        let chosen = commodities.first { firstChild($0, localName: "id").map(decodedText) == "USD" }
            ?? commodities[0]
        guard let code = firstChild(chosen, localName: "id").map(decodedText) else { return nil }
        let fullName = firstChild(chosen, localName: "name").map(decodedText) ?? code
        let fraction = firstChild(chosen, localName: "fraction").map(decodedText).flatMap(Int64.init) ?? 100
        return CurrencyInfo(code: code, fullName: fullName, fraction: fraction, guid: nil)
    }

    /// The transactions, newest first; splits within a transaction keep
    /// document order. Decoding every transaction's and split's text fields
    /// from the underlying XML tree is the hot path `balances()` and the
    /// budget/report readers below all share, so the result is memoized in
    /// `cachedTransactions` until a mutation invalidates it -- see
    /// `invalidateTransactionsCache()`.
    func transactions() -> [TransactionRow] {
        if let cachedTransactions { return cachedTransactions }
        let decoded = children(book, localName: "transaction")
            .compactMap(transactionRow)
            .sorted { $0.date > $1.date || ($0.date == $1.date && $0.guid.rawValue > $1.guid.rawValue) }
        cachedTransactions = decoded
        return decoded
    }

    func transaction(_ guid: Guid) -> TransactionRow? {
        transactionIndex[guid].flatMap(transactionRow)
    }

    /// Clears the memoized `transactions()` result. Called by every method
    /// that mutates a `gnc:transaction` node's decoded fields (posting,
    /// reconciling, voiding/unvoiding, doc-linking, deleting) -- not just on
    /// save, since `transactions()`/`balances()` can be called again before
    /// the next save.
    private func invalidateTransactionsCache() {
        cachedTransactions = nil
    }

    private func transactionRow(_ node: XNode) -> TransactionRow? {
        transactionDecodeCountForTesting += 1
        guard let guid = guidValue(node, localName: "id"),
              let description = firstChild(node, localName: "description").map(decodedText)
        else {
            return nil
        }
        let date = firstChild(node, localName: "date-posted")
            .flatMap { firstChild($0, localName: "date") }
            .map(decodedText)
            .map { String($0.prefix(10)) } ?? ""
        let splitsContainer = firstChild(node, localName: "splits")
        let splits = children(splitsContainer ?? node, localName: "split").compactMap { splitNode -> SplitRow? in
            guard let account = guidValue(splitNode, localName: "account"),
                  let valueText = firstChild(splitNode, localName: "value").map(decodedText),
                  let value = rational(valueText)
            else {
                return nil
            }
            let splitGuid = guidValue(splitNode, localName: "id")
            let memo = firstChild(splitNode, localName: "memo").map(decodedText) ?? ""
            let reconcileStateText = firstChild(splitNode, localName: "reconciled-state").map(decodedText)
            let reconcileState = (reconcileStateText?.isEmpty ?? true) ? "n" : reconcileStateText!
            let reconcileDate = firstChild(splitNode, localName: "reconcile-date")
                .flatMap { firstChild($0, localName: "date") }
                .map(decodedText)
            return SplitRow(
                accountGuid: account,
                value: value,
                guid: splitGuid,
                memo: memo,
                reconcileState: reconcileState,
                reconcileDate: reconcileDate,
                voidFormerValue: readNumericSlot(splitNode, key: "void-former-value")
            )
        }
        let docLink = firstChild(node, localName: "slots")
            .map { children($0, localName: "slot") }
            .flatMap { slots in
                slots.first { firstChild($0, localName: "key").map(decodedText) == "assoc_uri" }
            }
            .flatMap { firstChild($0, localName: "value") }
            .map(decodedText)
        return TransactionRow(
            guid: guid,
            date: date,
            description: description,
            splits: splits,
            docLink: docLink,
            voided: readStringSlot(node, key: "void-time") != nil,
            voidReason: readStringSlot(node, key: "void-reason"),
            voidTime: readStringSlot(node, key: "void-time")
        )
    }

    /// Sums each account's split value (the book currency amount); not
    /// rolled up to parents.
    func balances() -> [Guid: Money] {
        var totals: [Guid: Money] = [:]
        for transaction in transactions() {
            for split in transaction.splits {
                let running = totals[split.accountGuid] ?? .zero
                totals[split.accountGuid] = (try? Money.add(running, split.value)) ?? running
            }
        }
        return totals
    }

    // MARK: - Reading: scheduled transactions

    func scheduledTransactions() -> [ScheduledTransactionRow] {
        children(book, localName: "schedxaction").compactMap(scheduledTransactionRow)
    }

    func scheduledTransaction(_ guid: Guid) -> ScheduledTransactionRow? {
        scheduledTransactionIndex[guid].flatMap(scheduledTransactionRow)
    }

    private func scheduledTransactionRow(_ node: XNode) -> ScheduledTransactionRow? {
        guard let guid = guidValue(node, localName: "id"),
              let name = firstChild(node, localName: "name").map(decodedText),
              let templateAccountGuid = guidValue(node, localName: "templ-acct"),
              let startNode = firstChild(node, localName: "start"),
              let start = gdateValue(startNode),
              let scheduleNode = firstChild(node, localName: "schedule"),
              let recurrenceNode = firstChild(scheduleNode, localName: "recurrence"),
              let multiplier = firstChild(recurrenceNode, localName: "mult").map(decodedText).flatMap(Int.init),
              let periodTypeText = firstChild(recurrenceNode, localName: "period_type").map(decodedText),
              let periodType = PeriodType(xmlValue: periodTypeText),
              let recurrenceStartNode = firstChild(recurrenceNode, localName: "start"),
              let recurrenceStart = gdateValue(recurrenceStartNode)
        else {
            return nil
        }

        let enabled = firstChild(node, localName: "enabled").map(decodedText) != "n"
        let autoCreate = firstChild(node, localName: "autoCreate").map(decodedText) == "y"
        let autoCreateNotify = firstChild(node, localName: "autoCreateNotify").map(decodedText) == "y"
        let advanceCreateDays = firstChild(node, localName: "advanceCreateDays").map(decodedText).flatMap(Int.init) ?? 0
        let advanceRemindDays = firstChild(node, localName: "advanceRemindDays").map(decodedText).flatMap(Int.init) ?? 0
        let instanceCount = firstChild(node, localName: "instanceCount").map(decodedText).flatMap(Int.init) ?? 0
        let last = firstChild(node, localName: "last").flatMap(gdateValue)

        var end: ScheduledEnd?
        if let numOccur = firstChild(node, localName: "num-occur").map(decodedText).flatMap(Int.init) {
            end = .occurrences(numOccur)
        } else if let endNode = firstChild(node, localName: "end"), let endDate = gdateValue(endNode) {
            end = .date(endDate)
        }

        let weekendAdjustText = firstChild(recurrenceNode, localName: "weekend_adj").map(decodedText)
        let weekendAdjust = weekendAdjustText.flatMap { WeekendAdjust(rawValue: $0) } ?? .none
        let recurrence = Recurrence(
            periodType: periodType,
            multiplier: multiplier,
            start: recurrenceStart,
            weekendAdjust: weekendAdjust
        )

        return ScheduledTransactionRow(
            guid: guid,
            name: name,
            enabled: enabled,
            autoCreate: autoCreate,
            autoCreateNotify: autoCreateNotify,
            advanceCreateDays: advanceCreateDays,
            advanceRemindDays: advanceRemindDays,
            instanceCount: instanceCount,
            start: start,
            last: last,
            end: end,
            templateAccountGuid: templateAccountGuid,
            recurrence: recurrence,
            templateSplits: templateTransactionSplits(forTemplateAccount: templateAccountGuid)
        )
    }

    /// Finds the one template transaction whose splits post to
    /// `templateAccountGuid` and recovers each split's real posting account
    /// and signed amount from its `sched-xaction` KVP frame -- the formula
    /// strings are written for file compatibility but never read back
    /// here, matching Milestone 1's "formulas are never evaluated" scope.
    private func templateTransactionSplits(forTemplateAccount templateAccountGuid: Guid) -> [ScheduledSplitRow] {
        guard let wrapper = firstChild(book, localName: "template-transactions") else { return [] }
        guard
            let templateTx = children(wrapper, localName: "transaction").first(where: { tx in
                let splitsContainer = firstChild(tx, localName: "splits") ?? tx
                return children(splitsContainer, localName: "split")
                    .contains { guidValue($0, localName: "account") == templateAccountGuid }
            })
        else {
            return []
        }
        let splitsContainer = firstChild(templateTx, localName: "splits") ?? templateTx
        return children(splitsContainer, localName: "split").compactMap { splitNode -> ScheduledSplitRow? in
            guard let splitSlots = firstChild(splitNode, localName: "slots"),
                  let schedSlot = children(splitSlots, localName: "slot").first(where: {
                      firstChild($0, localName: "key").map(decodedText) == "sched-xaction"
                  }),
                  let frame = firstChild(schedSlot, localName: "value"),
                  let accountGuid = frameGuidValue(frame, key: "account")
            else {
                return nil
            }
            let debitFormula = frameStringValue(frame, key: "debit-formula") ?? ""
            let creditFormula = frameStringValue(frame, key: "credit-formula") ?? ""
            let value: Money
            if !debitFormula.isEmpty {
                value = frameRationalValue(frame, key: "debit-numeric") ?? .zero
            } else if !creditFormula.isEmpty {
                value = (frameRationalValue(frame, key: "credit-numeric") ?? .zero).negated()
            } else {
                value = .zero
            }
            return ScheduledSplitRow(accountGuid: accountGuid, value: value)
        }
    }

    private func frameSlotValue(_ frame: XNode, key: String) -> XNode? {
        children(frame, localName: "slot")
            .first { firstChild($0, localName: "key").map(decodedText) == key }
            .flatMap { firstChild($0, localName: "value") }
    }

    private func frameStringValue(_ frame: XNode, key: String) -> String? {
        frameSlotValue(frame, key: key).map(decodedText)
    }

    private func frameGuidValue(_ frame: XNode, key: String) -> Guid? {
        frameSlotValue(frame, key: key).map(decodedText).flatMap(Guid.init)
    }

    private func frameRationalValue(_ frame: XNode, key: String) -> Money? {
        frameSlotValue(frame, key: key).map(decodedText).flatMap(rational)
    }

    private func gdateValue(_ wrapperNode: XNode) -> String? {
        firstChild(wrapperNode, localName: "gdate").map(decodedText)
    }

    // MARK: - Mutating: scheduled transactions

    /// Creates the lazily-shared `Template Root` (and its
    /// `gnc:template-transactions` wrapper) the first time any schedule is
    /// created in this book, or returns the existing one. Found by
    /// scanning *inside the wrapper* for a `ROOT` account, never by a
    /// fixed GUID -- the same way a reparsed file finds it again, and the
    /// same way the web's own `xml-document.ts` discovers it.
    private func ensureTemplateRoot(ids: any IDGenerator) -> Guid {
        let wrapper = firstChild(book, localName: "template-transactions") ?? {
            let created = XNode(name: "gnc:template-transactions")
            book.addChild(created)
            return created
        }()
        if let existing = children(wrapper, localName: "account").first(where: {
            firstChild($0, localName: "type").map(decodedText) == "ROOT"
        }), let existingGuid = guidValue(existing, localName: "id") {
            return existingGuid
        }
        let rootGuid = ids.guid()
        wrapper.addChild(Self.templateAccountNode(guid: rootGuid, name: "Template Root", type: "ROOT", parentGuid: nil))
        return rootGuid
    }

    /// Creates a `gnc:schedxaction` plus its backing per-schedule template
    /// account and template transaction, mirroring the web's locked XML
    /// shape byte-for-byte (`johnarleyburns/saldima#98`). Validation
    /// (split count, zero-sum, known accounts) is `BookStore`'s job, the
    /// same split of responsibility `post`/`postTransaction` already use.
    @discardableResult
    func createScheduledTransaction(
        guid: Guid,
        name: String,
        enabled: Bool,
        autoCreate: Bool,
        autoCreateNotify: Bool,
        advanceCreateDays: Int,
        advanceRemindDays: Int,
        start: String,
        end: ScheduledEnd?,
        recurrence: Recurrence,
        templateSplits: [ScheduledSplitRow],
        currencyCode: String,
        currencyFraction: Int64,
        ids: any IDGenerator
    ) -> ScheduledTransactionRow {
        let templateRootGuid = ensureTemplateRoot(ids: ids)
        let wrapper = firstChild(book, localName: "template-transactions")!

        let templateAccountGuid = ids.guid()
        wrapper.addChild(Self.templateAccountNode(
            guid: templateAccountGuid,
            name: templateAccountGuid.rawValue,
            type: "BANK",
            parentGuid: templateRootGuid
        ))

        let splitNodes = templateSplits.map { split in
            Self.templateSplitNode(
                guid: ids.guid(),
                templateAccountGuid: templateAccountGuid,
                realAccountGuid: split.accountGuid,
                value: split.value,
                fraction: currencyFraction
            )
        }
        wrapper.addChild(Self.templateTransactionNode(
            guid: ids.guid(),
            currencyCode: currencyCode,
            start: start,
            name: name,
            splitNodes: splitNodes
        ))

        book.addChild(Self.schedxactionNode(
            guid: guid,
            name: name,
            enabled: enabled,
            autoCreate: autoCreate,
            autoCreateNotify: autoCreateNotify,
            advanceCreateDays: advanceCreateDays,
            advanceRemindDays: advanceRemindDays,
            start: start,
            end: end,
            templateAccountGuid: templateAccountGuid,
            recurrence: recurrence
        ))

        reindex()
        return scheduledTransaction(guid)!
    }

    /// Patches the same restricted field set the web's own
    /// `UpdateScheduledTransactionInput` allows -- `start`/`end`/
    /// `recurrence`/template splits are immutable after creation (delete
    /// and recreate instead), matching web exactly.
    func updateScheduledTransaction(
        _ guid: Guid,
        name: String,
        enabled: Bool,
        autoCreate: Bool,
        autoCreateNotify: Bool,
        advanceCreateDays: Int,
        advanceRemindDays: Int
    ) {
        guard let node = scheduledTransactionIndex[guid] else { return }
        setChildText(node, localName: "name", tag: "sx:name", value: name)
        setChildText(node, localName: "enabled", tag: "sx:enabled", value: enabled ? "y" : "n")
        setChildText(node, localName: "autoCreate", tag: "sx:autoCreate", value: autoCreate ? "y" : "n")
        setChildText(node, localName: "autoCreateNotify", tag: "sx:autoCreateNotify", value: autoCreateNotify ? "y" : "n")
        setChildText(node, localName: "advanceCreateDays", tag: "sx:advanceCreateDays", value: String(advanceCreateDays))
        setChildText(node, localName: "advanceRemindDays", tag: "sx:advanceRemindDays", value: String(advanceRemindDays))
    }

    /// Removes the schedule's own template transaction and per-schedule
    /// template account, but leaves the shared `Template Root` (and any
    /// other schedule's template) alone.
    func deleteScheduledTransaction(_ guid: Guid) {
        guard let node = scheduledTransactionIndex[guid] else { return }
        if let templateAccountGuid = guidValue(node, localName: "templ-acct"),
           let wrapper = firstChild(book, localName: "template-transactions")
        {
            if let templateTx = children(wrapper, localName: "transaction").first(where: { tx in
                let splitsContainer = firstChild(tx, localName: "splits") ?? tx
                return children(splitsContainer, localName: "split")
                    .contains { guidValue($0, localName: "account") == templateAccountGuid }
            }) {
                templateTx.detach()
            }
            if let templateAccount = children(wrapper, localName: "account").first(where: {
                guidValue($0, localName: "id") == templateAccountGuid
            }) {
                templateAccount.detach()
            }
        }
        node.detach()
        scheduledTransactionIndex.removeValue(forKey: guid)
    }

    /// Records that an instance due on `date` was posted or skipped:
    /// `sx:last` is inserted once, right after `sx:start`, then only ever
    /// overwritten in place -- never duplicated -- and `sx:instanceCount`
    /// increments. Never touches `sx:rem-occur` (write-only, kept for file
    /// compatibility; the real exhaustion check compares `instanceCount`).
    func advanceScheduledTransaction(_ guid: Guid, to date: String) {
        guard let node = scheduledTransactionIndex[guid] else { return }
        if let lastNode = firstChild(node, localName: "last") {
            firstChild(lastNode, localName: "gdate")?.text = escapeXml(date)
        } else if let startNode = firstChild(node, localName: "start"), let startIndex = startNode.indexInParent {
            node.insertChild(Self.gdateNode(tag: "sx:last", date: date), at: startIndex + 1)
        } else {
            node.addChild(Self.gdateNode(tag: "sx:last", date: date))
        }
        let currentCount = firstChild(node, localName: "instanceCount").map(decodedText).flatMap(Int.init) ?? 0
        setChildText(node, localName: "instanceCount", tag: "sx:instanceCount", value: String(currentCount + 1))
    }

    // MARK: - Reading: budgets

    func budgets() -> [BudgetRow] {
        children(book, localName: "budget").compactMap(budgetRow)
    }

    func budget(_ guid: Guid) -> BudgetRow? {
        budgetIndex[guid].flatMap(budgetRow)
    }

    private func budgetRow(_ node: XNode) -> BudgetRow? {
        guard let guid = guidValue(node, localName: "id"),
              let name = firstChild(node, localName: "name").map(decodedText),
              let periodCount = firstChild(node, localName: "num-periods").map(decodedText).flatMap(Int.init),
              // Unlike sx:schedule's inner gnc:recurrence, bgt:recurrence carries
              // the recurrence:* children directly -- no further unwrapping.
              let recurrenceNode = firstChild(node, localName: "recurrence"),
              let multiplier = firstChild(recurrenceNode, localName: "mult").map(decodedText).flatMap(Int.init),
              let periodTypeText = firstChild(recurrenceNode, localName: "period_type").map(decodedText),
              let periodType = PeriodType(xmlValue: periodTypeText),
              let recurrenceStartNode = firstChild(recurrenceNode, localName: "start"),
              let recurrenceStart = gdateValue(recurrenceStartNode)
        else {
            return nil
        }
        let description = firstChild(node, localName: "description").map(decodedText) ?? ""
        let weekendAdjustText = firstChild(recurrenceNode, localName: "weekend_adj").map(decodedText)
        let weekendAdjust = weekendAdjustText.flatMap { WeekendAdjust(rawValue: $0) } ?? .none
        return BudgetRow(
            guid: guid,
            name: name,
            description: description,
            periodCount: periodCount,
            recurrence: Recurrence(
                periodType: periodType,
                multiplier: multiplier,
                start: recurrenceStart,
                weekendAdjust: weekendAdjust
            )
        )
    }

    /// Period *N*'s `[start, end)` range: `instance(N)` to `instance(N+1)`,
    /// where `instance(0)` is the recurrence's own start and `instance(k)`
    /// is `nextInstance` applied `k` times -- matching desktop GnuCash's
    /// `recurrenceGetPeriodTime`, and the web engine's own `periodRange`.
    func periodRange(_ budget: BudgetRow, periodIndex: Int) throws -> BudgetPeriodRangeRow {
        guard periodIndex >= 0 else { throw BudgetRangeError.invalidPeriodIndex }
        return BudgetPeriodRangeRow(
            start: try nthRecurrenceInstance(budget.recurrence, index: periodIndex),
            end: try nthRecurrenceInstance(budget.recurrence, index: periodIndex + 1)
        )
    }

    private func nthRecurrenceInstance(_ recurrence: Recurrence, index: Int) throws -> String {
        var date = recurrence.start
        for _ in 0..<index {
            guard let next = try nextInstance(recurrence, after: date) else {
                throw BudgetRangeError.recurrenceExhausted
            }
            date = next
        }
        return date
    }

    /// The budget's own per-account KVP frame (`bgt:slots` -> one `slot`
    /// keyed by the account's guid, `type="frame"`, holding one nested
    /// `slot` per set period keyed by its number) -- the exact shape
    /// `make_period_data_path` writes in desktop GnuCash's own
    /// `gnc-budget.cpp`. `nil` if the account has never had an amount set.
    private func findBudgetAccountFrame(_ budgetNode: XNode, accountGuid: Guid) -> XNode? {
        guard let slots = firstChild(budgetNode, localName: "slots"),
              let accountSlot = findSlot(slots, key: accountGuid.rawValue)
        else {
            return nil
        }
        return firstChild(accountSlot, localName: "value")
    }

    /// Creates `bgt:slots` the first time any amount is set on this budget
    /// -- it never exists right after `createBudget`, matching the web
    /// engine's optional `bgt:slots` (present only once something sets it).
    private func findOrCreateSlots(_ owner: XNode, tag: String) -> XNode {
        if let existing = firstChild(owner, localName: "slots") { return existing }
        let created = XNode(name: "\(tag):slots")
        owner.addChild(created)
        return created
    }

    private func findOrCreateBudgetAccountFrame(_ budgetNode: XNode, accountGuid: Guid) -> XNode {
        let slots = findOrCreateSlots(budgetNode, tag: "bgt")
        if let frame = findBudgetAccountFrame(budgetNode, accountGuid: accountGuid) { return frame }
        let frame = XNode(name: "slot:value", attributes: ["type": "frame"])
        slots.addChild(Self.kvpSlot(accountGuid.rawValue, frame))
        return frame
    }

    /// Removes the whole per-account frame once its last period is cleared.
    private func removeBudgetAccountFrameIfEmpty(_ budgetNode: XNode, accountGuid: Guid) {
        guard let slots = firstChild(budgetNode, localName: "slots"),
              let accountSlot = findSlot(slots, key: accountGuid.rawValue),
              let frame = firstChild(accountSlot, localName: "value"),
              frame.children.isEmpty
        else {
            return
        }
        accountSlot.detach()
    }

    /// `nil` if this account's period has never been set -- never a zero placeholder.
    func budgetAmount(_ budgetGuid: Guid, accountGuid: Guid, periodIndex: Int) -> Money? {
        guard let budgetNode = budgetIndex[budgetGuid],
              let frame = findBudgetAccountFrame(budgetNode, accountGuid: accountGuid)
        else {
            return nil
        }
        let periodKey = String(periodIndex)
        guard
            let slot = children(frame, localName: "slot")
                .first(where: { firstChild($0, localName: "key").map(decodedText) == periodKey }),
            let valueNode = firstChild(slot, localName: "value")
        else {
            return nil
        }
        return rational(decodedText(valueNode))
    }

    /// Sum of this account's split values whose transaction date falls in
    /// the period's `[start, end)` range. Desktop GnuCash computes
    /// "actual" the same way every time, live -- it's never stored.
    func budgetActual(_ budgetGuid: Guid, accountGuid: Guid, periodIndex: Int) throws -> Money {
        guard let budget = budget(budgetGuid) else { throw BudgetRangeError.unknownBudget }
        let range = try periodRange(budget, periodIndex: periodIndex)
        var total = Money.zero
        for transaction in transactions() {
            guard transaction.date >= range.start, transaction.date < range.end else { continue }
            for split in transaction.splits where split.accountGuid == accountGuid {
                total = (try? Money.add(total, split.value)) ?? total
            }
        }
        return total
    }

    // MARK: - Mutating: budgets

    /// `<gnc:budget version="2.0.0">` in the web's exact child order: id,
    /// name, description, num-periods, recurrence, [slots -- optional,
    /// created lazily by the first `setBudgetAmount`].
    @discardableResult
    func createBudget(
        guid: Guid,
        name: String,
        description: String,
        periodCount: Int,
        recurrence: Recurrence
    ) -> BudgetRow {
        let node = XNode(name: "gnc:budget", attributes: ["version": "2.0.0"])
        node.addChild(leaf("bgt:id", guid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("bgt:name", name))
        node.addChild(leaf("bgt:description", description))
        node.addChild(leaf("bgt:num-periods", String(periodCount)))
        node.addChild(Self.buildBudgetRecurrenceNode(recurrence))
        book.addChild(node)
        budgetIndex[guid] = node
        return budgetRow(node)!
    }

    /// Patches name, description and periodCount only -- the recurrence is
    /// immutable after creation, matching the web engine's own
    /// `UpdateBudgetInput` and the same convention scheduled transactions use.
    func updateBudget(_ guid: Guid, name: String, description: String, periodCount: Int) {
        guard let node = budgetIndex[guid] else { return }
        setChildText(node, localName: "name", tag: "bgt:name", value: name)
        setChildText(node, localName: "description", tag: "bgt:description", value: description)
        setChildText(node, localName: "num-periods", tag: "bgt:num-periods", value: String(periodCount))
    }

    func deleteBudget(_ guid: Guid) {
        guard let node = budgetIndex[guid] else { return }
        node.detach()
        budgetIndex.removeValue(forKey: guid)
    }

    /// Sets (or, with `amount: nil`, removes) one account's budgeted amount
    /// for one period. Matching real GnuCash: an unset period is simply
    /// absent from the KVP tree, never a zero placeholder.
    func setBudgetAmount(_ budgetGuid: Guid, accountGuid: Guid, periodIndex: Int, amount: Money?) {
        guard let budgetNode = budgetIndex[budgetGuid] else { return }
        let periodKey = String(periodIndex)

        guard let amount else {
            guard let frame = findBudgetAccountFrame(budgetNode, accountGuid: accountGuid) else { return }
            if let existing = children(frame, localName: "slot")
                .first(where: { firstChild($0, localName: "key").map(decodedText) == periodKey })
            {
                existing.detach()
            }
            removeBudgetAccountFrameIfEmpty(budgetNode, accountGuid: accountGuid)
            return
        }

        let frame = findOrCreateBudgetAccountFrame(budgetNode, accountGuid: accountGuid)
        let valueText = "\(amount.num)/\(amount.denom)"
        if let existing = children(frame, localName: "slot")
            .first(where: { firstChild($0, localName: "key").map(decodedText) == periodKey })
        {
            firstChild(existing, localName: "value")?.text = escapeXml(valueText)
        } else {
            let slot = XNode(name: "slot")
            slot.addChild(leaf("slot:key", periodKey))
            slot.addChild(leaf("slot:value", valueText, attributes: ["type": "numeric"]))
            frame.addChild(slot)
        }
    }

    /// `<bgt:recurrence version="1.0.0">` carries the `recurrence:*`
    /// children directly -- unlike `sx:schedule`'s inner `gnc:recurrence`,
    /// budgets have no separate wrapper element at all, confirmed against
    /// desktop GnuCash's own `gnc-budget-xml-v2.cpp`.
    private static func buildBudgetRecurrenceNode(_ recurrence: Recurrence) -> XNode {
        let node = XNode(name: "bgt:recurrence", attributes: ["version": "1.0.0"])
        node.addChild(leaf("recurrence:mult", String(recurrence.multiplier)))
        node.addChild(leaf("recurrence:period_type", recurrence.periodType.xmlValue))
        node.addChild(gdateNode(tag: "recurrence:start", date: recurrence.start))
        if recurrence.weekendAdjust != .none {
            node.addChild(leaf("recurrence:weekend_adj", recurrence.weekendAdjust.rawValue))
        }
        return node
    }

    // MARK: - Reading: prices

    private func findPricedbNode() -> XNode? {
        firstChild(book, localName: "pricedb")
    }

    func prices() -> [PriceRow] {
        guard let pricedbNode = findPricedbNode() else { return [] }
        return children(pricedbNode, localName: "price").compactMap(priceRow)
    }

    func price(_ guid: Guid) -> PriceRow? {
        priceIndex[guid].flatMap(priceRow)
    }

    private func readCommodityRef(_ parent: XNode, localName name: String) -> CommodityRef? {
        guard let node = firstChild(parent, localName: name),
              let space = firstChild(node, localName: "space").map(decodedText),
              let id = firstChild(node, localName: "id").map(decodedText)
        else {
            return nil
        }
        return CommodityRef(space: space, id: id)
    }

    private func priceRow(_ node: XNode) -> PriceRow? {
        guard let guid = guidValue(node, localName: "id"),
              let commodity = readCommodityRef(node, localName: "commodity"),
              let currency = readCommodityRef(node, localName: "currency"),
              let valueText = firstChild(node, localName: "value").map(decodedText),
              let value = rational(valueText)
        else {
            return nil
        }
        let date = firstChild(node, localName: "time")
            .flatMap { firstChild($0, localName: "date") }
            .map(decodedText)
            .map { String($0.prefix(10)) } ?? ""
        let source = firstChild(node, localName: "source").map(decodedText) ?? ""
        let type = firstChild(node, localName: "type").map(decodedText) ?? ""
        return PriceRow(guid: guid, commodity: commodity, currency: currency, date: date, source: source, type: type, value: value)
    }

    /// The price for `commodity`/`currency` closest in time to `asOf`
    /// (desktop GnuCash's `gnc_pricedb_lookup_nearest_in_time`), or `nil` if
    /// none exists for that exact pair. Milestone 1: directional only -- no
    /// reciprocal-pair fallback, matching the web engine's `nearestPrice`.
    func nearestPrice(commodity: CommodityRef, currency: CommodityRef, asOf: String) throws -> PriceRow? {
        let candidates = prices().filter { candidate in
            candidate.commodity.space == commodity.space && candidate.commodity.id == commodity.id
                && candidate.currency.space == currency.space && candidate.currency.id == currency.id
        }
        var best: PriceRow?
        var bestDistance = Int.max
        for candidate in candidates {
            let distance = try daysBetween(candidate.date, asOf)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    /// Converts `value` (in `from`'s commodity) to `to`'s commodity using
    /// the nearest price as of `asOf`. `nil` -- never a silent 1:1 guess --
    /// when no price exists for the pair and the commodities aren't
    /// identical.
    func convertMoney(_ value: Money, from: CommodityRef, to: CommodityRef, asOf: String) throws -> Money? {
        if from.space == to.space && from.id == to.id { return value }
        guard let price = try nearestPrice(commodity: from, currency: to, asOf: asOf) else { return nil }
        return try Money.multiply(value, price.value)
    }

    // MARK: - Mutating: prices

    private static func commodityNode(tag: String, ref: CommodityRef) -> XNode {
        let node = XNode(name: tag)
        node.addChild(leaf("cmdty:space", ref.space))
        node.addChild(leaf("cmdty:id", ref.id))
        return node
    }

    /// `<gnc:pricedb>` sits right after the last `<gnc:commodity>` -- before
    /// any account/transaction. Falls back to right after `book:id` on the
    /// (unrealistic in practice, every real book declares a currency) case
    /// of a book with no commodities at all, rather than before it.
    /// Mirrors the web engine's `findOrCreatePricedbNode`
    /// (`johnarleyburns/saldima#104`).
    private func findOrCreatePricedbNode() -> XNode {
        if let existing = findPricedbNode() { return existing }
        let created = XNode(name: "gnc:pricedb", attributes: ["version": "1"])
        let anchor = children(book, localName: "commodity").last ?? firstChild(book, localName: "id")
        if let anchor, let index = anchor.indexInParent {
            book.insertChild(created, at: index + 1)
        } else {
            book.insertChild(created, at: 0)
        }
        return created
    }

    /// Creates a `<price>` in the book's price database, mirroring the
    /// web's exact XML shape byte-for-byte (`johnarleyburns/saldima#104`):
    /// `price:id`, `price:commodity`, `price:currency`, `price:time`,
    /// `price:source` (always `user:price-editor` in this milestone),
    /// `price:type` (omitted entirely when `type` is empty), `price:value`.
    @discardableResult
    func createPrice(
        guid: Guid,
        commodity: CommodityRef,
        currency: CommodityRef,
        date: String,
        type: String,
        value: Money
    ) -> PriceRow {
        let pricedbNode = findOrCreatePricedbNode()
        let node = XNode(name: "price")
        node.addChild(leaf("price:id", guid.rawValue, attributes: ["type": "guid"]))
        node.addChild(Self.commodityNode(tag: "price:commodity", ref: commodity))
        node.addChild(Self.commodityNode(tag: "price:currency", ref: currency))
        let timeWrapper = XNode(name: "price:time")
        timeWrapper.addChild(leaf("ts:date", "\(date) 00:00:00 +0000"))
        node.addChild(timeWrapper)
        // Milestone 1: every price this engine creates is user-entered.
        node.addChild(leaf("price:source", "user:price-editor"))
        if !type.isEmpty { node.addChild(leaf("price:type", type)) }
        node.addChild(leaf("price:value", "\(value.num)/\(value.denom)"))
        pricedbNode.addChild(node)
        priceIndex[guid] = node
        return priceRow(node)!
    }

    /// Patches date, type and value only -- the commodity/currency pair is
    /// immutable after creation, matching the web engine's own
    /// `UpdatePriceInput` and the same convention scheduled transactions
    /// and budgets use. A silent no-op on an unknown price.
    func updatePrice(_ guid: Guid, date: String?, type: String?, value: Money?) {
        guard let node = priceIndex[guid] else { return }
        if let date, let timeWrapper = firstChild(node, localName: "time") {
            setChildText(timeWrapper, localName: "date", tag: "ts:date", value: "\(date) 00:00:00 +0000")
        }
        if let type {
            let existingType = firstChild(node, localName: "type")
            if let existingType {
                if type.isEmpty {
                    existingType.detach()
                } else {
                    existingType.text = escapeXml(type)
                }
            } else if !type.isEmpty {
                let newType = leaf("price:type", type)
                if let valueNode = firstChild(node, localName: "value"), let index = valueNode.indexInParent {
                    node.insertChild(newType, at: index)
                } else {
                    node.addChild(newType)
                }
            }
        }
        if let value {
            setChildText(node, localName: "value", tag: "price:value", value: "\(value.num)/\(value.denom)")
        }
    }

    /// Deletes a price; a silent no-op on an unknown guid, matching
    /// `deleteAccount`/`deleteBudget`. Real GnuCash omits `<gnc:pricedb>`
    /// entirely once it holds no prices -- so does this engine.
    func deletePrice(_ guid: Guid) {
        guard let node = priceIndex[guid], let pricedbNode = findPricedbNode() else { return }
        node.detach()
        priceIndex.removeValue(forKey: guid)
        if pricedbNode.children.isEmpty { pricedbNode.detach() }
    }

    // MARK: - Mutating: accounts

    @discardableResult
    func createAccount(
        guid: Guid,
        name: String,
        type: String,
        parentGuid: Guid?,
        code: String,
        description: String,
        hidden: Bool,
        placeholder: Bool,
        commodityGuid: Guid?
    ) -> AccountRow {
        let newNode = Self.accountNode(
            guid: guid,
            name: name,
            type: type,
            parentGuid: parentGuid,
            code: code,
            description: description,
            hidden: hidden,
            placeholder: placeholder
        )
        if let firstTransaction = children(book, localName: "transaction").first {
            book.insertChild(newNode, at: firstTransaction.indexInParent ?? book.children.count)
        } else {
            book.addChild(newNode)
        }
        accountIndex[guid] = newNode
        return accountRow(newNode)!
    }

    func updateAccount(
        _ guid: Guid,
        name: String,
        type: String,
        parentGuid: Guid?,
        code: String,
        description: String,
        hidden: Bool,
        placeholder: Bool
    ) {
        guard let node = accountIndex[guid] else { return }
        setChildText(node, localName: "name", tag: "act:name", value: name)
        setChildText(node, localName: "type", tag: "act:type", value: type)
        setChildText(node, localName: "code", tag: "act:code", value: code)
        setChildText(node, localName: "description", tag: "act:description", value: description)

        if let existingParent = firstChild(node, localName: "parent") {
            if let parentGuid {
                existingParent.text = escapeXml(parentGuid.rawValue)
            } else {
                existingParent.detach()
            }
        } else if let parentGuid {
            node.addChild(leaf("act:parent", parentGuid.rawValue, attributes: ["type": "guid"]))
        }

        let slots = firstChild(node, localName: "slots") ?? {
            let created = XNode(name: "act:slots")
            node.addChild(created)
            return created
        }()
        setBooleanSlot(slots, key: "hidden", value: hidden)
        setBooleanSlot(slots, key: "placeholder", value: placeholder)
        if children(slots, localName: "slot").isEmpty {
            slots.detach()
        }
    }

    func deleteAccount(_ guid: Guid) {
        guard let node = accountIndex[guid] else { return }
        node.detach()
        accountIndex.removeValue(forKey: guid)
    }

    func accountCount(withParent guid: Guid) -> Int {
        accounts().filter { $0.parentGuid == guid }.count
    }

    func splitCount(forAccount guid: Guid) -> Int {
        transactions().reduce(0) { total, transaction in
            total + transaction.splits.filter { $0.accountGuid == guid }.count
        }
    }

    // MARK: - Mutating: transactions

    @discardableResult
    func postTransaction(
        guid: Guid,
        date: String,
        description: String,
        splits: [(accountGuid: Guid, value: Money, splitGuid: Guid)]
    ) -> TransactionRow {
        let node = Self.transactionNode(
            guid: guid,
            date: date,
            description: description,
            splits: splits.map { (guid: $0.splitGuid, accountGuid: $0.accountGuid, value: $0.value) }
        )
        book.addChild(node)
        transactionIndex[guid] = node
        invalidateTransactionsCache()
        return transactionRow(node)!
    }

    /// Sets one split's reconcile state, the same action as checking a row
    /// off in GnuCash's Reconcile window. `reconcileDate` is only written
    /// when `state == "y"` (reconciled); any other state clears it,
    /// matching desktop GnuCash. Silently no-ops on an unknown transaction
    /// or split -- `BookStore` validates and throws before calling this.
    func setSplitReconcileState(
        transactionGuid: Guid,
        splitGuid: Guid,
        state: String,
        reconcileDate: String?
    ) {
        guard let transactionNode = transactionIndex[transactionGuid] else { return }
        let splitsContainer = firstChild(transactionNode, localName: "splits") ?? transactionNode
        guard
            let splitNode = children(splitsContainer, localName: "split").first(where: {
                guidValue($0, localName: "id") == splitGuid
            })
        else {
            return
        }
        invalidateTransactionsCache()
        setChildText(splitNode, localName: "reconciled-state", tag: "split:reconciled-state", value: state)
        let existingDate = firstChild(splitNode, localName: "reconcile-date")
        if state == "y", let reconcileDate {
            if let existingDate {
                firstChild(existingDate, localName: "date")?.text = escapeXml(reconcileDate)
            } else {
                let dateNode = XNode(name: "split:reconcile-date")
                dateNode.addChild(leaf("ts:date", reconcileDate))
                splitNode.addChild(dateNode)
            }
        } else {
            existingDate?.detach()
        }
    }

    /// Sets or clears a transaction's "Associate File/Location" --
    /// `assoc_uri`, the same slot desktop GnuCash's own right-click action
    /// writes. `uri = nil` removes it.
    func setTransactionDocLink(_ guid: Guid, uri: String?) {
        guard let node = transactionIndex[guid] else { return }
        invalidateTransactionsCache()
        let slots = firstChild(node, localName: "slots") ?? {
            let created = XNode(name: "trn:slots")
            node.addChild(created)
            return created
        }()
        let existing = children(slots, localName: "slot").first {
            firstChild($0, localName: "key").map(decodedText) == "assoc_uri"
        }
        if let uri, !uri.isEmpty {
            if let existing {
                firstChild(existing, localName: "value")?.text = escapeXml(uri)
            } else {
                let slot = XNode(name: "slot")
                slot.addChild(leaf("slot:key", "assoc_uri"))
                slot.addChild(leaf("slot:value", uri, attributes: ["type": "string"]))
                slots.addChild(slot)
            }
        } else {
            existing?.detach()
        }
        if children(slots, localName: "slot").isEmpty {
            slots.detach()
        }
    }

    /// Voids a transaction exactly like desktop GnuCash's own `xaccTransVoid`:
    /// every split's value and quantity is preserved in a `void-former-*`
    /// slot, then zeroed (so the transaction stops affecting any balance
    /// without being deleted), every split is marked `"v"`, and the
    /// transaction's notes/void-reason/void-time slots record why and when.
    /// Silently no-ops on an unknown transaction, a blank reason, or one
    /// that's already voided -- `BookStore` validates and throws before
    /// calling this.
    func voidTransaction(_ guid: Guid, reason: String, voidTime: String) {
        guard let node = transactionIndex[guid], !reason.isEmpty,
              readStringSlot(node, key: "void-time") == nil
        else {
            return
        }
        invalidateTransactionsCache()
        let slots = firstChild(node, localName: "slots") ?? {
            let created = XNode(name: "trn:slots")
            node.addChild(created)
            return created
        }()
        if let existingNotes = readStringSlot(node, key: "notes") {
            setStringSlot(slots, key: "void-former-notes", value: existingNotes)
        }
        setStringSlot(slots, key: "notes", value: "Voided transaction")
        setStringSlot(slots, key: "void-reason", value: reason)
        setStringSlot(slots, key: "void-time", value: voidTime)
        setStringSlot(slots, key: "trans-read-only", value: "Transaction Voided")

        let splitsContainer = firstChild(node, localName: "splits") ?? node
        for splitNode in children(splitsContainer, localName: "split") {
            guard
                let valueText = firstChild(splitNode, localName: "value").map(decodedText),
                let value = rational(valueText)
            else {
                continue
            }
            let quantityText = firstChild(splitNode, localName: "quantity").map(decodedText) ?? valueText
            let quantity = rational(quantityText) ?? value
            let splitSlots = firstChild(splitNode, localName: "slots") ?? {
                let created = XNode(name: "split:slots")
                splitNode.addChild(created)
                return created
            }()
            setNumericSlot(splitSlots, key: "void-former-value", value: value)
            setNumericSlot(splitSlots, key: "void-former-amount", value: quantity)
            setChildText(splitNode, localName: "value", tag: "split:value", value: "0/\(value.denom)")
            setChildText(splitNode, localName: "quantity", tag: "split:quantity", value: "0/\(quantity.denom)")
            setChildText(splitNode, localName: "reconciled-state", tag: "split:reconciled-state", value: "v")
        }
    }

    /// Reverses `voidTransaction`: restores every split's original
    /// value/quantity and reconcile state (always back to `"n"`, matching
    /// desktop GnuCash -- a split's reconciled state before voiding is not
    /// preserved), restores the transaction's notes, and clears every
    /// void-related slot. Silently no-ops on an unknown or non-voided
    /// transaction -- `BookStore` validates and throws before calling this.
    func unvoidTransaction(_ guid: Guid) {
        guard let node = transactionIndex[guid], readStringSlot(node, key: "void-time") != nil else {
            return
        }
        invalidateTransactionsCache()
        let slots = firstChild(node, localName: "slots") ?? {
            let created = XNode(name: "trn:slots")
            node.addChild(created)
            return created
        }()
        setStringSlot(slots, key: "notes", value: readStringSlot(node, key: "void-former-notes"))
        setStringSlot(slots, key: "void-former-notes", value: nil)
        setStringSlot(slots, key: "void-reason", value: nil)
        setStringSlot(slots, key: "void-time", value: nil)
        setStringSlot(slots, key: "trans-read-only", value: nil)
        if children(slots, localName: "slot").isEmpty { slots.detach() }

        let splitsContainer = firstChild(node, localName: "splits") ?? node
        for splitNode in children(splitsContainer, localName: "split") {
            let formerValue = readNumericSlot(splitNode, key: "void-former-value")
            let formerQuantity = readNumericSlot(splitNode, key: "void-former-amount")
            if let formerValue {
                setChildText(splitNode, localName: "value", tag: "split:value", value: "\(formerValue.num)/\(formerValue.denom)")
            }
            if let formerQuantity {
                setChildText(
                    splitNode,
                    localName: "quantity",
                    tag: "split:quantity",
                    value: "\(formerQuantity.num)/\(formerQuantity.denom)"
                )
            }
            setChildText(splitNode, localName: "reconciled-state", tag: "split:reconciled-state", value: "n")
            if let splitSlots = firstChild(splitNode, localName: "slots") {
                setNumericSlot(splitSlots, key: "void-former-value", value: nil)
                setNumericSlot(splitSlots, key: "void-former-amount", value: nil)
                if children(splitSlots, localName: "slot").isEmpty { splitSlots.detach() }
            }
        }
    }

    func deleteTransaction(_ guid: Guid) {
        guard let node = transactionIndex[guid] else { return }
        node.detach()
        transactionIndex.removeValue(forKey: guid)
        invalidateTransactionsCache()
    }

    // MARK: - Reading: customers

    func customers() -> [CustomerRow] {
        children(book, localName: "GncCustomer").compactMap(customerRow)
    }

    func customer(_ guid: Guid) -> CustomerRow? {
        customerIndex[guid].flatMap(customerRow)
    }

    private func customerRow(_ node: XNode) -> CustomerRow? {
        guard let guid = guidValue(node, localName: "guid"),
              let name = firstChild(node, localName: "name").map(decodedText)
        else {
            return nil
        }
        let address = firstChild(node, localName: "addr")
        func addressField(_ name: String) -> String {
            address.flatMap { firstChild($0, localName: name) }.map(decodedText) ?? ""
        }
        return CustomerRow(
            guid: guid,
            name: name,
            customerNumber: firstChild(node, localName: "id").map(decodedText) ?? "",
            addressName: addressField("name"),
            addressLine1: addressField("addr1"),
            addressLine2: addressField("addr2"),
            phone: addressField("phone"),
            email: addressField("email"),
            notes: firstChild(node, localName: "notes").map(decodedText) ?? "",
            active: firstChild(node, localName: "active").map(decodedText) != "0"
        )
    }

    // MARK: - Mutating: customers

    @discardableResult
    func createCustomer(
        guid: Guid,
        name: String,
        customerNumber: String,
        addressName: String,
        addressLine1: String,
        addressLine2: String,
        phone: String,
        email: String,
        notes: String,
        currencyCode: String
    ) -> CustomerRow {
        let node = Self.customerNode(
            guid: guid,
            name: name,
            customerNumber: customerNumber,
            addressName: addressName,
            addressLine1: addressLine1,
            addressLine2: addressLine2,
            phone: phone,
            email: email,
            notes: notes,
            active: true,
            currencyCode: currencyCode
        )
        book.addChild(node)
        customerIndex[guid] = node
        return customerRow(node)!
    }

    func updateCustomer(
        _ guid: Guid,
        name: String,
        customerNumber: String,
        addressName: String,
        addressLine1: String,
        addressLine2: String,
        phone: String,
        email: String,
        notes: String,
        active: Bool
    ) {
        guard let node = customerIndex[guid] else { return }
        setChildText(node, localName: "name", tag: "cust:name", value: name)
        setChildText(node, localName: "id", tag: "cust:id", value: customerNumber)
        let address = firstChild(node, localName: "addr") ?? {
            let created = XNode(name: "cust:addr", attributes: ["version": "2.0.0"])
            node.addChild(created)
            return created
        }()
        setChildText(address, localName: "name", tag: "addr:name", value: addressName)
        setChildText(address, localName: "addr1", tag: "addr:addr1", value: addressLine1)
        setChildText(address, localName: "addr2", tag: "addr:addr2", value: addressLine2)
        setChildText(address, localName: "phone", tag: "addr:phone", value: phone)
        setChildText(address, localName: "email", tag: "addr:email", value: email)
        setChildText(node, localName: "notes", tag: "cust:notes", value: notes)
        setChildText(node, localName: "active", tag: "cust:active", value: active ? "1" : "0")
    }

    func deleteCustomer(_ guid: Guid) {
        guard let node = customerIndex[guid] else { return }
        node.detach()
        customerIndex.removeValue(forKey: guid)
    }

    func customerInUse(_ guid: Guid) -> Bool {
        invoices().contains { $0.customerGuid == guid }
    }

    // MARK: - Reading: invoices and entries

    func invoices() -> [InvoiceRow] {
        children(book, localName: "GncInvoice")
            .filter { ownerType($0) != "gncVendor" }
            .compactMap(invoiceRow)
    }

    func invoice(_ guid: Guid) -> InvoiceRow? {
        guard let node = invoiceIndex[guid], ownerType(node) != "gncVendor" else { return nil }
        return invoiceRow(node)
    }

    private func invoiceRow(_ node: XNode) -> InvoiceRow? {
        guard let guid = guidValue(node, localName: "guid"),
              let owner = firstChild(node, localName: "owner"),
              let customerGuid = guidValue(owner, localName: "id")
        else {
            return nil
        }
        let dateOpened = firstChild(node, localName: "opened")
            .flatMap { firstChild($0, localName: "date") }
            .map(decodedText) ?? ""
        let datePosted = firstChild(node, localName: "posted")
            .flatMap { firstChild($0, localName: "date") }
            .map(decodedText)
        return InvoiceRow(
            guid: guid,
            invoiceNumber: firstChild(node, localName: "id").map(decodedText) ?? "",
            customerGuid: customerGuid,
            dateOpened: dateOpened,
            datePosted: datePosted,
            notes: firstChild(node, localName: "notes").map(decodedText) ?? "",
            active: firstChild(node, localName: "active").map(decodedText) != "0",
            postedTransactionGuid: guidValue(node, localName: "posttxn"),
            receivableAccountGuid: guidValue(node, localName: "postacc")
        )
    }

    /// Every line on one invoice, oldest first.
    func invoiceEntries(forInvoice invoiceGuid: Guid) -> [InvoiceEntryRow] {
        children(book, localName: "GncEntry")
            .compactMap(entryRow)
            .filter { $0.invoiceGuid == invoiceGuid }
            .sorted { $0.date == $1.date ? $0.guid.rawValue < $1.guid.rawValue : $0.date < $1.date }
    }

    private func entryRow(_ node: XNode) -> InvoiceEntryRow? {
        guard let guid = guidValue(node, localName: "guid"),
              let invoiceGuid = guidValue(node, localName: "invoice"),
              let incomeAccountGuid = guidValue(node, localName: "i-acct")
        else {
            return nil
        }
        let date = firstChild(node, localName: "date")
            .flatMap { firstChild($0, localName: "date") }
            .map(decodedText) ?? ""
        let quantity = firstChild(node, localName: "qty").map(decodedText).flatMap(rational) ?? .zero
        let unitPrice = firstChild(node, localName: "i-price").map(decodedText).flatMap(rational) ?? .zero
        return InvoiceEntryRow(
            guid: guid,
            invoiceGuid: invoiceGuid,
            date: date,
            description: firstChild(node, localName: "description").map(decodedText) ?? "",
            quantity: quantity,
            unitPrice: unitPrice,
            incomeAccountGuid: incomeAccountGuid
        )
    }

    // MARK: - Mutating: invoices and entries

    @discardableResult
    func createInvoice(
        guid: Guid,
        invoiceNumber: String,
        customerGuid: Guid,
        dateOpened: String,
        notes: String,
        currencyCode: String
    ) -> InvoiceRow {
        let node = Self.invoiceNode(
            guid: guid,
            invoiceNumber: invoiceNumber,
            customerGuid: customerGuid,
            dateOpened: dateOpened,
            notes: notes,
            currencyCode: currencyCode
        )
        book.addChild(node)
        invoiceIndex[guid] = node
        return invoiceRow(node)!
    }

    /// Drafts only: a posted invoice is part of the permanent ledger history.
    func deleteInvoice(_ guid: Guid) {
        guard let node = invoiceIndex[guid] else { return }
        for entryNode in children(book, localName: "GncEntry")
        where guidValue(entryNode, localName: "invoice") == guid {
            entryNode.detach()
        }
        node.detach()
        invoiceIndex.removeValue(forKey: guid)
    }

    @discardableResult
    func addInvoiceEntry(
        guid: Guid,
        invoiceGuid: Guid,
        date: String,
        description: String,
        quantity: Money,
        unitPrice: Money,
        incomeAccountGuid: Guid
    ) -> InvoiceEntryRow {
        let node = Self.entryNode(
            guid: guid,
            invoiceGuid: invoiceGuid,
            date: date,
            description: description,
            quantity: quantity,
            unitPrice: unitPrice,
            incomeAccountGuid: incomeAccountGuid
        )
        book.addChild(node)
        return entryRow(node)!
    }

    func deleteInvoiceEntry(_ guid: Guid) {
        guard let node = children(book, localName: "GncEntry")
            .first(where: { guidValue($0, localName: "guid") == guid })
        else {
            return
        }
        node.detach()
    }

    /// Marks a draft invoice posted: stamps the posted date, the real
    /// ledger transaction behind it, and the receivable account used --
    /// matching desktop GnuCash's own "Post Invoice" action. The caller
    /// creates that transaction separately via `postTransaction`.
    func markInvoicePosted(
        _ guid: Guid,
        postedDate: String,
        transactionGuid: Guid,
        receivableAccountGuid: Guid
    ) {
        guard let node = invoiceIndex[guid] else { return }
        let postedNode = XNode(name: "invoice:posted")
        postedNode.addChild(leaf("ts:date", postedDate))
        node.addChild(postedNode)
        node.addChild(leaf("invoice:posttxn", transactionGuid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("invoice:postacc", receivableAccountGuid.rawValue, attributes: ["type": "guid"]))
    }

    // MARK: - Reading: vendors

    func vendors() -> [VendorRow] {
        children(book, localName: "GncVendor").compactMap(vendorRow)
    }

    func vendor(_ guid: Guid) -> VendorRow? {
        vendorIndex[guid].flatMap(vendorRow)
    }

    private func vendorRow(_ node: XNode) -> VendorRow? {
        guard let guid = guidValue(node, localName: "guid"),
              let name = firstChild(node, localName: "name").map(decodedText)
        else {
            return nil
        }
        let address = firstChild(node, localName: "addr")
        func addressField(_ name: String) -> String {
            address.flatMap { firstChild($0, localName: name) }.map(decodedText) ?? ""
        }
        return VendorRow(
            guid: guid,
            name: name,
            vendorNumber: firstChild(node, localName: "id").map(decodedText) ?? "",
            addressLine1: addressField("addr1"),
            phone: addressField("phone"),
            email: addressField("email"),
            notes: firstChild(node, localName: "notes").map(decodedText) ?? "",
            active: firstChild(node, localName: "active").map(decodedText) != "0"
        )
    }

    // MARK: - Mutating: vendors

    @discardableResult
    func createVendor(
        guid: Guid,
        name: String,
        vendorNumber: String,
        addressLine1: String,
        phone: String,
        email: String,
        notes: String,
        currencyCode: String
    ) -> VendorRow {
        let node = Self.vendorNode(
            guid: guid,
            name: name,
            vendorNumber: vendorNumber,
            addressLine1: addressLine1,
            phone: phone,
            email: email,
            notes: notes,
            active: true,
            currencyCode: currencyCode
        )
        book.addChild(node)
        vendorIndex[guid] = node
        return vendorRow(node)!
    }

    func updateVendor(
        _ guid: Guid,
        name: String,
        vendorNumber: String,
        addressLine1: String,
        phone: String,
        email: String,
        notes: String,
        active: Bool
    ) {
        guard let node = vendorIndex[guid] else { return }
        setChildText(node, localName: "name", tag: "vendor:name", value: name)
        setChildText(node, localName: "id", tag: "vendor:id", value: vendorNumber)
        let address = firstChild(node, localName: "addr") ?? {
            let created = XNode(name: "vendor:addr", attributes: ["version": "2.0.0"])
            node.addChild(created)
            return created
        }()
        setChildText(address, localName: "addr1", tag: "addr:addr1", value: addressLine1)
        setChildText(address, localName: "phone", tag: "addr:phone", value: phone)
        setChildText(address, localName: "email", tag: "addr:email", value: email)
        setChildText(node, localName: "notes", tag: "vendor:notes", value: notes)
        setChildText(node, localName: "active", tag: "vendor:active", value: active ? "1" : "0")
    }

    func deleteVendor(_ guid: Guid) {
        guard let node = vendorIndex[guid] else { return }
        node.detach()
        vendorIndex.removeValue(forKey: guid)
    }

    func vendorInUse(_ guid: Guid) -> Bool {
        bills().contains { $0.vendorGuid == guid }
    }

    // MARK: - Reading: bills and bill entries

    func bills() -> [BillRow] {
        children(book, localName: "GncInvoice")
            .filter { ownerType($0) == "gncVendor" }
            .compactMap(billRow)
    }

    func bill(_ guid: Guid) -> BillRow? {
        guard let node = invoiceIndex[guid], ownerType(node) == "gncVendor" else { return nil }
        return billRow(node)
    }

    private func billRow(_ node: XNode) -> BillRow? {
        guard let guid = guidValue(node, localName: "guid"),
              let owner = firstChild(node, localName: "owner"),
              let vendorGuid = guidValue(owner, localName: "id")
        else {
            return nil
        }
        let dateOpened = firstChild(node, localName: "opened")
            .flatMap { firstChild($0, localName: "date") }
            .map(decodedText) ?? ""
        let datePosted = firstChild(node, localName: "posted")
            .flatMap { firstChild($0, localName: "date") }
            .map(decodedText)
        return BillRow(
            guid: guid,
            billNumber: firstChild(node, localName: "id").map(decodedText) ?? "",
            vendorGuid: vendorGuid,
            dateOpened: dateOpened,
            datePosted: datePosted,
            notes: firstChild(node, localName: "notes").map(decodedText) ?? "",
            active: firstChild(node, localName: "active").map(decodedText) != "0",
            postedTransactionGuid: guidValue(node, localName: "posttxn"),
            payableAccountGuid: guidValue(node, localName: "postacc")
        )
    }

    /// Every line on one bill, oldest first.
    func billEntries(forBill billGuid: Guid) -> [BillEntryRow] {
        children(book, localName: "GncEntry")
            .compactMap(billEntryRow)
            .filter { $0.billGuid == billGuid }
            .sorted { $0.date == $1.date ? $0.guid.rawValue < $1.guid.rawValue : $0.date < $1.date }
    }

    private func billEntryRow(_ node: XNode) -> BillEntryRow? {
        guard let guid = guidValue(node, localName: "guid"),
              let billGuid = guidValue(node, localName: "bill"),
              let expenseAccountGuid = guidValue(node, localName: "b-acct")
        else {
            return nil
        }
        let date = firstChild(node, localName: "date")
            .flatMap { firstChild($0, localName: "date") }
            .map(decodedText) ?? ""
        let quantity = firstChild(node, localName: "qty").map(decodedText).flatMap(rational) ?? .zero
        let unitPrice = firstChild(node, localName: "b-price").map(decodedText).flatMap(rational) ?? .zero
        return BillEntryRow(
            guid: guid,
            billGuid: billGuid,
            date: date,
            description: firstChild(node, localName: "description").map(decodedText) ?? "",
            quantity: quantity,
            unitPrice: unitPrice,
            expenseAccountGuid: expenseAccountGuid
        )
    }

    // MARK: - Mutating: bills and bill entries

    @discardableResult
    func createBill(
        guid: Guid,
        billNumber: String,
        vendorGuid: Guid,
        dateOpened: String,
        notes: String,
        currencyCode: String
    ) -> BillRow {
        let node = Self.billNode(
            guid: guid,
            billNumber: billNumber,
            vendorGuid: vendorGuid,
            dateOpened: dateOpened,
            notes: notes,
            currencyCode: currencyCode
        )
        book.addChild(node)
        invoiceIndex[guid] = node
        return billRow(node)!
    }

    /// Drafts only: a posted bill is part of the permanent ledger history.
    func deleteBill(_ guid: Guid) {
        guard let node = invoiceIndex[guid] else { return }
        for entryNode in children(book, localName: "GncEntry")
        where guidValue(entryNode, localName: "bill") == guid {
            entryNode.detach()
        }
        node.detach()
        invoiceIndex.removeValue(forKey: guid)
    }

    @discardableResult
    func addBillEntry(
        guid: Guid,
        billGuid: Guid,
        date: String,
        description: String,
        quantity: Money,
        unitPrice: Money,
        expenseAccountGuid: Guid
    ) -> BillEntryRow {
        let node = Self.billEntryNode(
            guid: guid,
            billGuid: billGuid,
            date: date,
            description: description,
            quantity: quantity,
            unitPrice: unitPrice,
            expenseAccountGuid: expenseAccountGuid
        )
        book.addChild(node)
        return billEntryRow(node)!
    }

    func deleteBillEntry(_ guid: Guid) {
        guard let node = children(book, localName: "GncEntry")
            .first(where: { guidValue($0, localName: "guid") == guid })
        else {
            return
        }
        node.detach()
    }

    /// Marks a draft bill posted: stamps the posted date, the real ledger
    /// transaction behind it, and the payable account used -- matching
    /// desktop GnuCash's own "Post Bill" action. The caller creates that
    /// transaction separately via `postTransaction`.
    func markBillPosted(
        _ guid: Guid,
        postedDate: String,
        transactionGuid: Guid,
        payableAccountGuid: Guid
    ) {
        guard let node = invoiceIndex[guid] else { return }
        let postedNode = XNode(name: "invoice:posted")
        postedNode.addChild(leaf("ts:date", postedDate))
        node.addChild(postedNode)
        node.addChild(leaf("invoice:posttxn", transactionGuid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("invoice:postacc", payableAccountGuid.rawValue, attributes: ["type": "guid"]))
    }

    // MARK: - Building new nodes

    private static let namespaceAttributes: [String: String] = [
        "xmlns:gnc": "http://www.gnucash.org/XML/gnc",
        "xmlns:act": "http://www.gnucash.org/XML/act",
        "xmlns:book": "http://www.gnucash.org/XML/book",
        "xmlns:cd": "http://www.gnucash.org/XML/cd",
        "xmlns:cmdty": "http://www.gnucash.org/XML/cmdty",
        "xmlns:price": "http://www.gnucash.org/XML/price",
        "xmlns:slot": "http://www.gnucash.org/XML/slot",
        "xmlns:split": "http://www.gnucash.org/XML/split",
        "xmlns:trn": "http://www.gnucash.org/XML/trn",
        "xmlns:ts": "http://www.gnucash.org/XML/ts",
    ]

    private static func accountNode(
        guid: Guid,
        name: String,
        type: String,
        parentGuid: Guid?,
        code: String,
        description: String,
        hidden: Bool,
        placeholder: Bool
    ) -> XNode {
        let node = XNode(name: "gnc:account", attributes: ["version": "2.0.0"])
        node.addChild(leaf("act:name", name))
        node.addChild(leaf("act:id", guid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("act:type", type))
        if let parentGuid {
            node.addChild(leaf("act:parent", parentGuid.rawValue, attributes: ["type": "guid"]))
        }
        if hidden || placeholder {
            let slots = XNode(name: "act:slots")
            if placeholder { slots.addChild(booleanSlotNode(key: "placeholder")) }
            if hidden { slots.addChild(booleanSlotNode(key: "hidden")) }
            node.addChild(slots)
        }
        node.addChild(leaf("act:code", code))
        node.addChild(leaf("act:description", description))
        return node
    }

    private static func booleanSlotNode(key: String) -> XNode {
        let slot = XNode(name: "slot")
        slot.addChild(leaf("slot:key", key))
        slot.addChild(leaf("slot:value", "true", attributes: ["type": "string"]))
        return slot
    }

    private func findSlot(_ slots: XNode, key: String) -> XNode? {
        children(slots, localName: "slot").first {
            firstChild($0, localName: "key").map(decodedText) == key
        }
    }

    private func readStringSlot(_ owner: XNode, key: String) -> String? {
        guard let slots = firstChild(owner, localName: "slots"),
              let slot = findSlot(slots, key: key)
        else {
            return nil
        }
        return firstChild(slot, localName: "value").map(decodedText)
    }

    private func setStringSlot(_ slots: XNode, key: String, value: String?) {
        let existing = findSlot(slots, key: key)
        guard let value else {
            existing?.detach()
            return
        }
        if let existing {
            firstChild(existing, localName: "value")?.text = escapeXml(value)
            return
        }
        let slot = XNode(name: "slot")
        slot.addChild(leaf("slot:key", key))
        slot.addChild(leaf("slot:value", value, attributes: ["type": "string"]))
        slots.addChild(slot)
    }

    private func readNumericSlot(_ owner: XNode, key: String) -> Money? {
        guard let slots = firstChild(owner, localName: "slots"),
              let slot = findSlot(slots, key: key),
              let valueNode = firstChild(slot, localName: "value")
        else {
            return nil
        }
        return rational(decodedText(valueNode))
    }

    private func setNumericSlot(_ slots: XNode, key: String, value: Money?) {
        let existing = findSlot(slots, key: key)
        guard let value else {
            existing?.detach()
            return
        }
        let valueText = "\(value.num)/\(value.denom)"
        if let existing {
            firstChild(existing, localName: "value")?.text = escapeXml(valueText)
            return
        }
        let slot = XNode(name: "slot")
        slot.addChild(leaf("slot:key", key))
        slot.addChild(leaf("slot:value", valueText, attributes: ["type": "numeric"]))
        slots.addChild(slot)
    }

    private func setBooleanSlot(_ slots: XNode, key: String, value: Bool) {
        let existing = children(slots, localName: "slot").first {
            firstChild($0, localName: "key").map(decodedText) == key
        }
        if !value {
            existing?.detach()
            return
        }
        if let existing {
            if let valueNode = firstChild(existing, localName: "value") {
                valueNode.text = "true"
            }
            return
        }
        slots.addChild(Self.booleanSlotNode(key: key))
    }

    private func setChildText(_ parent: XNode, localName: String, tag: String, value: String) {
        if let existing = firstChild(parent, localName: localName) {
            existing.children = []
            existing.text = escapeXml(value)
            return
        }
        parent.addChild(leaf(tag, value))
    }

    private static func transactionNode(
        guid: Guid,
        date: String,
        description: String,
        splits: [(guid: Guid, accountGuid: Guid, value: Money)]
    ) -> XNode {
        let node = XNode(name: "gnc:transaction", attributes: ["version": "2.0.0"])
        node.addChild(leaf("trn:id", guid.rawValue, attributes: ["type": "guid"]))

        let postedDate = XNode(name: "trn:date-posted")
        postedDate.addChild(leaf("ts:date", "\(date) 00:00:00 +0000"))
        node.addChild(postedDate)
        let enteredDate = XNode(name: "trn:date-entered")
        enteredDate.addChild(leaf("ts:date", "\(date) 00:00:00 +0000"))
        node.addChild(enteredDate)

        node.addChild(leaf("trn:description", description))

        let splitsNode = XNode(name: "trn:splits")
        for split in splits {
            let splitNode = XNode(name: "trn:split")
            splitNode.addChild(leaf("split:id", split.guid.rawValue, attributes: ["type": "guid"]))
            splitNode.addChild(leaf("split:reconciled-state", "n"))
            let valueText = "\(split.value.num)/\(split.value.denom)"
            splitNode.addChild(leaf("split:value", valueText))
            splitNode.addChild(leaf("split:quantity", valueText))
            splitNode.addChild(leaf("split:account", split.accountGuid.rawValue, attributes: ["type": "guid"]))
            splitsNode.addChild(splitNode)
        }
        node.addChild(splitsNode)
        return node
    }

    private static func customerNode(
        guid: Guid,
        name: String,
        customerNumber: String,
        addressName: String,
        addressLine1: String,
        addressLine2: String,
        phone: String,
        email: String,
        notes: String,
        active: Bool,
        currencyCode: String
    ) -> XNode {
        let node = XNode(name: "gnc:GncCustomer", attributes: ["version": "2.0.0"])
        node.addChild(leaf("cust:guid", guid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("cust:name", name))
        node.addChild(leaf("cust:id", customerNumber))

        let address = XNode(name: "cust:addr", attributes: ["version": "2.0.0"])
        address.addChild(leaf("addr:name", addressName))
        address.addChild(leaf("addr:addr1", addressLine1))
        address.addChild(leaf("addr:addr2", addressLine2))
        address.addChild(leaf("addr:phone", phone))
        address.addChild(leaf("addr:email", email))
        node.addChild(address)

        node.addChild(leaf("cust:notes", notes))
        node.addChild(leaf("cust:active", active ? "1" : "0"))

        let currency = XNode(name: "cust:currency")
        currency.addChild(leaf("cmdty:space", "CURRENCY"))
        currency.addChild(leaf("cmdty:id", currencyCode))
        node.addChild(currency)
        return node
    }

    private static func invoiceNode(
        guid: Guid,
        invoiceNumber: String,
        customerGuid: Guid,
        dateOpened: String,
        notes: String,
        currencyCode: String
    ) -> XNode {
        let node = XNode(name: "gnc:GncInvoice", attributes: ["version": "2.0.0"])
        node.addChild(leaf("invoice:guid", guid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("invoice:id", invoiceNumber))

        let owner = XNode(name: "invoice:owner", attributes: ["version": "2.0.0"])
        owner.addChild(leaf("owner:type", "gncCustomer"))
        owner.addChild(leaf("owner:id", customerGuid.rawValue, attributes: ["type": "guid"]))
        node.addChild(owner)

        let opened = XNode(name: "invoice:opened")
        opened.addChild(leaf("ts:date", dateOpened))
        node.addChild(opened)

        node.addChild(leaf("invoice:notes", notes))
        node.addChild(leaf("invoice:active", "1"))

        let currency = XNode(name: "invoice:currency")
        currency.addChild(leaf("cmdty:space", "CURRENCY"))
        currency.addChild(leaf("cmdty:id", currencyCode))
        node.addChild(currency)
        return node
    }

    private static func entryNode(
        guid: Guid,
        invoiceGuid: Guid,
        date: String,
        description: String,
        quantity: Money,
        unitPrice: Money,
        incomeAccountGuid: Guid
    ) -> XNode {
        let node = XNode(name: "gnc:GncEntry", attributes: ["version": "2.0.0"])
        node.addChild(leaf("entry:guid", guid.rawValue, attributes: ["type": "guid"]))

        let dateNode = XNode(name: "entry:date")
        dateNode.addChild(leaf("ts:date", date))
        node.addChild(dateNode)
        let enteredNode = XNode(name: "entry:entered")
        enteredNode.addChild(leaf("ts:date", date))
        node.addChild(enteredNode)

        node.addChild(leaf("entry:description", description))
        node.addChild(leaf("entry:qty", "\(quantity.num)/\(quantity.denom)"))
        node.addChild(leaf("entry:i-acct", incomeAccountGuid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("entry:i-price", "\(unitPrice.num)/\(unitPrice.denom)"))
        node.addChild(leaf("entry:i-discount", "0/100"))
        node.addChild(leaf("entry:invoice", invoiceGuid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("entry:i-disc-type", "PERCENT"))
        node.addChild(leaf("entry:i-disc-how", "PRETAX"))
        node.addChild(leaf("entry:i-taxable", "0"))
        node.addChild(leaf("entry:i-taxincluded", "0"))
        return node
    }

    private static func vendorNode(
        guid: Guid,
        name: String,
        vendorNumber: String,
        addressLine1: String,
        phone: String,
        email: String,
        notes: String,
        active: Bool,
        currencyCode: String
    ) -> XNode {
        let node = XNode(name: "gnc:GncVendor", attributes: ["version": "2.0.0"])
        node.addChild(leaf("vendor:guid", guid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("vendor:name", name))
        node.addChild(leaf("vendor:id", vendorNumber))

        let address = XNode(name: "vendor:addr", attributes: ["version": "2.0.0"])
        address.addChild(leaf("addr:name", ""))
        address.addChild(leaf("addr:addr1", addressLine1))
        address.addChild(leaf("addr:addr2", ""))
        address.addChild(leaf("addr:phone", phone))
        address.addChild(leaf("addr:email", email))
        node.addChild(address)

        node.addChild(leaf("vendor:notes", notes))
        node.addChild(leaf("vendor:taxincluded", "0"))
        node.addChild(leaf("vendor:active", active ? "1" : "0"))

        let currency = XNode(name: "vendor:currency")
        currency.addChild(leaf("cmdty:space", "CURRENCY"))
        currency.addChild(leaf("cmdty:id", currencyCode))
        node.addChild(currency)
        return node
    }

    private static func billNode(
        guid: Guid,
        billNumber: String,
        vendorGuid: Guid,
        dateOpened: String,
        notes: String,
        currencyCode: String
    ) -> XNode {
        let node = XNode(name: "gnc:GncInvoice", attributes: ["version": "2.0.0"])
        node.addChild(leaf("invoice:guid", guid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("invoice:id", billNumber))

        let owner = XNode(name: "invoice:owner", attributes: ["version": "2.0.0"])
        owner.addChild(leaf("owner:type", "gncVendor"))
        owner.addChild(leaf("owner:id", vendorGuid.rawValue, attributes: ["type": "guid"]))
        node.addChild(owner)

        let opened = XNode(name: "invoice:opened")
        opened.addChild(leaf("ts:date", dateOpened))
        node.addChild(opened)

        node.addChild(leaf("invoice:notes", notes))
        node.addChild(leaf("invoice:active", "1"))

        let currency = XNode(name: "invoice:currency")
        currency.addChild(leaf("cmdty:space", "CURRENCY"))
        currency.addChild(leaf("cmdty:id", currencyCode))
        node.addChild(currency)
        return node
    }

    private static func billEntryNode(
        guid: Guid,
        billGuid: Guid,
        date: String,
        description: String,
        quantity: Money,
        unitPrice: Money,
        expenseAccountGuid: Guid
    ) -> XNode {
        let node = XNode(name: "gnc:GncEntry", attributes: ["version": "2.0.0"])
        node.addChild(leaf("entry:guid", guid.rawValue, attributes: ["type": "guid"]))

        let dateNode = XNode(name: "entry:date")
        dateNode.addChild(leaf("ts:date", date))
        node.addChild(dateNode)
        let enteredNode = XNode(name: "entry:entered")
        enteredNode.addChild(leaf("ts:date", date))
        node.addChild(enteredNode)

        node.addChild(leaf("entry:description", description))
        node.addChild(leaf("entry:qty", "\(quantity.num)/\(quantity.denom)"))
        node.addChild(leaf("entry:b-acct", expenseAccountGuid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("entry:b-price", "\(unitPrice.num)/\(unitPrice.denom)"))
        node.addChild(leaf("entry:bill", billGuid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("entry:billable", "0"))
        node.addChild(leaf("entry:b-taxable", "0"))
        node.addChild(leaf("entry:b-taxincluded", "0"))
        return node
    }

    // MARK: - Building new nodes: scheduled transactions

    /// A `Template Root` or per-schedule template account: `gnc:account`
    /// in the shared `"template"/"template"` commodity, `commodity-scu`
    /// 1 -- never a real posting account, so it never shows up in
    /// `accounts()`'s scan of `book`'s direct children.
    private static func templateAccountNode(guid: Guid, name: String, type: String, parentGuid: Guid?) -> XNode {
        let node = XNode(name: "gnc:account", attributes: ["version": "2.0.0"])
        node.addChild(leaf("act:name", name))
        node.addChild(leaf("act:id", guid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("act:type", type))
        let commodity = XNode(name: "act:commodity")
        commodity.addChild(leaf("cmdty:space", "template"))
        commodity.addChild(leaf("cmdty:id", "template"))
        node.addChild(commodity)
        node.addChild(leaf("act:commodity-scu", "1"))
        if let parentGuid {
            node.addChild(leaf("act:parent", parentGuid.rawValue, attributes: ["type": "guid"]))
        }
        return node
    }

    /// One template split: posts a zero amount to the template account
    /// (GnuCash never lets a template transaction affect a real balance),
    /// and carries the real account and signed fixed amount in a
    /// `sched-xaction` KVP frame with exactly five sub-keys, in this
    /// order, always all five -- the unused side's formula is an empty
    /// string and its numeric is the literal `"0/1"`, never omitted.
    private static func templateSplitNode(
        guid: Guid,
        templateAccountGuid: Guid,
        realAccountGuid: Guid,
        value: Money,
        fraction: Int64
    ) -> XNode {
        let node = XNode(name: "trn:split")
        node.addChild(leaf("split:id", guid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("split:reconciled-state", "n"))
        node.addChild(leaf("split:value", "0/\(fraction)"))
        node.addChild(leaf("split:quantity", "0/1"))
        node.addChild(leaf("split:account", templateAccountGuid.rawValue, attributes: ["type": "guid"]))

        let isDebit = value.num >= 0
        let magnitude = isDebit ? value : value.negated()
        let formula = (try? magnitude.formatted(fraction: fraction)) ?? "0"
        let numericText = "\(magnitude.num)/\(magnitude.denom)"

        let frame = XNode(name: "slot:value", attributes: ["type": "frame"])
        frame.addChild(kvpSlot("account", leaf("slot:value", realAccountGuid.rawValue, attributes: ["type": "guid"])))
        frame.addChild(kvpSlot(
            "credit-formula",
            leaf("slot:value", isDebit ? "" : formula, attributes: ["type": "string"])
        ))
        frame.addChild(kvpSlot(
            "credit-numeric",
            leaf("slot:value", isDebit ? "0/1" : numericText, attributes: ["type": "numeric"])
        ))
        frame.addChild(kvpSlot(
            "debit-formula",
            leaf("slot:value", isDebit ? formula : "", attributes: ["type": "string"])
        ))
        frame.addChild(kvpSlot(
            "debit-numeric",
            leaf("slot:value", isDebit ? numericText : "0/1", attributes: ["type": "numeric"])
        ))

        let splitSlots = XNode(name: "split:slots")
        splitSlots.addChild(kvpSlot("sched-xaction", frame))
        node.addChild(splitSlots)
        return node
    }

    private static func kvpSlot(_ key: String, _ value: XNode) -> XNode {
        let slot = XNode(name: "slot")
        slot.addChild(leaf("slot:key", key))
        slot.addChild(value)
        return slot
    }

    /// A schedule's template transaction: dated and described from the
    /// schedule itself (`start`/`name`), never from "today" -- it is never
    /// posted on its own, only copied from when a due instance is approved.
    private static func templateTransactionNode(
        guid: Guid,
        currencyCode: String,
        start: String,
        name: String,
        splitNodes: [XNode]
    ) -> XNode {
        let node = XNode(name: "gnc:transaction", attributes: ["version": "2.0.0"])
        node.addChild(leaf("trn:id", guid.rawValue, attributes: ["type": "guid"]))
        let currency = XNode(name: "trn:currency")
        currency.addChild(leaf("cmdty:space", "CURRENCY"))
        currency.addChild(leaf("cmdty:id", currencyCode))
        node.addChild(currency)
        let posted = XNode(name: "trn:date-posted")
        posted.addChild(leaf("ts:date", "\(start) 00:00:00 +0000"))
        node.addChild(posted)
        let entered = XNode(name: "trn:date-entered")
        entered.addChild(leaf("ts:date", "\(start) 00:00:00 +0000"))
        node.addChild(entered)
        node.addChild(leaf("trn:description", name))
        let splits = XNode(name: "trn:splits")
        for splitNode in splitNodes { splits.addChild(splitNode) }
        node.addChild(splits)
        return node
    }

    /// `<tag><gdate>YYYY-MM-DD</gdate></tag>` -- GnuCash's date-only
    /// wrapper, used by `sx:start`/`sx:last`/`sx:end`/`recurrence:start`.
    private static func gdateNode(tag: String, date: String) -> XNode {
        let node = XNode(name: tag)
        node.addChild(leaf("gdate", date))
        return node
    }

    /// `<gnc:schedxaction version="2.0.0">` in the web's exact child
    /// order: id, name, enabled, autoCreate, autoCreateNotify,
    /// advanceCreateDays, advanceRemindDays, instanceCount, start,
    /// [num-occur+rem-occur OR end -- mutually exclusive, omitted if no
    /// end], templ-acct, schedule > gnc:recurrence.
    private static func schedxactionNode(
        guid: Guid,
        name: String,
        enabled: Bool,
        autoCreate: Bool,
        autoCreateNotify: Bool,
        advanceCreateDays: Int,
        advanceRemindDays: Int,
        start: String,
        end: ScheduledEnd?,
        templateAccountGuid: Guid,
        recurrence: Recurrence
    ) -> XNode {
        let node = XNode(name: "gnc:schedxaction", attributes: ["version": "2.0.0"])
        node.addChild(leaf("sx:id", guid.rawValue, attributes: ["type": "guid"]))
        node.addChild(leaf("sx:name", name))
        node.addChild(leaf("sx:enabled", enabled ? "y" : "n"))
        node.addChild(leaf("sx:autoCreate", autoCreate ? "y" : "n"))
        node.addChild(leaf("sx:autoCreateNotify", autoCreateNotify ? "y" : "n"))
        node.addChild(leaf("sx:advanceCreateDays", String(advanceCreateDays)))
        node.addChild(leaf("sx:advanceRemindDays", String(advanceRemindDays)))
        node.addChild(leaf("sx:instanceCount", "0"))
        node.addChild(gdateNode(tag: "sx:start", date: start))
        switch end {
        case .occurrences(let count):
            node.addChild(leaf("sx:num-occur", String(count)))
            node.addChild(leaf("sx:rem-occur", String(count)))
        case .date(let date):
            node.addChild(gdateNode(tag: "sx:end", date: date))
        case nil:
            break
        }
        node.addChild(leaf("sx:templ-acct", templateAccountGuid.rawValue, attributes: ["type": "guid"]))

        let schedule = XNode(name: "sx:schedule")
        let recurrenceNode = XNode(name: "gnc:recurrence", attributes: ["version": "1.0.0"])
        recurrenceNode.addChild(leaf("recurrence:mult", String(recurrence.multiplier)))
        recurrenceNode.addChild(leaf("recurrence:period_type", recurrence.periodType.xmlValue))
        recurrenceNode.addChild(gdateNode(tag: "recurrence:start", date: recurrence.start))
        if recurrence.weekendAdjust != .none {
            recurrenceNode.addChild(leaf("recurrence:weekend_adj", recurrence.weekendAdjust.rawValue))
        }
        schedule.addChild(recurrenceNode)
        node.addChild(schedule)
        return node
    }

    // MARK: - Tree helpers

    private func localName(_ name: String) -> String {
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    private func children(_ node: XNode, localName name: String) -> [XNode] {
        node.children.filter { localName($0.name) == name }
    }

    private func firstChild(_ node: XNode, localName name: String) -> XNode? {
        children(node, localName: name).first
    }

    private func decodedText(_ node: XNode) -> String {
        decodeXmlEntities(node.text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func guidValue(_ node: XNode, localName name: String) -> Guid? {
        firstChild(node, localName: name).flatMap { Guid(decodedText($0)) }
    }

    private func rational(_ text: String) -> Money? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let num = Int64(parts[0]), let denom = Int64(parts[1]) else { return nil }
        return try? Money(num: num, denom: denom)
    }
}

private func findDescendant(_ node: XNode, localName name: String) -> XNode? {
    for child in node.children {
        if local(child.name) == name { return child }
        if let found = findDescendant(child, localName: name) { return found }
    }
    return nil
}

private func local(_ name: String) -> String {
    if let colon = name.lastIndex(of: ":") {
        return String(name[name.index(after: colon)...])
    }
    return name
}

private func leaf(_ name: String, _ value: String, attributes: [String: String] = [:]) -> XNode {
    let node = XNode(name: name, attributes: attributes)
    node.text = escapeXml(value)
    return node
}

private func escapeXml(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func decodeXmlEntities(_ raw: String) -> String {
    guard raw.contains("&") else { return raw }
    var result = ""
    var remaining = Substring(raw)
    while let ampersand = remaining.firstIndex(of: "&") {
        result += remaining[remaining.startIndex..<ampersand]
        let afterAmp = remaining.index(after: ampersand)
        guard let semicolon = remaining[afterAmp...].firstIndex(of: ";") else {
            result += remaining[ampersand...]
            remaining = Substring("")
            break
        }
        let entity = remaining[afterAmp..<semicolon]
        switch entity {
        case "amp": result += "&"
        case "lt": result += "<"
        case "gt": result += ">"
        case "quot": result += "\""
        case "apos": result += "'"
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X"),
               let code = UInt32(entity.dropFirst(2), radix: 16),
               let scalar = Unicode.Scalar(code)
            {
                result += String(Character(scalar))
            } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                result += String(Character(scalar))
            } else {
                result += remaining[ampersand...semicolon]
            }
        }
        remaining = remaining[remaining.index(after: semicolon)...]
    }
    result += remaining
    return result
}

/// A hand-rolled XML element/text node. `.text` always holds pre-escaped
/// content (matching what was parsed, or freshly escaped when this engine
/// sets it), so the serializer never needs to -- and never double-escapes
/// -- untouched nodes it is only passing through.
private final class XNode {
    let name: String
    var attributes: [String: String]
    var children: [XNode] = []
    var text: String = ""
    weak var parent: XNode?

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    func addChild(_ child: XNode) {
        child.parent = self
        children.append(child)
    }

    func insertChild(_ child: XNode, at index: Int) {
        child.parent = self
        let clamped = max(0, min(index, children.count))
        children.insert(child, at: clamped)
    }

    func detach() {
        if let currentParent = parent, let position = currentParent.children.firstIndex(where: { $0 === self }) {
            currentParent.children.remove(at: position)
        }
        parent = nil
    }

    var indexInParent: Int? {
        parent?.children.firstIndex(where: { $0 === self })
    }
}

private enum XMLTreeParseError: Error {
    case malformed
}

/// A deliberately small, pure-Swift XML parser (no platform-specific DOM
/// API): elements, attributes, self-closing tags, comments and processing
/// instructions. GnuCash writes no CDATA or DTD in books, but CDATA is
/// still handled for robustness against hand-edited or third-party files.
private func parseXMLTree(_ xml: String) throws -> XNode {
    let root = XNode(name: "#document")
    var stack: [XNode] = [root]
    var index = xml.startIndex
    let end = xml.endIndex

    func top() throws -> XNode {
        guard let node = stack.last else { throw XMLTreeParseError.malformed }
        return node
    }

    while index < end {
        guard let openRange = xml.range(of: "<", range: index..<end) else {
            let trailing = String(xml[index..<end])
            if !trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try top().text += trailing
            }
            break
        }
        if openRange.lowerBound > index {
            try top().text += String(xml[index..<openRange.lowerBound])
        }
        let open = openRange.lowerBound

        if xml[open...].hasPrefix("<!--") {
            guard let closeRange = xml.range(of: "-->", range: open..<end) else {
                throw XMLTreeParseError.malformed
            }
            index = closeRange.upperBound
            continue
        }
        if xml[open...].hasPrefix("<?") {
            guard let closeRange = xml.range(of: "?>", range: open..<end) else {
                throw XMLTreeParseError.malformed
            }
            index = closeRange.upperBound
            continue
        }
        if xml[open...].hasPrefix("<![CDATA[") {
            guard let closeRange = xml.range(of: "]]>", range: open..<end) else {
                throw XMLTreeParseError.malformed
            }
            let contentStart = xml.index(open, offsetBy: 9)
            try top().text += escapeXml(String(xml[contentStart..<closeRange.lowerBound]))
            index = closeRange.upperBound
            continue
        }

        guard let tagEnd = xml.range(of: ">", range: open..<end) else {
            throw XMLTreeParseError.malformed
        }
        let bodyStart = xml.index(after: open)
        let rawBody = xml[bodyStart..<tagEnd.lowerBound]
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        index = tagEnd.upperBound

        if body.hasPrefix("/") {
            let name = body.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let closed = stack.popLast(), closed.name == name else {
                throw XMLTreeParseError.malformed
            }
            continue
        }

        let selfClosing = body.hasSuffix("/")
        let content = selfClosing ? String(body.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : body
        let (name, attributes) = parseTag(content)
        let node = XNode(name: name, attributes: attributes)
        try top().addChild(node)
        if !selfClosing {
            stack.append(node)
        }
    }

    guard stack.count == 1 else { throw XMLTreeParseError.malformed }
    return root
}

private func parseTag(_ content: String) -> (name: String, attributes: [String: String]) {
    guard let spaceIndex = content.firstIndex(where: { $0.isWhitespace }) else {
        return (content, [:])
    }
    let name = String(content[content.startIndex..<spaceIndex])
    let rest = content[content.index(after: spaceIndex)...]
    return (name, parseAttributes(String(rest)))
}

private func parseAttributes(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    var remaining = Substring(text)
    while let equals = remaining.firstIndex(of: "=") {
        let key = remaining[remaining.startIndex..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        remaining = remaining[remaining.index(after: equals)...]
        guard let quoteStart = remaining.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { break }
        let quoteChar = remaining[quoteStart]
        let valueStart = remaining.index(after: quoteStart)
        guard let quoteEnd = remaining[valueStart...].firstIndex(of: quoteChar) else { break }
        if !key.isEmpty {
            result[key] = String(remaining[valueStart..<quoteEnd])
        }
        remaining = remaining[remaining.index(after: quoteEnd)...]
    }
    return result
}

/// Renders the (possibly mutated) tree back to XML. Nodes this engine never
/// touched are emitted exactly as parsed; mutated/created nodes carry
/// pre-escaped text, so no node is ever escaped twice.
private func serializeNode(_ node: XNode, into output: inout String) {
    output += "<\(node.name)"
    for (key, value) in node.attributes.sorted(by: { $0.key < $1.key }) {
        output += " \(key)=\"\(escapeXml(value))\""
    }
    if !node.children.isEmpty {
        output += ">"
        for child in node.children {
            serializeNode(child, into: &output)
        }
        output += "</\(node.name)>"
    } else if node.text.isEmpty {
        output += "/>"
    } else {
        output += ">\(node.text)</\(node.name)>"
    }
}
