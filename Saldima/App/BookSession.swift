// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

import SaldimaCore

/// Owns the standalone book on this device. There is no server account: the
/// file in Documents is the source of truth, and the app opens or creates it
/// without any network call.
@MainActor
@Observable
final class BookSession {
    private(set) var store: BookStore?
    private(set) var bookURL: URL?
    private(set) var accounts: [Account] = []
    private(set) var isLoading = false
    var lastError: String?

    private let ids: any IDGenerator

    init(ids: any IDGenerator = SystemIDGenerator()) {
        self.ids = ids
    }

    var isOpen: Bool { store != nil }
    var bookName: String { bookURL?.lastPathComponent ?? "No book" }

    /// Opens Documents/Saldima.gnucash, creating a personal book on first run.
    func openDefaultBook() async {
        guard store == nil else { return }
        do {
            let url = try Self.defaultURL()
            if !FileManager.default.fileExists(atPath: url.path) {
                try BookWriter.create(
                    at: url,
                    template: BookTemplates.personal,
                    ids: ids
                )
            }
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
        accounts = try await opened.accounts()
    }

    /// Creates a fresh book from a template next to the current one and opens it.
    func createBook(from template: BookTemplate) async {
        do {
            let directory = try Self.documentsDirectory()
            var number = 1
            var url = directory.appendingPathComponent("Saldima \(template.name).gnucash")
            while FileManager.default.fileExists(atPath: url.path) {
                number += 1
                url = directory.appendingPathComponent("Saldima \(template.name) \(number).gnucash")
            }
            try BookWriter.create(at: url, template: template, ids: ids)
            try await open(url: url)
        } catch {
            lastError = Self.message(for: error)
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
            accounts = try await store.accounts()
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
            accounts = try await store.accounts()
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    func clearError() {
        lastError = nil
    }

    private static func defaultURL() throws -> URL {
        try documentsDirectory().appendingPathComponent("Saldima.gnucash")
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
