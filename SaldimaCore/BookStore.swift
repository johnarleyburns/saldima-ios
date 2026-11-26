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

public struct StoredSplit: Sendable, Hashable {
    public let accountGuid: Guid
    public let value: Money

    public init(accountGuid: Guid, value: Money) {
        self.accountGuid = accountGuid
        self.value = value
    }
}

public struct StoredTransaction: Sendable, Hashable, Identifiable {
    public let guid: Guid
    public let date: String
    public let description: String
    public let splits: [StoredSplit]

    public var id: Guid { guid }

    public init(guid: Guid, date: String, description: String, splits: [StoredSplit]) {
        self.guid = guid
        self.date = date
        self.description = description
        self.splits = splits
    }
}

public enum JournalError: Error, Equatable, Sendable {
    case invalidDate
    case tooFewSplits
    case unknownAccount(Guid)
    case unbalanced
    case alreadyPosted(Guid)
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
                splits: row.splits.map { StoredSplit(accountGuid: $0.accountGuid, value: $0.value) }
            )
        }
    }

    /// Posts a balanced journal entry.
    @discardableResult
    public func post(
        date: String,
        description: String,
        splits: [StoredSplit],
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
        try save()
        return txGuid
    }

    public func deleteTransaction(_ guid: Guid) throws {
        guard let document else { throw BookStoreError.cannotOpen }
        document.deleteTransaction(guid)
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
