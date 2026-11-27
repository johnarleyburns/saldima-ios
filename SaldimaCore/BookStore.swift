// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A GnuCash account node. `children` is populated by `BookStore.accounts()`.
public struct Account: Hashable, Sendable, Identifiable {
    public let guid: Guid
    public let name: String
    public let accountType: String
    public let parentGuid: Guid?
    public let code: String
    public let description: String
    public let hidden: Bool
    public let placeholder: Bool
    public var children: [Account]

    public var id: Guid { guid }

    public init(
        guid: Guid,
        name: String,
        accountType: String,
        parentGuid: Guid?,
        code: String = "",
        description: String = "",
        hidden: Bool,
        placeholder: Bool,
        children: [Account] = []
    ) {
        self.guid = guid
        self.name = name
        self.accountType = accountType
        self.parentGuid = parentGuid
        self.code = code
        self.description = description
        self.hidden = hidden
        self.placeholder = placeholder
        self.children = children
    }
}

/// The editable fields of an account. `type` is limited to the ten user-facing
/// GnuCash types the web accepts; `ROOT` is structural and never editable.
public struct AccountDraft: Sendable, Hashable {
    public var name: String
    public var type: AccountType
    public var parentGuid: Guid?
    public var code: String
    public var description: String
    public var hidden: Bool
    public var placeholder: Bool

    public init(
        name: String,
        type: AccountType,
        parentGuid: Guid? = nil,
        code: String = "",
        description: String = "",
        hidden: Bool = false,
        placeholder: Bool = false
    ) {
        self.name = name
        self.type = type
        self.parentGuid = parentGuid
        self.code = code
        self.description = description
        self.hidden = hidden
        self.placeholder = placeholder
    }
}

public struct StoredSplit: Sendable, Hashable, Identifiable {
    public let accountGuid: Guid
    public let value: Money
    public let guid: Guid?
    public let memo: String
    /// `"n"` not reconciled, `"c"` cleared, `"y"` reconciled, `"v"` voided -- GnuCash's own codes.
    public let reconcileState: String
    /// Set only once `reconcileState` is `"y"`; `YYYY-MM-DD HH:MM:SS +ZZZZ`.
    public let reconcileDate: String?
    /// Pre-void value, set only while the parent transaction is voided.
    public let voidFormerValue: Money?

    public var id: Guid { guid ?? accountGuid }

