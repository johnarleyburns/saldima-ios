// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// A format-neutral view of a book, produced by any backend reader. GUIDs are
/// kept so callers can match rows against the SQLite side.
public struct SnapshotAccount: Sendable, Hashable {
    public let guid: Guid
    public let name: String
    public let type: String
    public let parentGuid: Guid?
    public let commodityCode: String?
    public let code: String
    public let description: String
    public let hidden: Bool
    public let placeholder: Bool

    public init(
        guid: Guid,
        name: String,
        type: String,
        parentGuid: Guid? = nil,
        commodityCode: String? = nil,
        code: String = "",
        description: String = "",
        hidden: Bool = false,
        placeholder: Bool = false
    ) {
        self.guid = guid
        self.name = name
        self.type = type
        self.parentGuid = parentGuid
        self.commodityCode = commodityCode
        self.code = code
        self.description = description
        self.hidden = hidden
        self.placeholder = placeholder
    }
}

public struct SnapshotSplit: Sendable, Hashable {
    public let accountGuid: Guid
    public let value: Money

    public init(accountGuid: Guid, value: Money) {
        self.accountGuid = accountGuid
        self.value = value
    }
}

public struct SnapshotTransaction: Sendable, Hashable {
    public let guid: Guid
    public let date: String
    public let description: String
    public let currencyCode: String?
    public let splits: [SnapshotSplit]

    public init(
        guid: Guid,
        date: String,
        description: String,
        currencyCode: String? = nil,
        splits: [SnapshotSplit]
    ) {
        self.guid = guid
        self.date = date
        self.description = description
        self.currencyCode = currencyCode
        self.splits = splits
    }
}

public struct BookSnapshot: Sendable, Hashable {
    public let bookGuid: Guid
    public let currencyCode: String?
    public let fraction: Int64?
    public let accounts: [SnapshotAccount]
    public let transactions: [SnapshotTransaction]

    public init(
        bookGuid: Guid,
        currencyCode: String? = nil,
        fraction: Int64? = nil,
        accounts: [SnapshotAccount],
        transactions: [SnapshotTransaction]
    ) {
        self.bookGuid = bookGuid
        self.currencyCode = currencyCode
        self.fraction = fraction
        self.accounts = accounts
        self.transactions = transactions
    }
}

/// Reads GnuCash's XML backend (plain or gzip). Element prefixes are part of
/// the GnuCash DTD (`gnc:`, `act:`, `trn:`, `split:`, `cmdty:`), so matching on
/// the local name keeps us independent of namespace-prefix handling.
public enum XMLBookReader {
    public static func read(at url: URL) throws -> BookSnapshot {
        let raw = try Data(contentsOf: url)
        let xml = raw.starts(with: [0x1f, 0x8b]) ? try Gzip.inflate(raw) : raw
        let parser = XMLParser(data: xml)
        let delegate = SnapshotDelegate()
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else {
            throw delegate.failure ?? BookFormatError.malformedXML
        }
        return try delegate.snapshot()
    }
}

private final class SnapshotDelegate: NSObject, XMLParserDelegate {
    var failure: BookFormatError?

    private var stack: [String] = []
    private var text = ""
    private var bookGuid: Guid?
    private var accounts: [SnapshotAccount] = []
    private var transactions: [SnapshotTransaction] = []
    private var account: AccountBuilder?
    private var transaction: TransactionBuilder?
    private var split: SplitBuilder?
    private var slotKey: String?

    private struct AccountBuilder {
        var guid: Guid?
        var name = ""
        var type = ""
        var parent: Guid?
        var commodity: String?
        var code = ""
        var description = ""
        var hidden = false
        var placeholder = false
    }

    private struct SplitBuilder {
        var account: Guid?
        var value: Money?
    }

    private struct TransactionBuilder {
        var guid: Guid?
        var date = ""
        var description = ""
        var currency: String?
        var splits: [SnapshotSplit] = []
    }

