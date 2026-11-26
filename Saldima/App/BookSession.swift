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
    /// library. An XML book is materialized as a fresh SQLite working copy
    /// (SQLite is still the live store today; the XML import boundary is the
    /// same shape the eventual XML-canonical migration will use), so it opens
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
            case .sqlite:
                try FileManager.default.copyItem(at: source, to: destination)
            case .xml:
                let snapshot = try XMLBookReader.read(at: source)
                try BookImporter.materialize(snapshot, at: destination, ids: ids)
            }
            try await open(url: destination)
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Builds a gzip GnuCash XML export of the open book for the share sheet.
    func exportXML() async -> (data: Data, filename: String)? {
        guard let store, let bookURL else { return nil }
        do {
            let snapshot = try await store.exportSnapshot()
            let data = try XMLBookWriter.data(snapshot, ids: ids)
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

    private func refresh() async throws {
        guard let store else { return }
        accounts = try await store.accounts()
        balances = try await store.balances()
        transactions = try await store.transactions()
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
        default:
            return error.localizedDescription
        }
    }
}
