// SPDX-License-Identifier: AGPL-3.0-only

import CSQLite
import Foundation

/// Reads a GnuCash SQLite-dialect book into the format-neutral `BookSnapshot`
/// -- the import boundary for a desktop SQLite file, now that XML is the
/// live format. Excludes the structural template root exactly as the old
/// SQLite-backed `BookStore` did, so the snapshot this produces is ready to
/// hand straight to `XMLBookDocument.build(from:)`.
public enum SQLiteBookReader {
    public static func read(at url: URL) throws -> BookSnapshot {
        try requireSQLiteHeader(url)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw BookStoreError.cannotOpen
        }
        defer { sqlite3_close(database) }
        try requireAccountSchema(database)

        let templateRoot = try templateRootGuid(database)
        var accounts = try readAccounts(database)
        if let templateRoot {
            accounts.removeAll { $0.guid == templateRoot }
        }
        guard !accounts.isEmpty else { throw BookFormatError.malformedXML }

        let currency = try readCurrency(database)
        let transactions = try readTransactions(database, currencyCode: currency?.code)
        // Not every valid book has a `books` row (a minimal fixture may skip
        // it); synthesize an identity rather than refuse to open.
        let bookGuid = try bookGuid(database) ?? SystemIDGenerator().guid()

        return BookSnapshot(
            bookGuid: bookGuid,
            currencyCode: currency?.code,
            fraction: currency?.fraction,
            accounts: accounts,
            transactions: transactions
        )
    }

    private static func readAccounts(_ database: OpaquePointer) throws -> [SnapshotAccount] {
        let columns = try columnNames(database, "accounts")
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
        var accounts: [SnapshotAccount] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guidText = text(statement, 0), let guid = Guid(guidText),
                  let name = text(statement, 1),
                  let type = text(statement, 2)
            else {
                throw BookFormatError.malformedXML
            }
            let parent = text(statement, 3).flatMap(Guid.init)
            accounts.append(
                SnapshotAccount(
                    guid: guid,
                    name: name,
                    type: type,
                    parentGuid: parent,
                    code: text(statement, 4) ?? "",
                    description: text(statement, 5) ?? "",
                    hidden: sqlite3_column_int(statement, 6) != 0,
                    placeholder: sqlite3_column_int(statement, 7) != 0
                )
            )
        }
        return accounts
    }

    private static func readTransactions(
        _ database: OpaquePointer,
        currencyCode: String?
    ) throws -> [SnapshotTransaction] {
        guard try tableExists(database, "transactions"), try tableExists(database, "splits") else {
            return []
        }
        let sql = """
            SELECT t.guid, t.post_date, t.description, s.account_guid,
                   s.value_num, s.value_denom
            FROM transactions t
            JOIN splits s ON s.tx_guid = t.guid
            ORDER BY t.post_date DESC, t.guid, s.guid;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var order: [Guid] = []
        var headers: [Guid: (date: String, description: String)] = [:]
        var rows: [Guid: [SnapshotSplit]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guidText = text(statement, 0), let guid = Guid(guidText),
                  let date = text(statement, 1),
                  let description = text(statement, 2),
                  let accountText = text(statement, 3),
                  let account = Guid(accountText)
            else {
                throw BookFormatError.malformedXML
            }
            if headers[guid] == nil {
                order.append(guid)
                headers[guid] = (String(date.prefix(10)), description)
            }
            let value = try Money(
                num: sqlite3_column_int64(statement, 4),
                denom: sqlite3_column_int64(statement, 5)
            )
            rows[guid, default: []].append(SnapshotSplit(accountGuid: account, value: value))
        }
        return order.compactMap { guid in
            guard let header = headers[guid] else { return nil }
            return SnapshotTransaction(
                guid: guid,
                date: header.date,
                description: header.description,
                currencyCode: currencyCode,
                splits: rows[guid] ?? []
            )
        }
    }

    private static func readCurrency(
        _ database: OpaquePointer
    ) throws -> (code: String, fraction: Int64)? {
        guard try tableExists(database, "commodities") else { return nil }
        let sql = """
            SELECT mnemonic, fraction FROM commodities
            WHERE namespace = 'CURRENCY'
            ORDER BY mnemonic = 'USD' DESC LIMIT 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let code = text(statement, 0) else {
            return nil
        }
        return (code, sqlite3_column_int64(statement, 1))
    }

    private static func bookGuid(_ database: OpaquePointer) throws -> Guid? {
        guard try tableExists(database, "books") else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT guid FROM books LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = text(statement, 0) else { return nil }
        return Guid(text)
    }

    private static func templateRootGuid(_ database: OpaquePointer) throws -> Guid? {
        guard try tableExists(database, "books") else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT root_template_guid FROM books LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = text(statement, 0) else { return nil }
        return Guid(text)
    }

    private static func tableExists(_ database: OpaquePointer, _ name: String) throws -> Bool {
        let sql = "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, name, -1, transient) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) > 0
    }

    private static func columnNames(_ database: OpaquePointer, _ table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            throw BookStoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { names.insert(name) }
        }
        return names
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
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 2 else {
            throw BookStoreError.missingSchema
        }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}
