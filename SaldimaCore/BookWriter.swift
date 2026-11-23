// SPDX-License-Identifier: AGPL-3.0-only

import CSQLite
import Foundation

/// The book's default currency commodity. Amounts in the file are rationals
/// with the currency's `fraction` as the usual denominator.
public struct BookCurrency: Sendable, Hashable {
    public let code: String
    public let fullName: String
    public let fraction: Int64

    public init(code: String, fullName: String, fraction: Int64) {
        self.code = code
        self.fullName = fullName
        self.fraction = fraction
    }

    public static let usd = BookCurrency(code: "USD", fullName: "US Dollar", fraction: 100)
    public static let eur = BookCurrency(code: "EUR", fullName: "Euro", fraction: 100)
    public static let gbp = BookCurrency(code: "GBP", fullName: "Pound Sterling", fraction: 100)
}

public enum BookWriterError: Error, Equatable, Sendable {
    case alreadyExists
    case cannotCreate
    case sqlite(String)
}

/// Creates a fresh GnuCash 5.14 SQLite book from one of our account templates.
///
/// The schema is the observed on-disk interface of GnuCash 5.14 (the version we
/// pin as the oracle); no GnuCash source is copied. Only the tables GnuCash
/// needs to open and save the book are written, and every GUID comes from an
/// injected `IDGenerator` so tests replay exactly.
public enum BookWriter {
    public static let gnuCashVersion: Int64 = 5_000_014
    public static let gnuCashResaveVersion: Int64 = 19_920

