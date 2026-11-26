// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

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
    }

    struct TransactionRow: Sendable, Hashable {
        let guid: Guid
        let date: String
        let description: String
        let splits: [SplitRow]
    }

    struct CurrencyInfo: Sendable, Hashable {
        let code: String
        let fullName: String
        let fraction: Int64
        let guid: Guid?
    }

    private let document: XMLDocument
    private let book: XMLElement
    private var accountIndex: [Guid: XMLElement] = [:]
    private var transactionIndex: [Guid: XMLElement] = [:]

    private init(document: XMLDocument, book: XMLElement) {
        self.document = document
        self.book = book
        reindex()
    }

    // MARK: - Loading

    static func parse(data: Data) throws -> XMLBookDocument {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: [])
        } catch {
            throw BookFormatError.malformedXML
        }
        guard let root = document.rootElement(),
              let book = firstChild(root, localName: "book")
        else {
            throw BookFormatError.malformedXML
        }
        return XMLBookDocument(document: document, book: book)
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
        let document = XMLDocument()
        document.version = "1.0"
        document.characterEncoding = "utf-8"

        let root = element("gnc-v2")
        for (prefix, uri) in namespaceURIs {
            root.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
        }
        document.setRootElement(root)

        let countData = element("gnc:count-data")
        countData.addAttribute(attribute("cd:type", "book"))
        countData.stringValue = "1"
        root.addChild(countData)

        let book = element("gnc:book")
        book.addAttribute(attribute("version", "2.0.0"))
        root.addChild(book)

        let bookId = element("book:id", text: snapshot.bookGuid.rawValue)
        bookId.addAttribute(attribute("type", "guid"))
        book.addChild(bookId)

        let currencyCommodity = element("gnc:commodity")
        currencyCommodity.addAttribute(attribute("version", "2.0.0"))
        currencyCommodity.addChild(element("cmdty:space", text: "CURRENCY"))
        currencyCommodity.addChild(element("cmdty:id", text: currencyCode))
        currencyCommodity.addChild(element("cmdty:fraction", text: String(fraction)))
        book.addChild(currencyCommodity)

        let rootAccount = snapshot.accounts.first { $0.type == "ROOT" }
        let rootGuid = rootAccount?.guid ?? ids.guid()
        book.addChild(accountElement(
            guid: rootGuid,
            name: rootAccount?.name ?? "Root Account",
            type: "ROOT",
            parentGuid: nil,
            code: "",
            description: "",
            hidden: false,
            placeholder: false,
            commodityGuid: nil
        ))
        book.addChild(accountElement(
            guid: templateRootGuid,
            name: "Template Root",
            type: "ROOT",
            parentGuid: nil,
            code: "",
            description: "",
            hidden: false,
            placeholder: false,
            commodityGuid: nil
        ))

        for account in snapshot.accounts where account.guid != rootGuid {
            book.addChild(accountElement(
                guid: account.guid,
                name: account.name,
                type: account.type,
                parentGuid: account.parentGuid,
                code: account.code,
                description: account.description,
                hidden: account.hidden,
                placeholder: account.placeholder,
                commodityGuid: nil
            ))
        }

        for transaction in snapshot.transactions {
            let splits = transaction.splits.map { split in
                (guid: ids.guid(), accountGuid: split.accountGuid, value: split.value)
            }
            book.addChild(transactionElement(
                guid: transaction.guid,
                date: transaction.date,
                description: transaction.description,
                splits: splits
            ))
        }

        return XMLBookDocument(document: document, book: book)
    }

    func serialize() -> Data {
        Data(document.xmlString(options: [.nodePrettyPrint]).utf8)
    }

    // MARK: - Reading

    private func reindex() {
        accountIndex.removeAll()
        transactionIndex.removeAll()
        for element in Self.children(book, localName: "account") {
            if let guid = Self.guidValue(element, localName: "id") {
                accountIndex[guid] = element
            }
        }
        for element in Self.children(book, localName: "transaction") {
            if let guid = Self.guidValue(element, localName: "id") {
                transactionIndex[guid] = element
            }
        }
    }

    var bookGuid: Guid? {
        guard let idNode = Self.firstChild(book, localName: "id") else { return nil }
        return Guid(Self.textValue(idNode))
    }

    func accounts() -> [AccountRow] {
        Self.children(book, localName: "account").compactMap(accountRow)
    }

    func account(_ guid: Guid) -> AccountRow? {
        accountIndex[guid].flatMap(accountRow)
    }

    private func accountRow(_ element: XMLElement) -> AccountRow? {
        guard let guid = Self.guidValue(element, localName: "id"),
              let name = Self.firstChild(element, localName: "name").map(Self.textValue),
              let type = Self.firstChild(element, localName: "type").map(Self.textValue)
        else {
            return nil
        }
        let parent = Self.guidValue(element, localName: "parent")
        let code = Self.firstChild(element, localName: "code").map(Self.textValue) ?? ""
        let description = Self.firstChild(element, localName: "description").map(Self.textValue) ?? ""
        let (hidden, placeholder) = readFlags(element)
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

    private func readFlags(_ accountElement: XMLElement) -> (hidden: Bool, placeholder: Bool) {
        guard let slots = Self.firstChild(accountElement, localName: "slots") else {
            return (false, false)
        }
        var hidden = false
        var placeholder = false
        for slot in Self.children(slots, localName: "slot") {
            guard let key = Self.firstChild(slot, localName: "key").map(Self.textValue) else { continue }
            let value = Self.firstChild(slot, localName: "value").map(Self.textValue) ?? ""
            if key == "hidden" { hidden = value == "true" }
            if key == "placeholder" { placeholder = value == "true" }
        }
        return (hidden, placeholder)
    }

    /// The CURRENCY-namespace commodity GnuCash would show first, preferring
    /// USD when more than one exists (matches the SQLite-era query order).
    func currency() -> CurrencyInfo? {
        let commodities = Self.children(book, localName: "commodity").filter { commodity in
            Self.firstChild(commodity, localName: "space").map(Self.textValue) == "CURRENCY"
        }
        guard !commodities.isEmpty else { return nil }
        let chosen = commodities.first { Self.firstChild($0, localName: "id").map(Self.textValue) == "USD" }
            ?? commodities[0]
        guard let code = Self.firstChild(chosen, localName: "id").map(Self.textValue) else { return nil }
        let fullName = Self.firstChild(chosen, localName: "name").map(Self.textValue) ?? code
        let fraction = Self.firstChild(chosen, localName: "fraction").map(Self.textValue).flatMap(Int64.init) ?? 100
        return CurrencyInfo(code: code, fullName: fullName, fraction: fraction, guid: nil)
    }

    /// The transactions, newest first; splits within a transaction keep
    /// document order.
    func transactions() -> [TransactionRow] {
        Self.children(book, localName: "transaction")
            .compactMap(transactionRow)
            .sorted { $0.date > $1.date || ($0.date == $1.date && $0.guid.rawValue > $1.guid.rawValue) }
    }

    func transaction(_ guid: Guid) -> TransactionRow? {
        transactionIndex[guid].flatMap(transactionRow)
    }

    private func transactionRow(_ element: XMLElement) -> TransactionRow? {
        guard let guid = Self.guidValue(element, localName: "id"),
              let description = Self.firstChild(element, localName: "description").map(Self.textValue)
        else {
            return nil
        }
        let date = Self.firstChild(element, localName: "date-posted")
            .flatMap { Self.firstChild($0, localName: "date") }
            .map(Self.textValue)
            .map { String($0.prefix(10)) } ?? ""
        let splitsContainer = Self.firstChild(element, localName: "splits")
        let splits = Self.children(splitsContainer ?? element, localName: "split").compactMap { splitElement -> SplitRow? in
            guard let account = Self.guidValue(splitElement, localName: "account"),
                  let valueText = Self.firstChild(splitElement, localName: "value").map(Self.textValue),
                  let value = Self.rational(valueText)
            else {
                return nil
            }
            return SplitRow(accountGuid: account, value: value)
        }
        return TransactionRow(guid: guid, date: date, description: description, splits: splits)
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
        let newElement = Self.accountElement(
            guid: guid,
            name: name,
            type: type,
            parentGuid: parentGuid,
            code: code,
            description: description,
            hidden: hidden,
            placeholder: placeholder,
            commodityGuid: commodityGuid
        )
        if let firstTransaction = Self.children(book, localName: "transaction").first {
            book.insertChild(newElement, at: firstTransaction.index)
        } else {
            book.addChild(newElement)
        }
        accountIndex[guid] = newElement
        return accountRow(newElement)!
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
        guard let element = accountIndex[guid] else { return }
        Self.setChildText(element, localName: "name", prefix: "act", value: name)
        Self.setChildText(element, localName: "type", prefix: "act", value: type)
        Self.setChildText(element, localName: "code", prefix: "act", value: code)
        Self.setChildText(element, localName: "description", prefix: "act", value: description)

        if let existingParent = Self.firstChild(element, localName: "parent") {
            if let parentGuid {
                existingParent.stringValue = parentGuid.rawValue
            } else {
                existingParent.detach()
            }
        } else if let parentGuid {
            let parentNode = Self.element("act:parent", text: parentGuid.rawValue)
            parentNode.addAttribute(Self.attribute("type", "guid"))
            element.addChild(parentNode)
        }

        let slots = Self.firstChild(element, localName: "slots") ?? {
            let created = Self.element("act:slots")
            element.addChild(created)
            return created
        }()
        Self.setBooleanSlot(slots, key: "hidden", value: hidden)
        Self.setBooleanSlot(slots, key: "placeholder", value: placeholder)
        if Self.children(slots, localName: "slot").isEmpty {
            slots.detach()
        }
    }

    func deleteAccount(_ guid: Guid) {
        guard let element = accountIndex[guid] else { return }
        element.detach()
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
        let element = Self.transactionElement(
            guid: guid,
            date: date,
            description: description,
            splits: splits.map { (guid: $0.splitGuid, accountGuid: $0.accountGuid, value: $0.value) }
        )
        book.addChild(element)
        transactionIndex[guid] = element
        return transactionRow(element)!
    }

    func deleteTransaction(_ guid: Guid) {
        guard let element = transactionIndex[guid] else { return }
        element.detach()
        transactionIndex.removeValue(forKey: guid)
    }

    // MARK: - XML helpers

    private static let namespaceURIs: [(String, String)] = [
        ("gnc", "http://www.gnucash.org/XML/gnc"),
        ("act", "http://www.gnucash.org/XML/act"),
        ("book", "http://www.gnucash.org/XML/book"),
        ("cd", "http://www.gnucash.org/XML/cd"),
        ("cmdty", "http://www.gnucash.org/XML/cmdty"),
        ("slot", "http://www.gnucash.org/XML/slot"),
        ("split", "http://www.gnucash.org/XML/split"),
        ("trn", "http://www.gnucash.org/XML/trn"),
        ("ts", "http://www.gnucash.org/XML/ts"),
    ]

    private static func element(_ name: String) -> XMLElement { XMLElement(name: name) }

    private static func element(_ name: String, text: String) -> XMLElement {
        XMLElement(name: name, stringValue: text)
    }

    private static func attribute(_ name: String, _ value: String) -> XMLNode {
        XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
    }

    private static func accountElement(
        guid: Guid,
        name: String,
        type: String,
        parentGuid: Guid?,
        code: String,
        description: String,
        hidden: Bool,
        placeholder: Bool,
        commodityGuid: Guid?
    ) -> XMLElement {
        let accountElement = element("gnc:account")
        accountElement.addAttribute(attribute("version", "2.0.0"))
        accountElement.addChild(element("act:name", text: name))
        let idNode = element("act:id", text: guid.rawValue)
        idNode.addAttribute(attribute("type", "guid"))
        accountElement.addChild(idNode)
        accountElement.addChild(element("act:type", text: type))
        if let parentGuid {
            let parentNode = element("act:parent", text: parentGuid.rawValue)
            parentNode.addAttribute(attribute("type", "guid"))
            accountElement.addChild(parentNode)
        }
        if hidden || placeholder {
            let slots = element("act:slots")
            if placeholder { slots.addChild(booleanSlotElement(key: "placeholder")) }
            if hidden { slots.addChild(booleanSlotElement(key: "hidden")) }
            accountElement.addChild(slots)
        }
        accountElement.addChild(element("act:code", text: code))
        accountElement.addChild(element("act:description", text: description))
        return accountElement
    }

    private static func booleanSlotElement(key: String) -> XMLElement {
        let slot = element("slot")
        slot.addChild(element("slot:key", text: key))
        let value = element("slot:value", text: "true")
        value.addAttribute(attribute("type", "string"))
        slot.addChild(value)
        return slot
    }

    private static func setBooleanSlot(_ slots: XMLElement, key: String, value: Bool) {
        let existing = children(slots, localName: "slot").first {
            firstChild($0, localName: "key").map(textValue) == key
        }
        if !value {
            existing?.detach()
            return
        }
        if let existing {
            if let valueNode = firstChild(existing, localName: "value") {
                valueNode.stringValue = "true"
            }
            return
        }
        slots.addChild(booleanSlotElement(key: key))
    }

    private static func setChildText(_ parent: XMLElement, localName: String, prefix: String, value: String) {
        if let existing = firstChild(parent, localName: localName) {
            existing.setChildren(nil)
            existing.stringValue = value
            return
        }
        parent.addChild(element("\(prefix):\(localName)", text: value))
    }

    private static func transactionElement(
        guid: Guid,
        date: String,
        description: String,
        splits: [(guid: Guid, accountGuid: Guid, value: Money)]
    ) -> XMLElement {
        let transactionElement = element("gnc:transaction")
        transactionElement.addAttribute(attribute("version", "2.0.0"))
        let idNode = element("trn:id", text: guid.rawValue)
        idNode.addAttribute(attribute("type", "guid"))
        transactionElement.addChild(idNode)

        let postedDate = element("trn:date-posted")
        postedDate.addChild(element("ts:date", text: "\(date) 00:00:00 +0000"))
        transactionElement.addChild(postedDate)
        let enteredDate = element("trn:date-entered")
        enteredDate.addChild(element("ts:date", text: "\(date) 00:00:00 +0000"))
        transactionElement.addChild(enteredDate)

        transactionElement.addChild(element("trn:description", text: description))

        let splitsElement = element("trn:splits")
        for split in splits {
            let splitElement = element("trn:split")
            let splitId = element("split:id", text: split.guid.rawValue)
            splitId.addAttribute(attribute("type", "guid"))
            splitElement.addChild(splitId)
            splitElement.addChild(element("split:reconciled-state", text: "n"))
            let valueText = "\(split.value.num)/\(split.value.denom)"
            splitElement.addChild(element("split:value", text: valueText))
            splitElement.addChild(element("split:quantity", text: valueText))
            let accountNode = element("split:account", text: split.accountGuid.rawValue)
            accountNode.addAttribute(attribute("type", "guid"))
            splitElement.addChild(accountNode)
            splitsElement.addChild(splitElement)
        }
        transactionElement.addChild(splitsElement)
        return transactionElement
    }

    private static func localName(_ name: String?) -> String {
        guard let name else { return "" }
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    private static func children(_ element: XMLElement, localName name: String) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }.filter { localName($0.name) == name }
    }

    private static func firstChild(_ element: XMLElement, localName name: String) -> XMLElement? {
        children(element, localName: name).first
    }

    private static func textValue(_ element: XMLElement) -> String {
        (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func guidValue(_ element: XMLElement, localName name: String) -> Guid? {
        firstChild(element, localName: name).flatMap { Guid(textValue($0)) }
    }

    private static func rational(_ text: String) -> Money? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let num = Int64(parts[0]), let denom = Int64(parts[1]) else { return nil }
        return try? Money(num: num, denom: denom)
    }
}
