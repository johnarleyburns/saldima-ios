// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Writes a GnuCash 5.x XML book (gzip by default), compatible with the same
/// schema the desktop reads. Only modelled fields are written; amounts stay
/// exact rationals from `Money`.
public enum XMLBookWriter {
    public static func xml(_ snapshot: BookSnapshot, ids: any IDGenerator) -> String {
        let currency = snapshot.currencyCode ?? "USD"
        let fraction = snapshot.fraction ?? 100
        let accounts = snapshot.accounts.map { account($0, currency: currency, fraction: fraction) }
        let transactions = snapshot.transactions.map {
            transaction($0, currency: currency, ids: ids)
        }
        return """
        <?xml version="1.0" encoding="utf-8" ?>
        <gnc-v2
             xmlns:gnc="http://www.gnucash.org/XML/gnc"
             xmlns:act="http://www.gnucash.org/XML/act"
             xmlns:book="http://www.gnucash.org/XML/book"
             xmlns:cd="http://www.gnucash.org/XML/cd"
             xmlns:cmdty="http://www.gnucash.org/XML/cmdty"
             xmlns:slot="http://www.gnucash.org/XML/slot"
             xmlns:split="http://www.gnucash.org/XML/split"
             xmlns:trn="http://www.gnucash.org/XML/trn"
             xmlns:ts="http://www.gnucash.org/XML/ts">
        <gnc:count-data cd:type="book">1</gnc:count-data>
        <gnc:book version="2.0.0">
        <book:id type="guid">\(escape(snapshot.bookGuid.rawValue))</book:id>
        <gnc:count-data cd:type="commodity">2</gnc:count-data>
        <gnc:count-data cd:type="account">\(snapshot.accounts.count)</gnc:count-data>
        <gnc:count-data cd:type="transaction">\(snapshot.transactions.count)</gnc:count-data>
        \(commodity(currency: currency, fraction: fraction))
        <gnc:commodity version="2.0.0">
          <cmdty:space>template</cmdty:space>
          <cmdty:id>template</cmdty:id>
          <cmdty:name>template</cmdty:name>
          <cmdty:xcode>template</cmdty:xcode>
          <cmdty:fraction>1</cmdty:fraction>
        </gnc:commodity>
        \(accounts.joined(separator: "\n"))
        \(transactions.joined(separator: "\n"))
        </gnc:book>
        </gnc-v2>

        """
    }

    /// GnuCash's default on-disk form for XML books is gzip.
    public static func data(_ snapshot: BookSnapshot, ids: any IDGenerator) throws -> Data {
        try Gzip.deflate(Data(xml(snapshot, ids: ids).utf8))
    }

    public static func write(
        at url: URL,
        snapshot: BookSnapshot,
        ids: any IDGenerator,
        overwrite: Bool = false
    ) throws {
        if FileManager.default.fileExists(atPath: url.path) && !overwrite {
            throw BookWriterError.alreadyExists
        }
        try data(snapshot, ids: ids).write(to: url, options: .atomic)
    }

    private static func commodity(currency: String, fraction: Int64) -> String {
        """
        <gnc:commodity version="2.0.0">
          <cmdty:space>CURRENCY</cmdty:space>
          <cmdty:id>\(escape(currency))</cmdty:id>
          <cmdty:get_quotes/>
          <cmdty:quote_source>currency</cmdty:quote_source>
          <cmdty:quote_tz/>
          <cmdty:fraction>\(fraction)</cmdty:fraction>
        </gnc:commodity>
        """
    }

    private static func account(
        _ account: SnapshotAccount,
        currency: String,
        fraction: Int64
    ) -> String {
        let commodity = account.type == "ROOT"
            ? ""
            : """
              <act:commodity>
                <cmdty:space>CURRENCY</cmdty:space>
                <cmdty:id>\(escape(currency))</cmdty:id>
              </act:commodity>
              <act:commodity-scu>\(fraction)</act:commodity-scu>
              """
        let parent = account.parentGuid.map {
            "\n  <act:parent type=\"guid\">\(escape($0.rawValue))</act:parent>"
        } ?? ""
        let slots = accountSlots(hidden: account.hidden, placeholder: account.placeholder)
        return """
        <gnc:account version="2.0.0">
          <act:name>\(escape(account.name))</act:name>
          <act:id type="guid">\(escape(account.guid.rawValue))</act:id>
          <act:type>\(escape(account.type))</act:type>
          \(commodity)\(parent)\(slots)
          <act:code>\(escape(account.code))</act:code>
          <act:description>\(escape(account.description))</act:description>
        </gnc:account>
        """
    }

    private static func accountSlots(hidden: Bool, placeholder: Bool) -> String {
        guard hidden || placeholder else { return "" }
        var slots: [String] = []
        if placeholder {
            slots.append(slot(key: "placeholder"))
        }
        if hidden {
            slots.append(slot(key: "hidden"))
        }
        return "\n  <act:slots>\(slots.joined())</act:slots>"
    }

    private static func slot(key: String) -> String {
        "<slot><slot:key>\(escape(key))</slot:key><slot:value type=\"string\">true</slot:value></slot>"
    }

    private static func transaction(
        _ transaction: SnapshotTransaction,
        currency: String,
        ids: any IDGenerator
    ) -> String {
        let splits = transaction.splits.map { split in
            let splitGuid = ids.guid().rawValue
            return """
            <trn:split>
              <split:id type="guid">\(escape(splitGuid))</split:id>
              <split:reconciled-state>n</split:reconciled-state>
              <split:value>\(split.value.num)/\(split.value.denom)</split:value>
              <split:quantity>\(split.value.num)/\(split.value.denom)</split:quantity>
              <split:account type="guid">\(escape(split.accountGuid.rawValue))</split:account>
            </trn:split>
            """
        }
        return """
        <gnc:transaction version="2.0.0">
          <trn:id type="guid">\(escape(transaction.guid.rawValue))</trn:id>
          <trn:currency>
            <cmdty:space>CURRENCY</cmdty:space>
            <cmdty:id>\(escape(transaction.currencyCode ?? currency))</cmdty:id>
          </trn:currency>
          <trn:date-posted>
            <ts:date>\(escape(String(transaction.date.prefix(10)))) 00:00:00 +0000</ts:date>
          </trn:date-posted>
          <trn:date-entered>
            <ts:date>\(escape(String(transaction.date.prefix(10)))) 00:00:00 +0000</ts:date>
          </trn:date-entered>
          <trn:description>\(escape(transaction.description))</trn:description>
          <trn:splits>
        \(splits.joined(separator: "\n"))
          </trn:splits>
        </gnc:transaction>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