    public init(
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

public struct StoredTransaction: Sendable, Hashable, Identifiable {
    public let guid: Guid
    public let date: String
    public let description: String
    public let splits: [StoredSplit]
    /// A path relative to the book's own directory, to a captured receipt
    /// image -- GnuCash's "Associate File/Location" slot. `nil` if none.
    public let docLink: String?
    /// True once `voidTransaction` has run; every split's value is zeroed.
    public let voided: Bool
    public let voidReason: String?
    /// `YYYY-MM-DD HH:MM:SS +ZZZZ`, set only while voided.
    public let voidTime: String?

    public var id: Guid { guid }

    public init(
        guid: Guid,
        date: String,
        description: String,
        splits: [StoredSplit],
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

public enum JournalError: Error, Equatable, Sendable {
    case invalidDate
    case tooFewSplits
    case unknownAccount(Guid)
    case unknownTransaction(Guid)
    case unbalanced
    case alreadyPosted(Guid)
    case unknownSplit(Guid)
    case missingReconcileDate
    case blankVoidReason
    case alreadyVoided(Guid)
    case notVoided(Guid)
}

public enum AccountEditError: Error, Equatable, Sendable {
    case invalidName
    case invalidType
    case unknownAccount(Guid)
    case moveIntoSubtree
    case accountHasChildren
    case accountInUse
    case protectedAccount
}

/// One template split of a scheduled transaction: Milestone-1 scope,
/// mirroring the web's locked design (`johnarleyburns/saldima#98`) -- a
/// real posting account and a fixed, signed numeric amount. Formulas are
/// written to the file for compatibility but never evaluated.
public struct ScheduledSplit: Sendable, Hashable {
    public let accountGuid: Guid
    public let value: Money

    public init(accountGuid: Guid, value: Money) {
        self.accountGuid = accountGuid
        self.value = value
    }
}

/// A schedule's end condition, mutually exclusive on disk; `nil` means
/// "no end".
public enum ScheduledEndCondition: Sendable, Hashable {
    case occurrences(Int)
    case date(String)
}

/// A scheduled/recurring transaction -- desktop GnuCash's own "Scheduled
/// Transactions" editor. `start`/`recurrence`/`templateSplits` are
/// immutable once created (delete and recreate instead): the web's own
/// `UpdateScheduledTransactionInput` restricts an edit to the same six
/// fields `ScheduledTransactionEditDraft` exposes, and this mirrors that
/// exactly rather than offering more.
public struct ScheduledTransaction: Sendable, Hashable, Identifiable {
    public let guid: Guid
    public let name: String
    public let enabled: Bool
    public let autoCreate: Bool
    public let autoCreateNotify: Bool
    public let advanceCreateDays: Int
    public let advanceRemindDays: Int
    public let instanceCount: Int
    public let start: String
    public let last: String?
    public let end: ScheduledEndCondition?
    public let recurrence: Recurrence
    public let templateSplits: [ScheduledSplit]

    public var id: Guid { guid }
}

/// The fields a new schedule is created with. `enabled` defaults to `true`,
/// matching desktop GnuCash's own default for a freshly created schedule.
public struct ScheduledTransactionDraft: Sendable, Hashable {
    public var name: String
    public var enabled: Bool
    public var autoCreate: Bool
    public var autoCreateNotify: Bool
    public var advanceCreateDays: Int
    public var advanceRemindDays: Int
    public var start: String
    public var end: ScheduledEndCondition?
    public var recurrence: Recurrence
    public var templateSplits: [ScheduledSplit]

    public init(
        name: String,
        enabled: Bool = true,
        autoCreate: Bool = false,
        autoCreateNotify: Bool = false,
        advanceCreateDays: Int = 0,
        advanceRemindDays: Int = 0,
        start: String,
        end: ScheduledEndCondition? = nil,
        recurrence: Recurrence,
        templateSplits: [ScheduledSplit]
    ) {
        self.name = name
        self.enabled = enabled
        self.autoCreate = autoCreate
        self.autoCreateNotify = autoCreateNotify
        self.advanceCreateDays = advanceCreateDays
        self.advanceRemindDays = advanceRemindDays
        self.start = start
        self.end = end
        self.recurrence = recurrence
        self.templateSplits = templateSplits
    }
}

/// The only fields an existing schedule can patch -- matches web exactly;
/// everything else requires delete and recreate.
public struct ScheduledTransactionEditDraft: Sendable, Hashable {
    public var name: String
    public var enabled: Bool
    public var autoCreate: Bool
    public var autoCreateNotify: Bool
    public var advanceCreateDays: Int
    public var advanceRemindDays: Int

    public init(
        name: String,
        enabled: Bool,
        autoCreate: Bool,
        autoCreateNotify: Bool,
        advanceCreateDays: Int,
        advanceRemindDays: Int
    ) {
        self.name = name
        self.enabled = enabled
        self.autoCreate = autoCreate
        self.autoCreateNotify = autoCreateNotify
        self.advanceCreateDays = advanceCreateDays
        self.advanceRemindDays = advanceRemindDays
    }
}

/// How a due instance is handled -- mirrors the web's
/// `dueScheduledInstances` classification exactly. `autoPost` happens
/// silently; `autoPostNotify` also posts but stays in the review list
/// purely for display; `needsApproval`/`reminder` wait for the owner.
public enum ScheduledTransactionAction: String, Sendable, Hashable {
    case autoPost
    case autoPostNotify
    case needsApproval
    case reminder
}

/// One instance of a schedule that is due (or coming up) as of some
/// reference date -- the "check on open" result shown on the register.
public struct DueScheduledInstance: Sendable, Hashable, Identifiable {
    public let scheduledTransactionGuid: Guid
    public let name: String
    public let date: String
    public let action: ScheduledTransactionAction

    public var id: String { "\(scheduledTransactionGuid.rawValue)-\(date)" }
}

public enum ScheduledTransactionError: Error, Equatable, Sendable {
    case invalidName
    case tooFewSplits
    case unbalanced
    case unknownAccount(Guid)
    case invalidRecurrence
    case unknownScheduledTransaction(Guid)
}

/// A GnuCash `GncCustomer` business object: a billing contact for invoices.
public struct Customer: Hashable, Sendable, Identifiable {
    public let guid: Guid
    public let name: String
    public let customerNumber: String
    public let addressName: String
    public let addressLine1: String
    public let addressLine2: String
    public let phone: String
    public let email: String
    public let notes: String
    public let active: Bool

    public var id: Guid { guid }

    public init(
        guid: Guid,
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
        self.guid = guid
        self.name = name
        self.customerNumber = customerNumber
        self.addressName = addressName
        self.addressLine1 = addressLine1
        self.addressLine2 = addressLine2
        self.phone = phone
        self.email = email
        self.notes = notes
        self.active = active
    }
}

public struct CustomerDraft: Sendable, Hashable {
    public var name: String
    public var customerNumber: String
    public var addressName: String
    public var addressLine1: String
    public var addressLine2: String
    public var phone: String
    public var email: String
    public var notes: String
    public var active: Bool

    public init(
        name: String,
        customerNumber: String = "",
        addressName: String = "",
        addressLine1: String = "",
        addressLine2: String = "",
        phone: String = "",
        email: String = "",
        notes: String = "",
        active: Bool = true
    ) {
        self.name = name
        self.customerNumber = customerNumber
        self.addressName = addressName
        self.addressLine1 = addressLine1
        self.addressLine2 = addressLine2
        self.phone = phone
        self.email = email
        self.notes = notes
        self.active = active
    }
}

/// One line on an invoice: a `GncEntry` business object.
public struct InvoiceLine: Hashable, Sendable, Identifiable {
    public let guid: Guid
    public let date: String
    public let description: String
    public let quantity: Money
    public let unitPrice: Money
    public let incomeAccountGuid: Guid

    public var id: Guid { guid }
    public var amount: Money { (try? Money.multiply(quantity, unitPrice)) ?? .zero }

    public init(
        guid: Guid,
        date: String,
        description: String,
        quantity: Money,
        unitPrice: Money,
        incomeAccountGuid: Guid
    ) {
        self.guid = guid
        self.date = date
        self.description = description
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.incomeAccountGuid = incomeAccountGuid
    }
}

/// A GnuCash `GncInvoice` business object. `datePosted == nil` means it is
/// still a draft, GnuCash's own distinction between an open and posted
/// invoice -- posting is the one-way action that creates the real
/// receivable/income transaction behind it.
public struct Invoice: Hashable, Sendable, Identifiable {
    public let guid: Guid
    public let invoiceNumber: String
    public let customerGuid: Guid
    public let dateOpened: String
    public let datePosted: String?
    public let notes: String
    public let active: Bool
    public let lines: [InvoiceLine]

    public var id: Guid { guid }
    public var isPosted: Bool { datePosted != nil }
    public var total: Money {
        lines.reduce(Money.zero) { sum, line in (try? Money.add(sum, line.amount)) ?? sum }
    }

    public init(
        guid: Guid,
        invoiceNumber: String,
        customerGuid: Guid,
        dateOpened: String,
        datePosted: String?,
        notes: String,
        active: Bool,
        lines: [InvoiceLine]
    ) {
        self.guid = guid
        self.invoiceNumber = invoiceNumber
        self.customerGuid = customerGuid
        self.dateOpened = dateOpened
        self.datePosted = datePosted
        self.notes = notes
        self.active = active
        self.lines = lines
    }
}

public enum CustomerEditError: Error, Equatable, Sendable {
    case invalidName
    case unknownCustomer(Guid)
    case customerInUse
}

public enum InvoiceEditError: Error, Equatable, Sendable {
    case unknownCustomer(Guid)
    case unknownInvoice(Guid)
    case alreadyPosted(Guid)
    case noLines
    case unknownAccount(Guid)
}

/// A GnuCash `GncVendor` business object: who a bill is owed to.
public struct Vendor: Hashable, Sendable, Identifiable {
    public let guid: Guid
    public let name: String
    public let vendorNumber: String
    public let addressLine1: String
    public let phone: String
    public let email: String
    public let notes: String
    public let active: Bool

    public var id: Guid { guid }

    public init(
        guid: Guid,
        name: String,
        vendorNumber: String,
        addressLine1: String,
        phone: String,
        email: String,
        notes: String,
        active: Bool
    ) {
        self.guid = guid
        self.name = name
        self.vendorNumber = vendorNumber
        self.addressLine1 = addressLine1
        self.phone = phone
        self.email = email
        self.notes = notes
        self.active = active
    }
}

public struct VendorDraft: Sendable, Hashable {
    public var name: String
    public var vendorNumber: String
    public var addressLine1: String
    public var phone: String
    public var email: String
    public var notes: String
    public var active: Bool

    public init(
        name: String,
        vendorNumber: String = "",
        addressLine1: String = "",
        phone: String = "",
        email: String = "",
        notes: String = "",
        active: Bool = true
    ) {
        self.name = name
        self.vendorNumber = vendorNumber
        self.addressLine1 = addressLine1
        self.phone = phone
        self.email = email
        self.notes = notes
        self.active = active
    }
}

/// One line on a bill: also a `GncEntry`, but using its bill-side fields.
public struct BillLine: Hashable, Sendable, Identifiable {
    public let guid: Guid
    public let date: String
    public let description: String
    public let quantity: Money
    public let unitPrice: Money
    public let expenseAccountGuid: Guid

    public var id: Guid { guid }
    public var amount: Money { (try? Money.multiply(quantity, unitPrice)) ?? .zero }

    public init(
        guid: Guid,
        date: String,
        description: String,
        quantity: Money,
        unitPrice: Money,
        expenseAccountGuid: Guid
    ) {
        self.guid = guid
        self.date = date
        self.description = description
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.expenseAccountGuid = expenseAccountGuid
    }
}

/// A vendor bill: GnuCash stores it as a `gnc:GncInvoice` exactly like a
/// customer invoice, distinguished only by `invoice:owner`'s `owner:type`.
/// `datePosted == nil` means it is still a draft; posting is the one-way
/// action that creates the real payable/expense transaction behind it.
public struct Bill: Hashable, Sendable, Identifiable {
    public let guid: Guid
    public let billNumber: String
    public let vendorGuid: Guid
    public let dateOpened: String
    public let datePosted: String?
    public let notes: String
    public let active: Bool
    public let lines: [BillLine]

    public var id: Guid { guid }
    public var isPosted: Bool { datePosted != nil }
    public var total: Money {
        lines.reduce(Money.zero) { sum, line in (try? Money.add(sum, line.amount)) ?? sum }
    }

    public init(
        guid: Guid,
        billNumber: String,
        vendorGuid: Guid,
        dateOpened: String,
        datePosted: String?,
        notes: String,
        active: Bool,
        lines: [BillLine]
    ) {
        self.guid = guid
        self.billNumber = billNumber
        self.vendorGuid = vendorGuid
        self.dateOpened = dateOpened
        self.datePosted = datePosted
        self.notes = notes
        self.active = active
        self.lines = lines
    }
}

public enum VendorEditError: Error, Equatable, Sendable {
    case invalidName
    case unknownVendor(Guid)
    case vendorInUse
}

public enum BillEditError: Error, Equatable, Sendable {
    case unknownVendor(Guid)
    case unknownBill(Guid)
    case alreadyPosted(Guid)
    case noLines
    case unknownAccount(Guid)
}

public enum BookStoreError: Error, Equatable, Sendable {
    case cannotOpen
    case notSQLite
    case missingSchema
    case corruptData
    case sqlite(String)
}

/// A live, editable GnuCash book. XML is the canonical on-disk format: the
/// whole document is parsed once on open, mutated in memory by `XMLBookDocument`,
/// and atomically rewritten on every change -- the same way desktop GnuCash's
/// own XML backend behaves. A legacy SQLite-dialect file still opens (read
/// through `SQLiteBookReader` and held as the equivalent in-memory XML model)
/// but is rewritten as XML the first time anything is saved; `BookImporter`
/// is the explicit, immediate version of that same conversion.
public actor BookStore {
    private var document: XMLBookDocument?
    private var fileURL: URL?

    public init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BookStoreError.cannotOpen
        }
        switch try BookFile.detect(prefix: data.prefix(4096)) {
        case .xml:
            let payload = data.starts(with: [0x1f, 0x8b]) ? try Gzip.inflate(data) : data
            self.document = try XMLBookDocument.parse(data: payload)
        case .sqlite:
            let snapshot = try SQLiteBookReader.read(at: url)
            self.document = XMLBookDocument.build(
                from: snapshot,
                templateRootGuid: SystemIDGenerator().guid(),
                ids: SystemIDGenerator()
            )
        }
        self.fileURL = url
    }

    public func close() {
        document = nil
        fileURL = nil
    }

    /// The account tree, roots and siblings sorted by name. Like the desktop
    /// Accounts window, the book root and the structural template root are
    /// not rows: the real root's children become the top level.
    public func accounts() throws -> [Account] {
        guard let document else { throw BookStoreError.cannotOpen }
        let rows = document.accounts()
        let rootCandidates = rows.filter { $0.type == "ROOT" && $0.parentGuid == nil }
        let templateRoot = rootCandidates.first { $0.name == "Template Root" }
        let bookRoot = rootCandidates.first { $0.guid != templateRoot?.guid }

        var flat: [Guid: Account] = [:]
        for row in rows where row.guid != templateRoot?.guid {
            flat[row.guid] = Account(
                guid: row.guid,
                name: row.name,
                accountType: row.type,
                parentGuid: row.parentGuid,
                code: row.code,
                description: row.description,
                hidden: row.hidden,
                placeholder: row.placeholder
            )
        }

        var childGuids: [Guid: [Guid]] = [:]
        var roots: [Guid] = []
        for account in flat.values {
            if let parent = account.parentGuid {
                guard flat[parent] != nil else { throw BookStoreError.corruptData }
                childGuids[parent, default: []].append(account.guid)
            } else {
                roots.append(account.guid)
            }
        }
        if let bookRoot = bookRoot?.guid, flat[bookRoot] != nil {
            let promoted = childGuids[bookRoot] ?? []
            roots = roots.filter { $0 != bookRoot } + promoted
        }

        func tree(_ guid: Guid, depth: Int) throws -> Account {
            guard depth <= flat.count, var account = flat[guid] else {
                throw BookStoreError.corruptData
            }
            let children = (childGuids[guid] ?? []).sorted { left, right in
                (flat[left]?.name ?? "") < (flat[right]?.name ?? "")
            }
            account.children = try children.map { try tree($0, depth: depth + 1) }
            return account
        }

        return try roots
            .sorted { (flat[$0]?.name ?? "") < (flat[$1]?.name ?? "") }
            .map { try tree($0, depth: 0) }
    }

    /// The commodity a new amount should use, normally the book currency.
    public func bookCurrency() throws -> BookCurrency? {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let currency = document.currency() else { return nil }
        return BookCurrency(code: currency.code, fullName: currency.fullName, fraction: currency.fraction)
    }

    // MARK: - Editing

    public func account(_ guid: Guid) throws -> Account? {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let row = document.account(guid) else { return nil }
        return Account(
            guid: row.guid,
            name: row.name,
            accountType: row.type,
            parentGuid: row.parentGuid,
            code: row.code,
            description: row.description,
            hidden: row.hidden,
            placeholder: row.placeholder
        )
    }

    @discardableResult
    public func createAccount(_ draft: AccountDraft, ids: any IDGenerator) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        let name = try validate(draft, editing: nil)
        let guid = ids.guid()
        document.createAccount(
            guid: guid,
            name: name,
            type: draft.type.rawValue,
            parentGuid: draft.parentGuid,
            code: draft.code,
            description: draft.description,
            hidden: draft.hidden,
            placeholder: draft.placeholder,
            commodityGuid: nil
        )
        try save()
        return guid
    }

    public func updateAccount(_ guid: Guid, with draft: AccountDraft) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let existing = try account(guid) else { throw AccountEditError.unknownAccount(guid) }
        guard existing.accountType != "ROOT" else { throw AccountEditError.protectedAccount }
        let name = try validate(draft, editing: guid)
        document.updateAccount(
            guid,
            name: name,
            type: draft.type.rawValue,
            parentGuid: draft.parentGuid,
            code: draft.code,
            description: draft.description,
            hidden: draft.hidden,
            placeholder: draft.placeholder
        )
        try save()
    }

