// SPDX-License-Identifier: AGPL-3.0-only

import CSQLite
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
}

public struct StoredTransaction: Sendable, Hashable, Identifiable {
    public let guid: Guid
    public let date: String
    public let description: String
    public let splits: [StoredSplit]

    public var id: Guid { guid }
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

/// Read-only access to a GnuCash SQLite book. P0 only reads the account tree;
/// posting and saving arrive in later phases.
public actor BookStore {
    private var database: OpaquePointer?

    public init(url: URL) throws {
        try Self.requireSQLiteHeader(url)

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw BookStoreError.cannotOpen
        }
        self.database = handle

        do {
            try Self.requireAccountSchema(handle)
        } catch {
            sqlite3_close(handle)
            self.database = nil
            throw error
        }
    }

    public func close() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
    }

    /// The account tree, roots and siblings sorted by name.
    public func accounts() throws -> [Account] {
        guard let database else { throw BookStoreError.cannotOpen }
        let columns = try Self.columnNames(database, "accounts")
        let code = columns.contains("code") ? "code" : "'' AS code"
        let description = columns.contains("description") ? "description" : "'' AS description"
        let sql = """
            SELECT guid, name, account_type, parent_guid, \(code), \(description),
                   hidden, placeholder
            FROM accounts
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var flat: [Guid: Account] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            guard let guidText = Self.text(statement, 0),
                  let guid = Guid(guidText),
                  let name = Self.text(statement, 1),
                  let type = Self.text(statement, 2)
            else {
                throw BookStoreError.corruptData
            }
            let parent: Guid?
            if let parentText = Self.text(statement, 3) {
                guard let parsed = Guid(parentText) else {
                    throw BookStoreError.corruptData
                }
                parent = parsed
            } else {
                parent = nil
            }
            flat[guid] = Account(
                guid: guid,
                name: name,
                accountType: type,
                parentGuid: parent,
                code: Self.text(statement, 4) ?? "",
                description: Self.text(statement, 5) ?? "",
                hidden: sqlite3_column_int(statement, 6) != 0,
                placeholder: sqlite3_column_int(statement, 7) != 0
            )
        }

        // A book's template root is structural: GnuCash keeps it out of the
        // visible tree, so we do too.
        if let templateRoot = try templateRootGuid(database) {
            flat.removeValue(forKey: templateRoot)
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

        // Like the desktop Accounts window, the book root is not a row: its
        // children are the top level.
        if let bookRoot = try bookRootGuid(database), flat[bookRoot] != nil {
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
        guard let database, try tableExists(database, "commodities") else { return nil }
        let sql = """
            SELECT mnemonic, fullname, fraction FROM commodities
            WHERE namespace = 'CURRENCY'
            ORDER BY mnemonic = 'USD' DESC LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let code = Self.text(statement, 0)
        else {
            return nil
        }
        return BookCurrency(
            code: code,
            fullName: Self.text(statement, 1) ?? code,
            fraction: sqlite3_column_int64(statement, 2)
        )
    }

    // MARK: - Editing

    public func account(_ guid: Guid) throws -> Account? {
        guard let database else { throw BookStoreError.cannotOpen }
        let columns = try Self.columnNames(database, "accounts")
        let code = columns.contains("code") ? "code" : "'' AS code"
        let description = columns.contains("description") ? "description" : "'' AS description"
        let sql = """
            SELECT guid, name, account_type, parent_guid, \(code), \(description),
                   hidden, placeholder
            FROM accounts WHERE guid = ? LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, guid.rawValue, -1, Self.transient) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let name = Self.text(statement, 1),
              let type = Self.text(statement, 2)
        else {
            throw BookStoreError.corruptData
        }
        var parent: Guid?
        if let parentText = Self.text(statement, 3) {
            guard let parsed = Guid(parentText) else { throw BookStoreError.corruptData }
            parent = parsed
        }
        return Account(
            guid: guid,
            name: name,
            accountType: type,
            parentGuid: parent,
            code: Self.text(statement, 4) ?? "",
            description: Self.text(statement, 5) ?? "",
            hidden: sqlite3_column_int(statement, 6) != 0,
            placeholder: sqlite3_column_int(statement, 7) != 0
        )
    }

    @discardableResult
    public func createAccount(_ draft: AccountDraft, ids: any IDGenerator) throws -> Guid {
        guard let database else { throw BookStoreError.cannotOpen }
        let name = try validate(draft, editing: nil)
        let guid = ids.guid()
        let sql = """
            INSERT INTO accounts(
                guid, name, account_type, commodity_guid, commodity_scu,
                non_std_scu, parent_guid, code, description, hidden, placeholder
            ) VALUES (?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, guid.rawValue, database)
        try bindText(statement, 2, name, database)
        try bindText(statement, 3, draft.type.rawValue, database)
        if let commodity = try bookCurrencyGuid() {
            try bindText(statement, 4, commodity.rawValue, database)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        if let parent = draft.parentGuid {
            try bindText(statement, 5, parent.rawValue, database)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        try bindText(statement, 6, draft.code, database)
        try bindText(statement, 7, draft.description, database)
        sqlite3_bind_int(statement, 8, draft.hidden ? 1 : 0)
        sqlite3_bind_int(statement, 9, draft.placeholder ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return guid
    }

    public func updateAccount(_ guid: Guid, with draft: AccountDraft) throws {
        guard let database else { throw BookStoreError.cannotOpen }
        guard let existing = try account(guid) else { throw AccountEditError.unknownAccount(guid) }
        guard existing.accountType != "ROOT" else { throw AccountEditError.protectedAccount }
        let name = try validate(draft, editing: guid)
        let sql = """
            UPDATE accounts
            SET name = ?, account_type = ?, parent_guid = ?, code = ?,
                description = ?, hidden = ?, placeholder = ?
            WHERE guid = ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, name, database)
        try bindText(statement, 2, draft.type.rawValue, database)
        if let parent = draft.parentGuid {
            try bindText(statement, 3, parent.rawValue, database)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        try bindText(statement, 4, draft.code, database)
        try bindText(statement, 5, draft.description, database)
        sqlite3_bind_int(statement, 6, draft.hidden ? 1 : 0)
        sqlite3_bind_int(statement, 7, draft.placeholder ? 1 : 0)
        try bindText(statement, 8, guid.rawValue, database)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    public func deleteAccount(_ guid: Guid) throws {
        guard let database else { throw BookStoreError.cannotOpen }
        guard let existing = try account(guid) else { throw AccountEditError.unknownAccount(guid) }
        guard existing.accountType != "ROOT" else { throw AccountEditError.protectedAccount }
        if try count(
            database,
            "SELECT count(*) FROM accounts WHERE parent_guid = ?;",
            guid.rawValue
        ) > 0 {
            throw AccountEditError.accountHasChildren
        }
        if try tableExists(database, "splits"),
           try count(
               database,
               "SELECT count(*) FROM splits WHERE account_guid = ?;",
               guid.rawValue
           ) > 0 {
            throw AccountEditError.accountInUse
        }
        let sql = "DELETE FROM accounts WHERE guid = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, guid.rawValue, database)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
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
        guard let database else { throw BookStoreError.cannotOpen }
        let sql = "SELECT guid, parent_guid FROM accounts;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var children: [Guid: [Guid]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guidText = Self.text(statement, 0), let child = Guid(guidText) else {
                throw BookStoreError.corruptData
            }
            if let parentText = Self.text(statement, 1), let parent = Guid(parentText) {
                children[parent, default: []].append(child)
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

    private func bookCurrencyGuid() throws -> Guid? {
        guard let database, try tableExists(database, "commodities") else { return nil }
        let sql = """
            SELECT guid FROM commodities
            WHERE namespace = 'CURRENCY'
            ORDER BY mnemonic = 'USD' DESC LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = Self.text(statement, 0),
              let guid = Guid(text)
        else {
            return nil
        }
        return guid
    }

    private func tableExists(_ database: OpaquePointer, _ name: String) throws -> Bool {
        let sql = "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, name, database)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) > 0
    }

    private func count(
        _ database: OpaquePointer,
        _ sql: String,
        _ value: String
    ) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, value, database)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func bindText(
        _ statement: OpaquePointer?,
        _ index: Int32,
        _ value: String,
        _ database: OpaquePointer
    ) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transient) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bookRootGuid(_ database: OpaquePointer) throws -> Guid? {
        guard try tableExists(database, "books") else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT root_account_guid FROM books LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = Self.text(statement, 0),
              let guid = Guid(text)
        else {
            return nil
        }
        return guid
    }

    /// Every transaction in the book, newest first.
    public func transactions() throws -> [StoredTransaction] {
        guard let database else { throw BookStoreError.cannotOpen }
        guard try tableExists(database, "transactions"), try tableExists(database, "splits") else {
            return []
        }
        var statement: OpaquePointer?
        let sql = """
            SELECT t.guid, t.post_date, t.description, s.account_guid,
                   s.value_num, s.value_denom
            FROM transactions t
            JOIN splits s ON s.tx_guid = t.guid
            ORDER BY t.post_date DESC, t.guid, s.guid;
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var order: [Guid] = []
        var headers: [Guid: (date: String, description: String)] = [:]
        var rows: [Guid: [StoredSplit]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guidText = Self.text(statement, 0), let guid = Guid(guidText),
                  let date = Self.text(statement, 1),
                  let description = Self.text(statement, 2),
                  let accountText = Self.text(statement, 3),
                  let account = Guid(accountText)
            else {
                throw BookStoreError.corruptData
            }
            if headers[guid] == nil {
                order.append(guid)
                headers[guid] = (date, description)
            }
            rows[guid, default: []].append(
                StoredSplit(
                    accountGuid: account,
                    value: try Money(
                        num: sqlite3_column_int64(statement, 4),
                        denom: sqlite3_column_int64(statement, 5)
                    )
                )
            )
        }
        return order.compactMap { guid in
            guard let header = headers[guid] else { return nil }
            return StoredTransaction(
                guid: guid,
                date: header.date,
                description: header.description,
                splits: rows[guid] ?? []
            )
        }
    }

    /// Posts a balanced journal entry into the GnuCash tables.
    @discardableResult
    public func post(
        date: String,
        description: String,
        splits: [StoredSplit],
        ids: any IDGenerator
    ) throws -> Guid {
        guard let database else { throw BookStoreError.cannotOpen }
        guard Self.isDate(date) else { throw JournalError.invalidDate }
        guard splits.count >= 2 else { throw JournalError.tooFewSplits }
        var known: Set<Guid> = []
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT guid FROM accounts;", -1, &statement, nil) == SQLITE_OK else {
                throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = Self.text(statement, 0), let guid = Guid(text) {
                    known.insert(guid)
                }
            }
        }
        var total = Money.zero
        for split in splits {
            guard known.contains(split.accountGuid) else {
                throw JournalError.unknownAccount(split.accountGuid)
            }
            total = try Money.add(total, split.value)
        }
        guard total == .zero else { throw JournalError.unbalanced }

        let txGuid = ids.guid()
        let currency = try bookCurrencyGuid()

        try run(
            database,
            """
            INSERT INTO transactions(guid, currency_guid, num, post_date,
                                     enter_date, description)
            VALUES (?, ?, '', ?, ?, ?);
            """,
            [
                txGuid.rawValue,
                currency.map { $0.rawValue as any SQLiteValue } ?? SQLiteNull(),
                "\(date) 00:00:00",
                "\(date) 00:00:00",
                description,
            ]
        )
        for split in splits {
            try run(
                database,
                """
                INSERT INTO splits(guid, tx_guid, account_guid, memo, action,
                                   reconcile_state, reconcile_date, value_num,
                                   value_denom, quantity_num, quantity_denom, lot_guid)
                VALUES (?, ?, ?, '', '', 'n', NULL, ?, ?, ?, ?, NULL);
                """,
                [
                    ids.guid().rawValue,
                    txGuid.rawValue,
                    split.accountGuid.rawValue,
                    split.value.num,
                    split.value.denom,
                    split.value.num,
                    split.value.denom,
                ]
            )
        }
        return txGuid
    }

    public func deleteTransaction(_ guid: Guid) throws {
        guard let database else { throw BookStoreError.cannotOpen }
        guard try tableExists(database, "transactions"), try tableExists(database, "splits") else {
            throw BookStoreError.missingSchema
        }
        try run(database, "DELETE FROM splits WHERE tx_guid = ?;", [guid.rawValue])
        try run(database, "DELETE FROM transactions WHERE guid = ?;", [guid.rawValue])
    }

    /// Sums each account's split value (the book currency amount).
    public func balances() throws -> [Guid: Money] {
        guard let database else { throw BookStoreError.cannotOpen }
        guard try tableExists(database, "splits") else { return [:] }
        var statement: OpaquePointer?
        let sql = "SELECT account_guid, value_num, value_denom FROM splits;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var totals: [Guid: Money] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guidText = Self.text(statement, 0), let guid = Guid(guidText) else {
                throw BookStoreError.corruptData
            }
            let value = try Money(
                num: sqlite3_column_int64(statement, 1),
                denom: sqlite3_column_int64(statement, 2)
            )
            totals[guid] = try Money.add(totals[guid] ?? .zero, value)
        }
        return totals
    }

    private func templateRootGuid(_ database: OpaquePointer) throws -> Guid? {
        guard try tableExists(database, "books") else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT root_template_guid FROM books LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = Self.text(statement, 0),
              let guid = Guid(text)
        else {
            return nil
        }
        return guid
    }

    private static func columnNames(
        _ database: OpaquePointer,
        _ table: String
    ) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) {
                names.insert(name)
            }
        }
        return names
    }

    private func run(
        _ database: OpaquePointer,
        _ sql: String,
        _ values: [any SQLiteValue]
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String:
                guard sqlite3_bind_text(statement, index, text, -1, Self.transient) == SQLITE_OK else {
                    throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
                }
            case let number as Int64:
                guard sqlite3_bind_int64(statement, index, number) == SQLITE_OK else {
                    throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
                }
            case let number as Int:
                guard sqlite3_bind_int64(statement, index, Int64(number)) == SQLITE_OK else {
                    throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
                }
            default:
                sqlite3_bind_null(statement, index)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func isDate(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let pieces = value.split(separator: "-")
        return pieces.count == 3
            && pieces[0].count == 4 && pieces[1].count == 2 && pieces[2].count == 2
            && pieces.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func requireSQLiteHeader(_ url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw BookStoreError.cannotOpen
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16),
              header == Data("SQLite format 3\u{0}".utf8)
        else {
            throw BookStoreError.notSQLite
        }
    }

    private static func requireAccountSchema(_ database: OpaquePointer) throws {
        let sql = """
            SELECT count(*) FROM sqlite_master
            WHERE type = 'table' AND name IN ('accounts', 'versions')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw BookStoreError.missingSchema
        }
        guard sqlite3_column_int(statement, 0) == 2 else {
            throw BookStoreError.missingSchema
        }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}
