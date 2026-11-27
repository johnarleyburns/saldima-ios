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
    /// document order.
    func transactions() -> [TransactionRow] {
        children(book, localName: "transaction")
            .compactMap(transactionRow)
            .sorted { $0.date > $1.date || ($0.date == $1.date && $0.guid.rawValue > $1.guid.rawValue) }
    }

    func transaction(_ guid: Guid) -> TransactionRow? {
        transactionIndex[guid].flatMap(transactionRow)
    }

    private func transactionRow(_ node: XNode) -> TransactionRow? {
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
