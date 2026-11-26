// SPDX-License-Identifier: AGPL-3.0-only

import CSQLite
import Foundation

public enum BookImporterError: Error, Equatable, Sendable {
    case alreadyExists
    case cannotCreate
    case emptySnapshot
    case sqlite(String)
}

/// Materializes a format-neutral `BookSnapshot` (read from a desktop-authored
/// GnuCash XML file, or any other source) as a fresh, standalone
/// SQLite-backed working copy, so a book opened or imported from XML becomes
/// a real, editable local book through the exact same `BookStore` as one
/// created on-device. SQLite import/export are desktop-interchange
/// boundaries; the working copy this produces is edited like any other.
public enum BookImporter {
    public static func materialize(
        _ snapshot: BookSnapshot,
        at url: URL,
        ids: any IDGenerator,
        overwrite: Bool = false
    ) throws {
        guard !snapshot.accounts.isEmpty else { throw BookImporterError.emptySnapshot }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            guard overwrite else { throw BookImporterError.alreadyExists }
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
            throw BookImporterError.cannotCreate
        }
        defer { sqlite3_close(database) }

        do {
            try BookWriter.execute(database, "PRAGMA journal_mode = DELETE;")
            try BookWriter.execute(database, "BEGIN IMMEDIATE;")
            try BookWriter.execute(database, BookWriter.schema)
            try BookWriter.insertVersions(database)

            let currency = BookCurrency(
                code: snapshot.currencyCode ?? "USD",
                fullName: snapshot.currencyCode ?? "USD",
                fraction: snapshot.fraction ?? 100
            )
            let commodityGuid = ids.guid()
            try BookWriter.insertCommodity(database, guid: commodityGuid, currency: currency)

            let rootAccount = snapshot.accounts.first { $0.type == "ROOT" }
            let rootGuid = rootAccount?.guid ?? ids.guid()
            let templateRootGuid = ids.guid()
            try BookWriter.insertAccount(
                database,
                guid: rootGuid,
                name: rootAccount?.name ?? "Root Account",
                type: "ROOT",
                commodity: nil,
                parent: nil,
                hidden: false,
                placeholder: false
            )
            try BookWriter.insertAccount(
                database,
                guid: templateRootGuid,
                name: "Template Root",
                type: "ROOT",
                commodity: nil,
                parent: nil,
                hidden: false,
                placeholder: false
            )
            try BookWriter.insertRow(
                database,
                "INSERT INTO books(guid, root_account_guid, root_template_guid) VALUES (?, ?, ?);",
                [snapshot.bookGuid.rawValue, rootGuid.rawValue, templateRootGuid.rawValue]
            )

            for account in snapshot.accounts where account.guid != rootGuid {
                try BookWriter.insertAccount(
                    database,
                    guid: account.guid,
                    name: account.name,
                    type: account.type,
                    commodity: commodityGuid,
                    parent: account.parentGuid ?? rootGuid,
                    hidden: account.hidden,
                    placeholder: account.placeholder,
                    code: account.code,
                    description: account.description
                )
            }

            for transaction in snapshot.transactions {
                try insertTransaction(database, transaction, currencyGuid: commodityGuid, ids: ids)
            }

            try BookWriter.execute(database, "COMMIT;")
        } catch {
            try? BookWriter.execute(database, "ROLLBACK;")
            throw error
        }
    }

    private static func insertTransaction(
        _ database: OpaquePointer,
        _ transaction: SnapshotTransaction,
        currencyGuid: Guid,
        ids: any IDGenerator
    ) throws {
        let timestamp = "\(transaction.date) 00:00:00"
        try BookWriter.insertRow(
            database,
            """
            INSERT INTO transactions(guid, currency_guid, num, post_date, enter_date, description)
            VALUES (?, ?, '', ?, ?, ?);
            """,
            [transaction.guid.rawValue, currencyGuid.rawValue, timestamp, timestamp, transaction.description]
        )
        for split in transaction.splits {
            try BookWriter.insertRow(
                database,
                """
                INSERT INTO splits(
                    guid, tx_guid, account_guid, memo, action, reconcile_state,
                    reconcile_date, value_num, value_denom, quantity_num, quantity_denom, lot_guid
                ) VALUES (?, ?, ?, '', '', 'n', NULL, ?, ?, ?, ?, NULL);
                """,
                [
                    ids.guid().rawValue,
                    transaction.guid.rawValue,
                    split.accountGuid.rawValue,
                    split.value.num,
                    split.value.denom,
                    split.value.num,
                    split.value.denom,
                ]
            )
        }
    }
}
