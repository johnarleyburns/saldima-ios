// SPDX-License-Identifier: AGPL-3.0-only

import CSQLite
import Foundation

/// A GnuCash account node. `children` is populated by `BookStore.accounts()`.
public struct Account: Hashable, Sendable, Identifiable {
    public let guid: Guid
    public let name: String
    public let accountType: String
    public let parentGuid: Guid?
    public let hidden: Bool
    public let placeholder: Bool
    public var children: [Account]

    public var id: Guid { guid }

    public init(
        guid: Guid,
        name: String,
        accountType: String,
        parentGuid: Guid?,
        hidden: Bool,
        placeholder: Bool,
        children: [Account] = []
    ) {
        self.guid = guid
        self.name = name
        self.accountType = accountType
        self.parentGuid = parentGuid
        self.hidden = hidden
        self.placeholder = placeholder
        self.children = children
    }
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
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
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
        let sql = """
            SELECT guid, name, account_type, parent_guid, hidden, placeholder
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
                hidden: sqlite3_column_int(statement, 4) != 0,
                placeholder: sqlite3_column_int(statement, 5) != 0
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
