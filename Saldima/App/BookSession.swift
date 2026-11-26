// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

import SaldimaCore

/// Owns the standalone books on this device. Like GnuCash desktop, there is no
/// single "root" book: each `.gnucash` file is a company, and the file in
/// Documents is the source of truth. No network call is ever made.
@MainActor
@Observable
final class BookSession {
    private(set) var store: BookStore?
    private(set) var bookURL: URL?
    private(set) var books: [URL] = []
    private(set) var accounts: [Account] = []
    private(set) var transactions: [StoredTransaction] = []
    private(set) var balances: [Guid: Money] = [:]
    private(set) var totals: [Guid: Money] = [:]
    private(set) var netAssets: Money = .zero
    private(set) var profit: Money = .zero
    private(set) var fraction: Int64 = 100
    private(set) var isLoading = false
    private(set) var customers: [Customer] = []
    private(set) var invoices: [Invoice] = []
    var lastError: String?

    private let ids: any IDGenerator

    init(ids: any IDGenerator = SystemIDGenerator()) {
        self.ids = ids
    }

    var isOpen: Bool { store != nil }
    var bookName: String { bookURL?.lastPathComponent ?? "No book" }

    func refreshLibrary() {
        do {
            let directory = try Self.documentsDirectory()
            books = try FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "gnucash" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Opens the first book, or creates a personal one on first run.
    func openDefaultBook() async {
        refreshLibrary()
        guard store == nil else { return }
        do {
            if let first = books.first {
                try await open(url: first)
                return
            }
            let url = try Self.documentsDirectory().appendingPathComponent("Saldima.gnucash")
            try BookWriter.create(at: url, template: BookTemplates.personal, ids: ids)
            try await open(url: url)
        } catch {
            lastError = Self.message(for: error)
        }
    }

    func open(url: URL) async throws {
        isLoading = true
        defer { isLoading = false }
        await store?.close()
        let opened = try BookStore(url: url)
        store = opened
        bookURL = url
        refreshLibrary()
        try await refresh()
    }

    /// Creates a company file from a template. Names are unique on disk.
    func createBook(named name: String, template: BookTemplate, currency: BookCurrency) async {
        do {
            let directory = try Self.documentsDirectory()
            let base = Self.fileName(from: name)
            var url = directory.appendingPathComponent("\(base).gnucash")
            var number = 1
            while FileManager.default.fileExists(atPath: url.path) {
                number += 1
                url = directory.appendingPathComponent("\(base) \(number).gnucash")
            }
            try BookWriter.create(at: url, template: template, currency: currency, ids: ids)
            try await open(url: url)
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Imports an existing `.gnucash` (XML or SQLite) into this device's
    /// library. XML is the canonical format, so an XML source is copied in
    /// as-is; a desktop SQLite-dialect source is read through
    /// `SQLiteBookReader` and materialized as XML, so either way it opens
    /// and edits exactly like a book created on-device.
    func importBook(from source: URL) async {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let directory = try Self.documentsDirectory()
            var destination = directory.appendingPathComponent(source.lastPathComponent)
            var number = 1
            while FileManager.default.fileExists(atPath: destination.path) {
                number += 1
                let stem = source.deletingPathExtension().lastPathComponent
                destination = directory.appendingPathComponent("\(stem) \(number).gnucash")
            }
            switch try BookFile.detect(at: source) {
            case .xml:
                // Already the canonical format: just copy it in.
                try FileManager.default.copyItem(at: source, to: destination)
            case .sqlite:
                // Desktop SQLite dialect is an import boundary only.
                let snapshot = try SQLiteBookReader.read(at: source)
                try BookImporter.materialize(snapshot, at: destination, ids: ids)
            }
            try await open(url: destination)
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Builds a gzip GnuCash XML export of the open book for the share sheet.
    /// The live working file already is gzip GnuCash XML, so exporting is
    /// just sharing its current bytes -- lossless, unlike rebuilding a
    /// narrow `BookSnapshot` and re-serializing from scratch.
    func exportXML() async -> (data: Data, filename: String)? {
        guard let bookURL else { return nil }
        do {
            let data = try Data(contentsOf: bookURL)
            let stem = bookURL.deletingPathExtension().lastPathComponent
            return (data, "\(stem)-xml.gnucash")
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    @discardableResult
    func save(_ draft: AccountDraft, editing account: Account?) async -> Bool {
        guard let store else { return false }
        do {
            if let account {
                try await store.updateAccount(account.guid, with: draft)
            } else {
                try await store.createAccount(draft, ids: ids)
            }
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    func delete(_ account: Account) async -> Bool {
        guard let store else { return false }
        do {
            try await store.deleteAccount(account.guid)
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    func formatted(_ value: Money) -> String {
        (try? value.formatted(fraction: fraction)) ?? "—"
    }

    /// Posts a transaction with two or more splits, each a signed amount
    /// (debit positive, credit negative); the splits used must sum to zero.
    /// Two legs cover a simple payment; more support entries with a tax or
    /// fee line (expense + input tax + payable, say).
    @discardableResult
    func post(
        date: Date,
        description: String,
        splits: [(account: Guid, amount: Money)]
    ) async -> Bool {
        guard let store else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        do {
            try await store.post(
                date: formatter.string(from: date),
                description: description,
                splits: splits.map { StoredSplit(accountGuid: $0.account, value: $0.amount) },
                ids: ids
            )
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    /// The same action as checking a row off in GnuCash's Reconcile window.
    @discardableResult
    func setSplitReconcileState(
        transactionGuid: Guid,
        splitGuid: Guid,
        state: String,
        reconcileDate: Date?
    ) async -> Bool {
        guard let store else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        do {
            try await store.setSplitReconcileState(
                transactionGuid: transactionGuid,
                splitGuid: splitGuid,
                state: state,
                reconcileDate: reconcileDate.map { "\(formatter.string(from: $0)) 00:00:00 +0000" }
            )
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    // MARK: - Receipts

    /// A receipt image's path is stored relative to the book's own
    /// directory (`setTransactionDocLink`), so it survives the sandbox
    /// container moving between launches; this is where that path resolves.
    private var receiptsDirectory: URL? {
        bookURL?.deletingLastPathComponent().appendingPathComponent("receipts")
    }

    /// Writes a captured receipt image and returns the relative path to
    /// hand to `post(receiptPath:)` or `attachReceipt`.
    private func saveReceiptImage(_ data: Data) throws -> String {
        guard let directory = receiptsDirectory else { throw BookStoreError.cannotOpen }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).jpg"
        try data.write(to: directory.appendingPathComponent(name))
        return "receipts/\(name)"
    }

    /// Loads a transaction's attached receipt image bytes, if any.
    func receiptImageData(_ docLink: String) -> Data? {
        guard let directory = receiptsDirectory else { return nil }
        let fileName = (docLink as NSString).lastPathComponent
        return try? Data(contentsOf: directory.appendingPathComponent(fileName))
    }

    /// Captures a receipt as a new expense: a simple two-leg posting
    /// (debit the expense account, credit the payment account) with the
    /// receipt image attached via `post(receiptPath:)` -- "create an
    /// expense on the receipt screen."
    @discardableResult
    func postReceiptExpense(
        date: Date,
        description: String,
        amount: Money,
        expenseAccount: Guid,
        paymentAccount: Guid,
        imageData: Data
    ) async -> Bool {
        guard let store else { return false }
        do {
            let receiptPath = try saveReceiptImage(imageData)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            try await store.post(
                date: formatter.string(from: date),
                description: description,
                splits: [
                    StoredSplit(accountGuid: expenseAccount, value: amount),
                    StoredSplit(accountGuid: paymentAccount, value: amount.negated()),
                ],
                receiptPath: receiptPath,
                ids: ids
            )
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    func accountOptions() -> [(guid: Guid, name: String, depth: Int)] {
        func walk(_ nodes: [Account], depth: Int, into rows: inout [(Guid, String, Int)]) {
            for node in nodes where node.accountType != "ROOT" && !node.placeholder {
                rows.append((node.guid, node.name, depth))
                walk(node.children, depth: depth + 1, into: &rows)
            }
        }
        var rows: [(Guid, String, Int)] = []
        walk(accounts, depth: 0, into: &rows)
        return rows
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Customers

    @discardableResult
    func saveCustomer(_ draft: CustomerDraft, editing customer: Customer?) async -> Bool {
        guard let store else { return false }
        do {
            if let customer {
                try await store.updateCustomer(customer.guid, with: draft)
            } else {
                try await store.createCustomer(draft, ids: ids)
            }
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    func delete(_ customer: Customer) async -> Bool {
        guard let store else { return false }
        do {
            try await store.deleteCustomer(customer.guid)
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    // MARK: - Invoices

    @discardableResult
    func createInvoiceDraft(
        customer: Customer,
        invoiceNumber: String,
        dateOpened: Date
    ) async -> Guid? {
        guard let store else { return nil }
        do {
            let guid = try await store.createInvoiceDraft(
                customerGuid: customer.guid,
                invoiceNumber: invoiceNumber,
                dateOpened: Self.isoDate(dateOpened),
                ids: ids
            )
            try await refresh()
            return guid
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    @discardableResult
    func addInvoiceLine(
        to invoice: Invoice,
        date: Date,
        description: String,
        quantity: Money,
        unitPrice: Money,
        incomeAccount: Guid
    ) async -> Bool {
        guard let store else { return false }
        do {
            try await store.addInvoiceLine(
                invoice.guid,
                date: Self.isoDate(date),
                description: description,
                quantity: quantity,
                unitPrice: unitPrice,
                incomeAccountGuid: incomeAccount,
                ids: ids
            )
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    func deleteInvoiceLine(_ line: InvoiceLine, from invoice: Invoice) async -> Bool {
        guard let store else { return false }
        do {
            try await store.deleteInvoiceLine(line.guid, invoiceGuid: invoice.guid)
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    func deleteInvoiceDraft(_ invoice: Invoice) async -> Bool {
        guard let store else { return false }
        do {
            try await store.deleteInvoiceDraft(invoice.guid)
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    /// Posts a draft invoice: debits the chosen receivable account for the
    /// total and credits each line's income account, like desktop GnuCash's
    /// "Post Invoice". One-way -- a posted invoice is permanent ledger
    /// history and can no longer be edited or deleted.
    @discardableResult
    func postInvoice(_ invoice: Invoice, receivableAccount: Guid, postedDate: Date) async -> Bool {
        guard let store else { return false }
        do {
            try await store.postInvoice(
                invoice.guid,
                receivableAccountGuid: receivableAccount,
                postedDate: Self.isoDate(postedDate),
                ids: ids
            )
            try await refresh()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func refresh() async throws {
        guard let store else { return }
        accounts = try await store.accounts()
        balances = try await store.balances()
        transactions = try await store.transactions()
        customers = try await store.customers()
        invoices = try await store.invoices()
        totals = try AccountRollup.totals(accounts, balances: balances)
        if let currency = try await store.bookCurrency() {
            fraction = currency.fraction
        }
        var assets = Money.zero
        var liabilities = Money.zero
        var income = Money.zero
        var expense = Money.zero

        func walk(_ nodes: [Account]) throws {
            for node in nodes {
                let balance = balances[node.guid] ?? .zero
                switch node.accountType {
                case "ASSET", "BANK", "CASH", "RECEIVABLE":
                    assets = try Money.add(assets, balance)
                case "LIABILITY", "CREDIT", "PAYABLE":
                    liabilities = try Money.add(liabilities, balance)
                case "INCOME":
                    income = try Money.add(income, balance)
                case "EXPENSE":
                    expense = try Money.add(expense, balance)
                default:
                    break
                }
                try walk(node.children)
            }
        }
        try walk(accounts)
        netAssets = try Money.subtract(assets, liabilities)
        profit = try Money.add(income, expense).negated()
    }

    private static func fileName(from name: String) -> String {
        let cleaned = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Saldima" : String(cleaned.prefix(80))
    }

    private static func documentsDirectory() throws -> URL {
        guard let url = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw BookWriterError.cannotCreate
        }
        return url
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AccountEditError.invalidName:
            return "Enter a name of 200 characters or fewer."
        case AccountEditError.moveIntoSubtree:
            return "Choose a parent that is not this account or one of its children."
        case AccountEditError.accountHasChildren:
            return "Move or delete this account's children first."
        case AccountEditError.accountInUse:
            return "This account has postings and cannot be deleted."
        case AccountEditError.protectedAccount:
            return "The book root account cannot be changed."
        case AccountEditError.unknownAccount:
            return "That account is no longer in the book."
        case BookWriterError.alreadyExists:
            return "A book with that name is already on this device."
        case CustomerEditError.invalidName:
            return "Enter a name of 200 characters or fewer."
        case CustomerEditError.customerInUse:
            return "This client has invoices and cannot be deleted."
        case CustomerEditError.unknownCustomer:
            return "That client is no longer in the book."
        case InvoiceEditError.noLines:
            return "Add at least one line before posting."
        case InvoiceEditError.alreadyPosted:
            return "A posted invoice cannot be edited or deleted."
        case InvoiceEditError.unknownAccount:
            return "Choose an account that still exists."
        case InvoiceEditError.unknownCustomer, InvoiceEditError.unknownInvoice:
            return "That record is no longer in the book."
        case JournalError.invalidDate:
            return "Enter a valid date."
        case JournalError.missingReconcileDate:
            return "A reconcile date is required to mark a split reconciled."
        case JournalError.unknownSplit, JournalError.unknownTransaction:
            return "That split is no longer in the book."
        default:
            return error.localizedDescription
        }
    }
}