    func snapshot() throws -> BookSnapshot {
        guard let bookGuid, !accounts.isEmpty else {
            throw BookFormatError.malformedXML
        }
        let fraction = transactions
            .flatMap(\.splits)
            .first
            .map { $0.value.denom }
        return BookSnapshot(
            bookGuid: bookGuid,
            currencyCode: transactions.first?.currencyCode
                ?? accounts.compactMap(\.commodityCode).first,
            fraction: fraction,
            accounts: accounts,
            transactions: transactions
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let parent = stack.last ?? ""
        stack.append(local(elementName))
        text = ""
        switch (local(elementName), elementName) {
        case ("account", "gnc:account"):
            account = AccountBuilder()
            slotKey = nil
        case ("transaction", "gnc:transaction"):
            transaction = TransactionBuilder()
        case ("split", "trn:split") where transaction != nil:
            split = SplitBuilder()
        case ("account", _) where parent == "book":
            account = AccountBuilder()
            slotKey = nil
        case ("transaction", _) where parent == "book":
            transaction = TransactionBuilder()
        case ("split", _) where parent == "splits" && transaction != nil:
            split = SplitBuilder()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = local(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
        defer {
            stack.removeLast()
            text = ""
        }

        if name == "account", let builder = account {
            finishAccount(builder)
        } else if name == "transaction", let builder = transaction {
            finishTransaction(builder)
        } else if name == "split", let builder = split {
            finishSplit(builder)
        } else if split != nil {
            switch (name, parent) {
            case ("account", "split"):
                split?.account = Guid(value)
            case ("value", "split"):
                split?.value = rational(value)
            default:
                break
            }
        } else if transaction != nil {
            switch (name, parent) {
            case ("id", "transaction"):
                transaction?.guid = Guid(value)
            case ("date", "date-posted"):
                transaction?.date = String(value.prefix(10))
            case ("description", "transaction"):
                transaction?.description = value
            case ("id", "currency"):
                transaction?.currency = value
            default:
                break
            }
        } else if account != nil {
            switch (name, parent) {
            case ("name", "account"):
                account?.name = value
            case ("id", "account"):
                account?.guid = Guid(value)
            case ("type", "account"):
                account?.type = value
            case ("parent", "account"):
                account?.parent = Guid(value)
            case ("id", "commodity"):
                account?.commodity = value
            case ("code", "account"):
                account?.code = value
            case ("description", "account"):
                account?.description = value
            case ("key", "slot"):
                slotKey = value
            case ("value", "slot"):
                if slotKey == "placeholder" {
                    account?.placeholder = value == "true"
                } else if slotKey == "hidden" {
                    account?.hidden = value == "true"
                }
                slotKey = nil
            default:
                break
            }
        } else if name == "id", parent == "book", let guid = Guid(value) {
            bookGuid = guid
        }
    }

    private func finishAccount(_ builder: AccountBuilder) {
        if let guid = builder.guid {
            accounts.append(
                SnapshotAccount(
                    guid: guid,
                    name: builder.name,
                    type: builder.type,
                    parentGuid: builder.parent,
                    commodityCode: builder.commodity,
                    code: builder.code,
                    description: builder.description,
                    hidden: builder.hidden,
                    placeholder: builder.placeholder
                )
            )
        }
        account = nil
    }

    private func finishTransaction(_ builder: TransactionBuilder) {
        if let guid = builder.guid {
            transactions.append(
                SnapshotTransaction(
                    guid: guid,
                    date: builder.date,
                    description: builder.description,
                    currencyCode: builder.currency,
                    splits: builder.splits
                )
            )
        }
        transaction = nil
    }

    private func finishSplit(_ builder: SplitBuilder) {
        if let account = builder.account, let value = builder.value {
            transaction?.splits.append(
                SnapshotSplit(accountGuid: account, value: value)
            )
        }
        split = nil
    }

    private func local(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name))
    }

    private func rational(_ value: String) -> Money? {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let num = Int64(pieces[0]),
              let denom = Int64(pieces[1])
        else {
            return nil
        }
        return try? Money(num: num, denom: denom)
    }
}