    public func deleteAccount(_ guid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let existing = try account(guid) else { throw AccountEditError.unknownAccount(guid) }
        guard existing.accountType != "ROOT" else { throw AccountEditError.protectedAccount }
        guard document.accountCount(withParent: guid) == 0 else { throw AccountEditError.accountHasChildren }
        guard document.splitCount(forAccount: guid) == 0 else { throw AccountEditError.accountInUse }
        document.deleteAccount(guid)
        try save()
    }

    /// Validates a draft the way the web does and returns the trimmed name.
    private func validate(_ draft: AccountDraft, editing: Guid?) throws -> String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw AccountEditError.invalidName }
        if let parent = draft.parentGuid {
            if let editing, parent == editing { throw AccountEditError.moveIntoSubtree }
            guard try account(parent) != nil else { throw AccountEditError.unknownAccount(parent) }
            if let editing, try descendants(of: editing).contains(parent) {
                throw AccountEditError.moveIntoSubtree
            }
        }
        return name
    }

    private func descendants(of guid: Guid) throws -> Set<Guid> {
        guard let document else { throw BookStoreError.cannotOpen }
        var children: [Guid: [Guid]] = [:]
        for row in document.accounts() {
            if let parent = row.parentGuid {
                children[parent, default: []].append(row.guid)
            }
        }
        var found: Set<Guid> = [guid]
        var queue = [guid]
        while let current = queue.popLast() {
            for child in children[current] ?? [] where found.insert(child).inserted {
                queue.append(child)
            }
        }
        return found
    }

    /// Every transaction in the book, newest first.
    public func transactions() throws -> [StoredTransaction] {
        guard let document else { throw BookStoreError.cannotOpen }
        return document.transactions().map { row in
            StoredTransaction(
                guid: row.guid,
                date: row.date,
                description: row.description,
                splits: row.splits.map {
                    StoredSplit(
                        accountGuid: $0.accountGuid,
                        value: $0.value,
                        guid: $0.guid,
                        memo: $0.memo,
                        reconcileState: $0.reconcileState,
                        reconcileDate: $0.reconcileDate,
                        voidFormerValue: $0.voidFormerValue
                    )
                },
                docLink: row.docLink,
                voided: row.voided,
                voidReason: row.voidReason,
                voidTime: row.voidTime
            )
        }
    }

    /// Posts a balanced journal entry. `receiptPath` is a path relative to
    /// the book's own directory -- e.g. a captured receipt image -- stored
    /// as the transaction's "Associate File/Location" the way desktop
    /// GnuCash's own right-click action does.
    @discardableResult
    public func post(
        date: String,
        description: String,
        splits: [StoredSplit],
        receiptPath: String? = nil,
        ids: any IDGenerator
    ) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        guard Self.isDate(date) else { throw JournalError.invalidDate }
        guard splits.count >= 2 else { throw JournalError.tooFewSplits }
        let known = Set(document.accounts().map(\.guid))
        var total = Money.zero
        for split in splits {
            guard known.contains(split.accountGuid) else {
                throw JournalError.unknownAccount(split.accountGuid)
            }
            total = try Money.add(total, split.value)
        }
        guard total == .zero else { throw JournalError.unbalanced }

        let txGuid = ids.guid()
        document.postTransaction(
            guid: txGuid,
            date: date,
            description: description,
            splits: splits.map { (accountGuid: $0.accountGuid, value: $0.value, splitGuid: ids.guid()) }
        )
        if let receiptPath {
            document.setTransactionDocLink(txGuid, uri: receiptPath)
        }
        try save()
        return txGuid
    }

    /// Attaches (or, with `nil`, removes) a receipt on an existing
    /// transaction -- the same "Associate File/Location" slot `post` can
    /// set directly when the receipt is captured at posting time.
    public func attachReceipt(_ receiptPath: String?, to transactionGuid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard document.transaction(transactionGuid) != nil else {
            throw JournalError.unknownTransaction(transactionGuid)
        }
        document.setTransactionDocLink(transactionGuid, uri: receiptPath)
        try save()
    }

    /// Sets one split's reconcile state, the same action as checking a row
    /// off in GnuCash's Reconcile window. `reconcileDate` is required for
    /// `"y"` (reconciled) and cleared for any other state, matching desktop
    /// GnuCash. Distinct from bank integration/auto-feeds, which this app
    /// does not do -- this only records what the owner checked off by hand.
    public func setSplitReconcileState(
        transactionGuid: Guid,
        splitGuid: Guid,
        state: String,
        reconcileDate: String?
    ) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let transaction = document.transaction(transactionGuid) else {
            throw JournalError.unknownTransaction(transactionGuid)
        }
        guard transaction.splits.contains(where: { $0.guid == splitGuid }) else {
            throw JournalError.unknownSplit(splitGuid)
        }
        if state == "y", reconcileDate == nil {
            throw JournalError.missingReconcileDate
        }
        document.setSplitReconcileState(
            transactionGuid: transactionGuid,
            splitGuid: splitGuid,
            state: state,
            reconcileDate: reconcileDate
        )
        try save()
    }

    public func deleteTransaction(_ guid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        document.deleteTransaction(guid)
        try save()
    }

    /// Voids a transaction (GnuCash's "Void Transaction", not a delete): the
    /// original splits are preserved for audit but zeroed, so the
    /// transaction stops affecting any balance. Can be reversed with
    /// `unvoidTransaction`.
    public func voidTransaction(_ guid: Guid, reason: String, voidTime: String) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let transaction = document.transaction(guid) else {
            throw JournalError.unknownTransaction(guid)
        }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JournalError.blankVoidReason
        }
        guard !transaction.voided else {
            throw JournalError.alreadyVoided(guid)
        }
        document.voidTransaction(guid, reason: reason, voidTime: voidTime)
        try save()
    }

    /// Reverses `voidTransaction`. A split's reconciled state before voiding
    /// is not restored (reset to `"n"`), matching desktop GnuCash.
    public func unvoidTransaction(_ guid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let transaction = document.transaction(guid) else {
            throw JournalError.unknownTransaction(guid)
        }
        guard transaction.voided else {
            throw JournalError.notVoided(guid)
        }
        document.unvoidTransaction(guid)
        try save()
    }

    /// A full snapshot for XML export, including the structural ROOT account
    /// that the account tree deliberately hides.
    public func exportSnapshot() throws -> BookSnapshot {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let bookGuid = document.bookGuid else { throw BookStoreError.missingSchema }
        let currency = try bookCurrency() ?? .usd
        let templateRootGuid = document.accounts()
            .first { $0.type == "ROOT" && $0.parentGuid == nil && $0.name == "Template Root" }?
            .guid
        let accounts = document.accounts().filter { $0.guid != templateRootGuid }
        let snapshotAccounts = accounts.map { row in
            SnapshotAccount(
                guid: row.guid,
                name: row.name,
                type: row.type,
                parentGuid: row.parentGuid,
                commodityCode: row.type == "ROOT" ? nil : currency.code,
                code: row.code,
                description: row.description,
                hidden: row.hidden,
                placeholder: row.placeholder
            )
        }
        let snapshotTransactions = document.transactions().map { row in
            SnapshotTransaction(
                guid: row.guid,
                date: String(row.date.prefix(10)),
                description: row.description,
                currencyCode: currency.code,
                splits: row.splits.map { SnapshotSplit(accountGuid: $0.accountGuid, value: $0.value) }
            )
        }
        return BookSnapshot(
            bookGuid: bookGuid,
            currencyCode: currency.code,
            fraction: currency.fraction,
            accounts: snapshotAccounts,
            transactions: snapshotTransactions
        )
    }

    /// Sums each account's split value (the book currency amount).
    public func balances() throws -> [Guid: Money] {
        guard let document else { throw BookStoreError.cannotOpen }
        return document.balances()
    }

    // MARK: - Scheduled transactions

    public func scheduledTransactions() throws -> [ScheduledTransaction] {
        guard let document else { throw BookStoreError.cannotOpen }
        return document.scheduledTransactions().map(Self.toScheduledTransaction)
    }

    public func scheduledTransaction(_ guid: Guid) throws -> ScheduledTransaction? {
        guard let document else { throw BookStoreError.cannotOpen }
        return document.scheduledTransaction(guid).map(Self.toScheduledTransaction)
    }

    private static func toScheduledTransaction(_ row: ScheduledTransactionRow) -> ScheduledTransaction {
        ScheduledTransaction(
            guid: row.guid,
            name: row.name,
            enabled: row.enabled,
            autoCreate: row.autoCreate,
            autoCreateNotify: row.autoCreateNotify,
            advanceCreateDays: row.advanceCreateDays,
            advanceRemindDays: row.advanceRemindDays,
            instanceCount: row.instanceCount,
            start: row.start,
            last: row.last,
            end: row.end.map { (end: ScheduledEnd) -> ScheduledEndCondition in
                switch end {
                case .occurrences(let count): return .occurrences(count)
                case .date(let date): return .date(date)
                }
            },
            recurrence: row.recurrence,
            templateSplits: row.templateSplits.map { ScheduledSplit(accountGuid: $0.accountGuid, value: $0.value) }
        )
    }

    /// Creates a schedule: a per-schedule template account and template
    /// transaction mirroring the web's exact XML shape, plus the
    /// `gnc:schedxaction` itself. Validates the way `post` does (known
    /// accounts, splits balance to zero) plus the recurrence's own
    /// multiplier/date validity.
    @discardableResult
    public func createScheduledTransaction(
        _ draft: ScheduledTransactionDraft,
        ids: any IDGenerator
    ) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        let name = try validateScheduledDraft(draft)
        let currency = try bookCurrency() ?? .usd
        let guid = ids.guid()
        document.createScheduledTransaction(
            guid: guid,
            name: name,
            enabled: draft.enabled,
            autoCreate: draft.autoCreate,
            autoCreateNotify: draft.autoCreateNotify,
            advanceCreateDays: draft.advanceCreateDays,
            advanceRemindDays: draft.advanceRemindDays,
            start: draft.start,
            end: draft.end.map { (end: ScheduledEndCondition) -> ScheduledEnd in
                switch end {
                case .occurrences(let count): return .occurrences(count)
                case .date(let date): return .date(date)
                }
            },
            recurrence: draft.recurrence,
            templateSplits: draft.templateSplits.map { ScheduledSplitRow(accountGuid: $0.accountGuid, value: $0.value) },
            currencyCode: currency.code,
            currencyFraction: currency.fraction,
            ids: ids
        )
        try save()
        return guid
    }

    private func validateScheduledDraft(_ draft: ScheduledTransactionDraft) throws -> String {
        guard let document else { throw BookStoreError.cannotOpen }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ScheduledTransactionError.invalidName }
        guard draft.templateSplits.count >= 2 else { throw ScheduledTransactionError.tooFewSplits }
        guard draft.recurrence.multiplier >= 1, Self.isDate(draft.start), Self.isDate(draft.recurrence.start) else {
            throw ScheduledTransactionError.invalidRecurrence
        }
        let known = Set(document.accounts().map(\.guid))
        var total = Money.zero
        for split in draft.templateSplits {
            guard known.contains(split.accountGuid) else {
                throw ScheduledTransactionError.unknownAccount(split.accountGuid)
            }
            total = try Money.add(total, split.value)
        }
        guard total == .zero else { throw ScheduledTransactionError.unbalanced }
        return name
    }

    /// Patches only the six fields the web's own
    /// `UpdateScheduledTransactionInput` allows; everything else is
    /// immutable after creation.
    public func updateScheduledTransaction(_ guid: Guid, with draft: ScheduledTransactionEditDraft) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard document.scheduledTransaction(guid) != nil else {
            throw ScheduledTransactionError.unknownScheduledTransaction(guid)
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ScheduledTransactionError.invalidName }
        document.updateScheduledTransaction(
            guid,
            name: name,
            enabled: draft.enabled,
            autoCreate: draft.autoCreate,
            autoCreateNotify: draft.autoCreateNotify,
            advanceCreateDays: draft.advanceCreateDays,
            advanceRemindDays: draft.advanceRemindDays
        )
        try save()
    }

    public func deleteScheduledTransaction(_ guid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard document.scheduledTransaction(guid) != nil else {
            throw ScheduledTransactionError.unknownScheduledTransaction(guid)
        }
        document.deleteScheduledTransaction(guid)
        try save()
    }

    /// Every due (or soon-due) instance across every enabled schedule, as
    /// of `asOf` -- mirroring the web's `dueScheduledInstances` exactly:
    /// enumerates every instance since the schedule's last post/skip (not
    /// just the next one, so a missed auto-create instance is caught up),
    /// classifies each by `autoCreate`/`autoCreateNotify` against the
    /// create/remind horizon, and stops at the first reminder per
    /// schedule. A schedule whose occurrence count is exhausted
    /// (`instanceCount >= end.occurrences`) is skipped entirely.
    public func dueScheduledInstances(asOf: String) throws -> [DueScheduledInstance] {
        guard let document else { throw BookStoreError.cannotOpen }
        var due: [DueScheduledInstance] = []
        for row in document.scheduledTransactions() where row.enabled {
            if case .occurrences(let maxOccurrences) = row.end, row.instanceCount >= maxOccurrences {
                continue
            }
            let createBoundary = try addDays(asOf, row.advanceCreateDays)
            let remindBoundary = try addDays(createBoundary, row.advanceRemindDays)
            var current = row.last ?? "0001-01-01"
            var iterations = 0
            while true {
                iterations += 1
                guard iterations <= 1000 else { break }
                guard let next = try nextInstance(row.recurrence, after: current) else { break }
                if case .date(let endDate) = row.end, next > endDate { break }
                if next > remindBoundary { break }
                let action: ScheduledTransactionAction
                if next <= createBoundary {
                    action = row.autoCreate ? (row.autoCreateNotify ? .autoPostNotify : .autoPost) : .needsApproval
                } else {
                    action = .reminder
                }
                due.append(DueScheduledInstance(
                    scheduledTransactionGuid: row.guid,
                    name: row.name,
                    date: next,
                    action: action
                ))
                if action == .reminder { break }
                current = next
            }
        }
        return due
    }

    /// Posts a real transaction from a schedule's template splits (fixed
    /// numeric amounts only -- formulas are never evaluated) and advances
    /// the schedule past `date`.
    @discardableResult
    public func approveScheduledInstance(_ guid: Guid, date: String, ids: any IDGenerator) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let row = document.scheduledTransaction(guid) else {
            throw ScheduledTransactionError.unknownScheduledTransaction(guid)
        }
        let txGuid = ids.guid()
        document.postTransaction(
            guid: txGuid,
            date: date,
            description: row.name,
            splits: row.templateSplits.map { (accountGuid: $0.accountGuid, value: $0.value, splitGuid: ids.guid()) }
        )
        document.advanceScheduledTransaction(guid, to: date)
        try save()
        return txGuid
    }

    /// Advances a schedule past `date` without posting anything --
    /// **permanently**: there is no deferred/postponed instance list, the
    /// same deliberate Milestone-1 simplification the web carries.
    public func skipScheduledInstance(_ guid: Guid, date: String) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard document.scheduledTransaction(guid) != nil else {
            throw ScheduledTransactionError.unknownScheduledTransaction(guid)
        }
        document.advanceScheduledTransaction(guid, to: date)
        try save()
    }

    /// "Check on open": computes every due instance and immediately posts
    /// the ones configured to auto-create -- silently for `autoPost`, or
    /// posted-but-still-shown for `autoPostNotify` -- exactly mirroring the
    /// web's `processDueScheduledTransactions`. Call this every time the
    /// journal/register loads; there is no background job. Returns the
    /// review list: everything except the silent auto-posts.
    @discardableResult
    public func processDueScheduledTransactions(asOf: String, ids: any IDGenerator) throws -> [DueScheduledInstance] {
        guard let document else { throw BookStoreError.cannotOpen }
        let due = try dueScheduledInstances(asOf: asOf)
        var posted = false
        for instance in due where instance.action == .autoPost || instance.action == .autoPostNotify {
            guard let row = document.scheduledTransaction(instance.scheduledTransactionGuid) else { continue }
            let txGuid = ids.guid()
            document.postTransaction(
                guid: txGuid,
                date: instance.date,
                description: row.name,
                splits: row.templateSplits.map { (accountGuid: $0.accountGuid, value: $0.value, splitGuid: ids.guid()) }
            )
            document.advanceScheduledTransaction(instance.scheduledTransactionGuid, to: instance.date)
            posted = true
        }
        if posted { try save() }
        return due.filter { $0.action != .autoPost }
    }

    // MARK: - Customers

    public func customers() throws -> [Customer] {
        guard let document else { throw BookStoreError.cannotOpen }
        return document.customers().map(Self.toCustomer).sorted { $0.name < $1.name }
    }

    public func customer(_ guid: Guid) throws -> Customer? {
        guard let document else { throw BookStoreError.cannotOpen }
        return document.customer(guid).map(Self.toCustomer)
    }

    @discardableResult
    public func createCustomer(_ draft: CustomerDraft, ids: any IDGenerator) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        let name = try validateCustomer(draft)
        let currency = try bookCurrency() ?? .usd
        let guid = ids.guid()
        document.createCustomer(
            guid: guid,
            name: name,
            customerNumber: draft.customerNumber,
            addressName: draft.addressName,
            addressLine1: draft.addressLine1,
            addressLine2: draft.addressLine2,
            phone: draft.phone,
            email: draft.email,
            notes: draft.notes,
            currencyCode: currency.code
        )
        try save()
        return guid
    }

    public func updateCustomer(_ guid: Guid, with draft: CustomerDraft) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard document.customer(guid) != nil else { throw CustomerEditError.unknownCustomer(guid) }
        let name = try validateCustomer(draft)
        document.updateCustomer(
            guid,
            name: name,
            customerNumber: draft.customerNumber,
            addressName: draft.addressName,
            addressLine1: draft.addressLine1,
            addressLine2: draft.addressLine2,
            phone: draft.phone,
            email: draft.email,
            notes: draft.notes,
            active: draft.active
        )
        try save()
    }

    public func deleteCustomer(_ guid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard document.customer(guid) != nil else { throw CustomerEditError.unknownCustomer(guid) }
        guard !document.customerInUse(guid) else { throw CustomerEditError.customerInUse }
        document.deleteCustomer(guid)
        try save()
    }

    private func validateCustomer(_ draft: CustomerDraft) throws -> String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw CustomerEditError.invalidName }
        return name
    }

    private static func toCustomer(_ row: XMLBookDocument.CustomerRow) -> Customer {
        Customer(
            guid: row.guid,
            name: row.name,
            customerNumber: row.customerNumber,
            addressName: row.addressName,
            addressLine1: row.addressLine1,
            addressLine2: row.addressLine2,
            phone: row.phone,
            email: row.email,
            notes: row.notes,
            active: row.active
        )
    }

    // MARK: - Invoices

    /// Every invoice, most recently opened first.
    public func invoices() throws -> [Invoice] {
        guard let document else { throw BookStoreError.cannotOpen }
        return document.invoices()
            .map { toInvoice($0, document: document) }
            .sorted { $0.dateOpened > $1.dateOpened }
    }

    public func invoice(_ guid: Guid) throws -> Invoice? {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let row = document.invoice(guid) else { return nil }
        return toInvoice(row, document: document)
    }

    private func toInvoice(_ row: XMLBookDocument.InvoiceRow, document: XMLBookDocument) -> Invoice {
        let lines = document.invoiceEntries(forInvoice: row.guid).map { entry in
            InvoiceLine(
                guid: entry.guid,
                date: entry.date,
                description: entry.description,
                quantity: entry.quantity,
                unitPrice: entry.unitPrice,
                incomeAccountGuid: entry.incomeAccountGuid
            )
        }
        return Invoice(
            guid: row.guid,
            invoiceNumber: row.invoiceNumber,
            customerGuid: row.customerGuid,
            dateOpened: row.dateOpened,
            datePosted: row.datePosted,
            notes: row.notes,
            active: row.active,
            lines: lines
        )
    }

    @discardableResult
    public func createInvoiceDraft(
        customerGuid: Guid,
        invoiceNumber: String,
        dateOpened: String,
        notes: String = "",
        ids: any IDGenerator
    ) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        guard document.customer(customerGuid) != nil else {
            throw InvoiceEditError.unknownCustomer(customerGuid)
        }
        guard Self.isDate(dateOpened) else { throw JournalError.invalidDate }
        let currency = try bookCurrency() ?? .usd
        let guid = ids.guid()
        document.createInvoice(
            guid: guid,
            invoiceNumber: invoiceNumber,
            customerGuid: customerGuid,
            dateOpened: dateOpened,
            notes: notes,
            currencyCode: currency.code
        )
        try save()
        return guid
    }

    @discardableResult
    public func addInvoiceLine(
        _ invoiceGuid: Guid,
        date: String,
        description: String,
        quantity: Money,
        unitPrice: Money,
        incomeAccountGuid: Guid,
        ids: any IDGenerator
    ) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let invoice = document.invoice(invoiceGuid) else {
            throw InvoiceEditError.unknownInvoice(invoiceGuid)
        }
        guard !invoice.isPosted else { throw InvoiceEditError.alreadyPosted(invoiceGuid) }
        guard document.account(incomeAccountGuid) != nil else {
            throw InvoiceEditError.unknownAccount(incomeAccountGuid)
        }
        guard Self.isDate(date) else { throw JournalError.invalidDate }
        let guid = ids.guid()
        document.addInvoiceEntry(
            guid: guid,
            invoiceGuid: invoiceGuid,
            date: date,
            description: description,
            quantity: quantity,
            unitPrice: unitPrice,
            incomeAccountGuid: incomeAccountGuid
        )
        try save()
        return guid
    }

    public func deleteInvoiceLine(_ guid: Guid, invoiceGuid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let invoice = document.invoice(invoiceGuid) else {
            throw InvoiceEditError.unknownInvoice(invoiceGuid)
        }
        guard !invoice.isPosted else { throw InvoiceEditError.alreadyPosted(invoiceGuid) }
        document.deleteInvoiceEntry(guid)
        try save()
    }

    public func deleteInvoiceDraft(_ guid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let invoice = document.invoice(guid) else { throw InvoiceEditError.unknownInvoice(guid) }
        guard !invoice.isPosted else { throw InvoiceEditError.alreadyPosted(guid) }
        document.deleteInvoice(guid)
        try save()
    }

    /// Posts a draft invoice: debits `receivableAccountGuid` for the total
    /// and credits each line's income account for its amount -- the same
    /// effect as desktop GnuCash's "Post Invoice", and the one-way action
    /// that turns a draft into permanent ledger history.
    @discardableResult
    public func postInvoice(
        _ guid: Guid,
        receivableAccountGuid: Guid,
        postedDate: String,
        ids: any IDGenerator
    ) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let invoiceRow = document.invoice(guid) else { throw InvoiceEditError.unknownInvoice(guid) }
        guard !invoiceRow.isPosted else { throw InvoiceEditError.alreadyPosted(guid) }
        guard document.account(receivableAccountGuid) != nil else {
            throw InvoiceEditError.unknownAccount(receivableAccountGuid)
        }
        guard Self.isDate(postedDate) else { throw JournalError.invalidDate }
        let lines = document.invoiceEntries(forInvoice: guid)
        guard !lines.isEmpty else { throw InvoiceEditError.noLines }

        var total = Money.zero
        var splits: [(accountGuid: Guid, value: Money, splitGuid: Guid)] = []
        for line in lines {
            total = try Money.add(total, line.amount)
            splits.append((
                accountGuid: line.incomeAccountGuid,
                value: line.amount.negated(),
                splitGuid: ids.guid()
            ))
        }
        splits.append((accountGuid: receivableAccountGuid, value: total, splitGuid: ids.guid()))

        let txGuid = ids.guid()
        document.postTransaction(
            guid: txGuid,
            date: postedDate,
            description: "Invoice \(invoiceRow.invoiceNumber)",
            splits: splits
        )
        document.markInvoicePosted(
            guid,
            postedDate: postedDate,
            transactionGuid: txGuid,
            receivableAccountGuid: receivableAccountGuid
        )
        try save()
        return txGuid
    }

    // MARK: - Vendors

    public func vendors() throws -> [Vendor] {
        guard let document else { throw BookStoreError.cannotOpen }
        return document.vendors().map(Self.toVendor).sorted { $0.name < $1.name }
    }

    public func vendor(_ guid: Guid) throws -> Vendor? {
        guard let document else { throw BookStoreError.cannotOpen }
        return document.vendor(guid).map(Self.toVendor)
    }

    @discardableResult
    public func createVendor(_ draft: VendorDraft, ids: any IDGenerator) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        let name = try validateVendor(draft)
        let currency = try bookCurrency() ?? .usd
        let guid = ids.guid()
        document.createVendor(
            guid: guid,
            name: name,
            vendorNumber: draft.vendorNumber,
            addressLine1: draft.addressLine1,
            phone: draft.phone,
            email: draft.email,
            notes: draft.notes,
            currencyCode: currency.code
        )
        try save()
        return guid
    }

    public func updateVendor(_ guid: Guid, with draft: VendorDraft) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard document.vendor(guid) != nil else { throw VendorEditError.unknownVendor(guid) }
        let name = try validateVendor(draft)
        document.updateVendor(
            guid,
            name: name,
            vendorNumber: draft.vendorNumber,
            addressLine1: draft.addressLine1,
            phone: draft.phone,
            email: draft.email,
            notes: draft.notes,
            active: draft.active
        )
        try save()
    }

    public func deleteVendor(_ guid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard document.vendor(guid) != nil else { throw VendorEditError.unknownVendor(guid) }
        guard !document.vendorInUse(guid) else { throw VendorEditError.vendorInUse }
        document.deleteVendor(guid)
        try save()
    }

    private func validateVendor(_ draft: VendorDraft) throws -> String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw VendorEditError.invalidName }
        return name
    }

    private static func toVendor(_ row: XMLBookDocument.VendorRow) -> Vendor {
        Vendor(
            guid: row.guid,
            name: row.name,
            vendorNumber: row.vendorNumber,
            addressLine1: row.addressLine1,
            phone: row.phone,
            email: row.email,
            notes: row.notes,
            active: row.active
        )
    }

    // MARK: - Bills

    /// Every bill, most recently opened first.
    public func bills() throws -> [Bill] {
        guard let document else { throw BookStoreError.cannotOpen }
        return document.bills()
            .map { toBill($0, document: document) }
            .sorted { $0.dateOpened > $1.dateOpened }
    }

    public func bill(_ guid: Guid) throws -> Bill? {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let row = document.bill(guid) else { return nil }
        return toBill(row, document: document)
    }

    private func toBill(_ row: XMLBookDocument.BillRow, document: XMLBookDocument) -> Bill {
        let lines = document.billEntries(forBill: row.guid).map { entry in
            BillLine(
                guid: entry.guid,
                date: entry.date,
                description: entry.description,
                quantity: entry.quantity,
                unitPrice: entry.unitPrice,
                expenseAccountGuid: entry.expenseAccountGuid
            )
        }
        return Bill(
            guid: row.guid,
            billNumber: row.billNumber,
            vendorGuid: row.vendorGuid,
            dateOpened: row.dateOpened,
            datePosted: row.datePosted,
            notes: row.notes,
            active: row.active,
            lines: lines
        )
    }

    @discardableResult
    public func createBillDraft(
        vendorGuid: Guid,
        billNumber: String,
        dateOpened: String,
        notes: String = "",
        ids: any IDGenerator
    ) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        guard document.vendor(vendorGuid) != nil else {
            throw BillEditError.unknownVendor(vendorGuid)
        }
        guard Self.isDate(dateOpened) else { throw JournalError.invalidDate }
        let currency = try bookCurrency() ?? .usd
        let guid = ids.guid()
        document.createBill(
            guid: guid,
            billNumber: billNumber,
            vendorGuid: vendorGuid,
            dateOpened: dateOpened,
            notes: notes,
            currencyCode: currency.code
        )
        try save()
        return guid
    }

    @discardableResult
    public func addBillLine(
        _ billGuid: Guid,
        date: String,
        description: String,
        quantity: Money,
        unitPrice: Money,
        expenseAccountGuid: Guid,
        ids: any IDGenerator
    ) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let bill = document.bill(billGuid) else {
            throw BillEditError.unknownBill(billGuid)
        }
        guard !bill.isPosted else { throw BillEditError.alreadyPosted(billGuid) }
        guard document.account(expenseAccountGuid) != nil else {
            throw BillEditError.unknownAccount(expenseAccountGuid)
        }
        guard Self.isDate(date) else { throw JournalError.invalidDate }
        let guid = ids.guid()
        document.addBillEntry(
            guid: guid,
            billGuid: billGuid,
            date: date,
            description: description,
            quantity: quantity,
            unitPrice: unitPrice,
            expenseAccountGuid: expenseAccountGuid
        )
        try save()
        return guid
    }

    public func deleteBillLine(_ guid: Guid, billGuid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let bill = document.bill(billGuid) else {
            throw BillEditError.unknownBill(billGuid)
        }
        guard !bill.isPosted else { throw BillEditError.alreadyPosted(billGuid) }
        document.deleteBillEntry(guid)
        try save()
    }

    public func deleteBillDraft(_ guid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let bill = document.bill(guid) else { throw BillEditError.unknownBill(guid) }
        guard !bill.isPosted else { throw BillEditError.alreadyPosted(guid) }
        document.deleteBill(guid)
        try save()
    }

    /// Posts a draft bill: debits each line's expense account for its
    /// amount and credits `payableAccountGuid` for the total -- the same
    /// effect as desktop GnuCash's "Post Bill", and the one-way action
    /// that turns a draft into permanent ledger history.
    @discardableResult
    public func postBill(
        _ guid: Guid,
        payableAccountGuid: Guid,
        postedDate: String,
        ids: any IDGenerator
    ) throws -> Guid {
        guard let document else { throw BookStoreError.cannotOpen }
        guard let billRow = document.bill(guid) else { throw BillEditError.unknownBill(guid) }
        guard !billRow.isPosted else { throw BillEditError.alreadyPosted(guid) }
        guard document.account(payableAccountGuid) != nil else {
            throw BillEditError.unknownAccount(payableAccountGuid)
        }
        guard Self.isDate(postedDate) else { throw JournalError.invalidDate }
        let lines = document.billEntries(forBill: guid)
        guard !lines.isEmpty else { throw BillEditError.noLines }

        var total = Money.zero
        var splits: [(accountGuid: Guid, value: Money, splitGuid: Guid)] = []
        for line in lines {
            total = try Money.add(total, line.amount)
            splits.append((accountGuid: line.expenseAccountGuid, value: line.amount, splitGuid: ids.guid()))
        }
        splits.append((accountGuid: payableAccountGuid, value: total.negated(), splitGuid: ids.guid()))

        let txGuid = ids.guid()
        document.postTransaction(
            guid: txGuid,
            date: postedDate,
            description: "Bill \(billRow.billNumber)",
            splits: splits
        )
        document.markBillPosted(
            guid,
            postedDate: postedDate,
            transactionGuid: txGuid,
            payableAccountGuid: payableAccountGuid
        )
        try save()
        return txGuid
    }

    // MARK: - Persistence

    /// Atomically rewrites the whole book, the way desktop GnuCash's XML
    /// backend saves: write a temporary file, then replace the original.
    private func save() throws {
        guard let document, let fileURL else { throw BookStoreError.cannotOpen }
        let compressed: Data
        do {
            compressed = try Gzip.deflate(document.serialize())
        } catch {
            throw BookStoreError.corruptData
        }
        // A fixed name is safe: the actor serializes its own saves, so there
        // is never more than one writer for this file at a time.
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent)-saving.tmp")
        do {
            try compressed.write(to: tempURL, options: .atomic)
            // `FileManager.replaceItemAt` is unreliable on Linux
            // (swift-corelibs-foundation); remove-then-move is simpler and
            // `rename(2)` on the same volume is still atomic.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw BookStoreError.cannotOpen
        }
    }

    private static func isDate(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let pieces = value.split(separator: "-")
        return pieces.count == 3
            && pieces[0].count == 4 && pieces[1].count == 2 && pieces[2].count == 2
            && pieces.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}