    /// Writes a book at `url`. Never overwrites unless `overwrite` is true.
    public static func create(
        at url: URL,
        template: BookTemplate,
        currency: BookCurrency = .usd,
        ids: any IDGenerator,
        overwrite: Bool = false
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            guard overwrite else { throw BookWriterError.alreadyExists }
            try fileManager.removeItem(at: url)
        }

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard status == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw BookWriterError.cannotCreate
        }
        defer { sqlite3_close(database) }

        try execute(database, "PRAGMA journal_mode = DELETE;")
        try execute(database, "BEGIN IMMEDIATE;")
        do {
            try execute(database, schema)
            try insertVersions(database)

            let bookGuid = ids.guid()
            let rootGuid = ids.guid()
            let templateRootGuid = ids.guid()
            let commodityGuid = ids.guid()

            try insertCommodity(database, guid: commodityGuid, currency: currency)
            try insertAccount(
                database,
                guid: rootGuid,
                name: "Root Account",
                type: "ROOT",
                commodity: nil,
                parent: nil,
                hidden: false,
                placeholder: false
            )
            try insertAccount(
                database,
                guid: templateRootGuid,
                name: "Template Root",
                type: "ROOT",
                commodity: nil,
                parent: nil,
                hidden: false,
                placeholder: false
            )
            try insertRow(
                database,
                "INSERT INTO books(guid, root_account_guid, root_template_guid) VALUES (?, ?, ?);",
                [bookGuid.rawValue, rootGuid.rawValue, templateRootGuid.rawValue]
            )

            func write(_ accounts: [TemplateAccount], parent: Guid) throws {
                for account in accounts {
                    let guid = ids.guid()
                    try insertAccount(
                        database,
                        guid: guid,
                        name: account.name,
                        type: account.type.rawValue,
                        commodity: commodityGuid,
                        parent: parent,
                        hidden: false,
                        placeholder: account.placeholder
                    )
                    try write(account.children, parent: guid)
                }
            }
            try write(template.roots, parent: rootGuid)

            try execute(database, "COMMIT;")
        } catch {
            try? execute(database, "ROLLBACK;")
            throw error
        }
    }

    // MARK: - Rows

    private static func insertVersions(_ database: OpaquePointer) throws {
        let rows: [(String, Int64)] = [
            ("Gnucash", gnuCashVersion),
            ("Gnucash-Resave", gnuCashResaveVersion),
            ("accounts", 1),
            ("billterms", 2),
            ("books", 1),
            ("budget_amounts", 1),
            ("budgets", 1),
            ("commodities", 1),
            ("customers", 2),
            ("employees", 2),
            ("entries", 4),
            ("invoices", 4),
            ("jobs", 1),
            ("lots", 2),
            ("orders", 1),
            ("prices", 3),
            ("recurrences", 2),
            ("schedxactions", 1),
            ("slots", 4),
            ("splits", 5),
            ("taxtable_entries", 3),
            ("taxtables", 2),
            ("transactions", 4),
            ("vendors", 1),
        ]
        for (table, version) in rows {
            try insertRow(
                database,
                "INSERT INTO versions(table_name, table_version) VALUES (?, ?);",
                [table, version]
            )
        }
    }

    private static func insertCommodity(
        _ database: OpaquePointer,
        guid: Guid,
        currency: BookCurrency
    ) throws {
        try insertRow(
            database,
            """
            INSERT INTO commodities(
                guid, namespace, mnemonic, fullname, cusip, fraction,
                quote_flag, quote_source, quote_tz
            ) VALUES (?, 'CURRENCY', ?, ?, NULL, ?, 1, 'currency', NULL);
            """,
            [guid.rawValue, currency.code, currency.fullName, currency.fraction]
        )
    }

    private static func insertAccount(
        _ database: OpaquePointer,
        guid: Guid,
        name: String,
        type: String,
        commodity: Guid?,
        parent: Guid?,
        hidden: Bool,
        placeholder: Bool
    ) throws {
        try insertRow(
            database,
            """
            INSERT INTO accounts(
                guid, name, account_type, commodity_guid, commodity_scu,
                non_std_scu, parent_guid, code, description, hidden, placeholder
            ) VALUES (?, ?, ?, ?, 0, 0, ?, '', '', ?, ?);
            """,
            [
                guid.rawValue,
                name,
                type,
                commodity.map { $0.rawValue as any SQLiteValue } ?? SQLiteNull(),
                parent.map { $0.rawValue as any SQLiteValue } ?? SQLiteNull(),
                hidden ? 1 : 0,
                placeholder ? 1 : 0,
            ]
        )
    }

    // MARK: - SQLite

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            throw BookWriterError.sqlite(message)
        }
    }

    private static func insertRow(
        _ database: OpaquePointer,
        _ sql: String,
        _ values: [any SQLiteValue]
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookWriterError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(database, statement, values)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw BookWriterError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func bind(
        _ database: OpaquePointer,
        _ statement: OpaquePointer?,
        _ values: [any SQLiteValue]
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case let text as String:
                status = sqlite3_bind_text(statement, index, text, -1, transient)
            case let number as Int64:
                status = sqlite3_bind_int64(statement, index, number)
            case let number as Int:
                status = sqlite3_bind_int64(statement, index, Int64(number))
            case is SQLiteNull:
                status = sqlite3_bind_null(statement, index)
            default:
                status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else {
                throw BookWriterError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    // swiftlint:disable line_length
    /// GnuCash 5.14 tables, in the order the SQLite backend creates them.
    static let schema = """
    CREATE TABLE accounts(guid text(32) PRIMARY KEY NOT NULL, name text(2048) NOT NULL, account_type text(2048) NOT NULL, commodity_guid text(32), commodity_scu integer NOT NULL, non_std_scu integer NOT NULL, parent_guid text(32), code text(2048), description text(2048), hidden integer, placeholder integer);
    CREATE TABLE billterms(guid text(32) PRIMARY KEY NOT NULL, name text(2048) NOT NULL, description text(2048) NOT NULL, refcount integer NOT NULL, invisible integer NOT NULL, parent text(32), type text(2048) NOT NULL, duedays integer, discountdays integer, discount_num bigint, discount_denom bigint, cutoff integer);
    CREATE TABLE books(guid text(32) PRIMARY KEY NOT NULL, root_account_guid text(32) NOT NULL, root_template_guid text(32) NOT NULL);
    CREATE TABLE budget_amounts(id integer PRIMARY KEY AUTOINCREMENT NOT NULL, budget_guid text(32) NOT NULL, account_guid text(32) NOT NULL, period_num integer NOT NULL, amount_num bigint NOT NULL, amount_denom bigint NOT NULL);
    CREATE TABLE budgets(guid text(32) PRIMARY KEY NOT NULL, name text(2048) NOT NULL, description text(2048), num_periods integer NOT NULL);
    CREATE TABLE commodities(guid text(32) PRIMARY KEY NOT NULL, namespace text(2048) NOT NULL, mnemonic text(2048) NOT NULL, fullname text(2048), cusip text(2048), fraction integer NOT NULL, quote_flag integer NOT NULL, quote_source text(2048), quote_tz text(2048));
    CREATE TABLE customers(guid text(32) PRIMARY KEY NOT NULL, name text(2048) NOT NULL, id text(2048) NOT NULL, notes text(2048) NOT NULL, active integer NOT NULL, discount_num bigint NOT NULL, discount_denom bigint NOT NULL, credit_num bigint NOT NULL, credit_denom bigint NOT NULL, currency text(32) NOT NULL, tax_override integer NOT NULL, addr_name text(1024), addr_addr1 text(1024), addr_addr2 text(1024), addr_addr3 text(1024), addr_addr4 text(1024), addr_phone text(128), addr_fax text(128), addr_email text(256), shipaddr_name text(1024), shipaddr_addr1 text(1024), shipaddr_addr2 text(1024), shipaddr_addr3 text(1024), shipaddr_addr4 text(1024), shipaddr_phone text(128), shipaddr_fax text(128), shipaddr_email text(256), terms text(32), tax_included integer, taxtable text(32));
    CREATE TABLE employees(guid text(32) PRIMARY KEY NOT NULL, username text(2048) NOT NULL, id text(2048) NOT NULL, language text(2048) NOT NULL, acl text(2048) NOT NULL, active integer NOT NULL, currency text(32) NOT NULL, ccard_guid text(32), workday_num bigint NOT NULL, workday_denom bigint NOT NULL, rate_num bigint NOT NULL, rate_denom bigint NOT NULL, addr_name text(1024), addr_addr1 text(1024), addr_addr2 text(1024), addr_addr3 text(1024), addr_addr4 text(1024), addr_phone text(128), addr_fax text(128), addr_email text(256));
    CREATE TABLE entries(guid text(32) PRIMARY KEY NOT NULL, date text(19) NOT NULL, date_entered text(19), description text(2048), action text(2048), notes text(2048), quantity_num bigint, quantity_denom bigint, i_acct text(32), i_price_num bigint, i_price_denom bigint, i_discount_num bigint, i_discount_denom bigint, invoice text(32), i_disc_type text(2048), i_disc_how text(2048), i_taxable integer, i_taxincluded integer, i_taxtable text(32), b_acct text(32), b_price_num bigint, b_price_denom bigint, bill text(32), b_taxable integer, b_taxincluded integer, b_taxtable text(32), b_paytype integer, billable integer, billto_type integer, billto_guid text(32), order_guid text(32));
    CREATE TABLE gnclock ( Hostname varchar(255), PID int );
    CREATE TABLE invoices(guid text(32) PRIMARY KEY NOT NULL, id text(2048) NOT NULL, date_opened text(19), date_posted text(19), notes text(2048) NOT NULL, active integer NOT NULL, currency text(32) NOT NULL, owner_type integer, owner_guid text(32), terms text(32), billing_id text(2048), post_txn text(32), post_lot text(32), post_acc text(32), billto_type integer, billto_guid text(32), charge_amt_num bigint, charge_amt_denom bigint);
    CREATE TABLE jobs(guid text(32) PRIMARY KEY NOT NULL, id text(2048) NOT NULL, name text(2048) NOT NULL, reference text(2048) NOT NULL, active integer NOT NULL, owner_type integer, owner_guid text(32));
    CREATE TABLE lots(guid text(32) PRIMARY KEY NOT NULL, account_guid text(32), is_closed integer NOT NULL);
    CREATE TABLE orders(guid text(32) PRIMARY KEY NOT NULL, id text(2048) NOT NULL, notes text(2048) NOT NULL, reference text(2048) NOT NULL, active integer NOT NULL, date_opened text(19) NOT NULL, date_closed text(19) NOT NULL, owner_type integer NOT NULL, owner_guid text(32) NOT NULL);
    CREATE TABLE prices(guid text(32) PRIMARY KEY NOT NULL, commodity_guid text(32) NOT NULL, currency_guid text(32) NOT NULL, date text(19) NOT NULL, source text(2048), type text(2048), value_num bigint NOT NULL, value_denom bigint NOT NULL);
    CREATE TABLE recurrences(id integer PRIMARY KEY AUTOINCREMENT NOT NULL, obj_guid text(32) NOT NULL, recurrence_mult integer NOT NULL, recurrence_period_type text(2048) NOT NULL, recurrence_period_start text(8) NOT NULL, recurrence_weekend_adjust text(2048) NOT NULL);
    CREATE TABLE schedxactions(guid text(32) PRIMARY KEY NOT NULL, name text(2048), enabled integer NOT NULL, start_date text(8), end_date text(8), last_occur text(8), num_occur integer NOT NULL, rem_occur integer NOT NULL, auto_create integer NOT NULL, auto_notify integer NOT NULL, adv_creation integer NOT NULL, adv_notify integer NOT NULL, instance_count integer NOT NULL, template_act_guid text(32) NOT NULL);
    CREATE TABLE slots(id integer PRIMARY KEY AUTOINCREMENT NOT NULL, obj_guid text(32) NOT NULL, name text(4096) NOT NULL, slot_type integer NOT NULL, int64_val bigint, string_val text(4096), double_val float8, timespec_val text(19), guid_val text(32), numeric_val_num bigint, numeric_val_denom bigint, gdate_val text(8));
    CREATE TABLE splits(guid text(32) PRIMARY KEY NOT NULL, tx_guid text(32) NOT NULL, account_guid text(32) NOT NULL, memo text(2048) NOT NULL, action text(2048) NOT NULL, reconcile_state text(1) NOT NULL, reconcile_date text(19), value_num bigint NOT NULL, value_denom bigint NOT NULL, quantity_num bigint NOT NULL, quantity_denom bigint NOT NULL, lot_guid text(32));
    CREATE TABLE taxtable_entries(id integer PRIMARY KEY AUTOINCREMENT NOT NULL, taxtable text(32) NOT NULL, account text(32) NOT NULL, amount_num bigint NOT NULL, amount_denom bigint NOT NULL, type integer NOT NULL);
    CREATE TABLE taxtables(guid text(32) PRIMARY KEY NOT NULL, name text(50) NOT NULL, refcount bigint NOT NULL, invisible integer NOT NULL, parent text(32));
    CREATE TABLE transactions(guid text(32) PRIMARY KEY NOT NULL, currency_guid text(32) NOT NULL, num text(2048) NOT NULL, post_date text(19), enter_date text(19), description text(2048));
    CREATE TABLE vendors(guid text(32) PRIMARY KEY NOT NULL, name text(2048) NOT NULL, id text(2048) NOT NULL, notes text(2048) NOT NULL, currency text(32) NOT NULL, active integer NOT NULL, tax_override integer NOT NULL, addr_name text(1024), addr_addr1 text(1024), addr_addr2 text(1024), addr_addr3 text(1024), addr_addr4 text(1024), addr_phone text(128), addr_fax text(128), addr_email text(256), terms text(32), tax_inc text(2048), tax_table text(32));
    CREATE TABLE versions(table_name text(50) PRIMARY KEY NOT NULL, table_version integer NOT NULL);
    """
    // swiftlint:enable line_length
}

public struct SQLiteNull: Sendable {
    public init() {}
}

public protocol SQLiteValue {}
extension String: SQLiteValue {}
extension Int: SQLiteValue {}
extension Int64: SQLiteValue {}
extension SQLiteNull: SQLiteValue {}
