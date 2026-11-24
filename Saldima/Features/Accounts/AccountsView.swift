// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

private struct AccountRow: Identifiable {
    let account: Account
    let depth: Int
    var id: Guid { account.guid }
}

private func rows(
    _ accounts: [Account],
    depth: Int = 0,
    collapsed: Set<Guid> = []
) -> [AccountRow] {
    accounts.flatMap { account in
        [AccountRow(account: account, depth: depth)]
            + (collapsed.contains(account.guid)
                ? []
                : rows(account.children, depth: depth + 1, collapsed: collapsed))
    }
}

private func branchGuids(_ accounts: [Account]) -> Set<Guid> {
    var found: Set<Guid> = []
    func walk(_ nodes: [Account]) {
        for node in nodes where !node.children.isEmpty {
            found.insert(node.guid)
            walk(node.children)
        }
    }
    walk(accounts)
    return found
}

private func descendants(of guid: Guid, in accounts: [Account]) -> Set<Guid> {
    func walk(_ nodes: [Account], into found: inout Set<Guid>) {
        for node in nodes {
            found.insert(node.guid)
            walk(node.children, into: &found)
        }
    }
    func search(_ nodes: [Account]) -> Account? {
        for node in nodes {
            if node.guid == guid { return node }
            if let match = search(node.children) { return match }
        }
        return nil
    }
    guard let match = search(accounts) else { return [] }
    var found: Set<Guid> = [guid]
    walk(match.children, into: &found)
    return found
}

struct AccountsView: View {
    let session: BookSession
    @State private var editor: EditorTarget?
    @State private var template: BookTemplate = BookTemplates.personal
    /// GnuCash remembers which branches are folded; so do we, per device.
    @AppStorage("saldima.collapsedAccounts") private var collapsedRaw = ""

    private struct EditorTarget: Identifiable {
        let account: Account?
        var id: String { account?.guid.rawValue ?? "new" }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Accounts")
                .toolbar {
                    if session.isOpen {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("Expand All") { collapsedRaw = "" }
                                Button("Collapse All") {
                                    collapsedRaw = branchGuids(session.accounts)
                                        .map(\.rawValue)
                                        .sorted()
                                        .joined(separator: ",")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityIdentifier("accounts.view")
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                editor = EditorTarget(account: nil)
                            } label: {
                                Label("Add account", systemImage: "plus")
                            }
                            .accessibilityIdentifier("accounts.add")
                        }
                    }
                }
                .sheet(item: $editor) { target in
                    AccountEditor(
                        session: session,
                        editing: target.account,
                        accounts: session.accounts
                    )
                }
                .alert(
                    "Saldima",
                    isPresented: Binding(
                        get: { session.lastError != nil },
                        set: { if !$0 { session.clearError() } }
                    )
                ) {
                    Button("OK", role: .cancel) { session.clearError() }
                } message: {
                    Text(session.lastError ?? "")
                }
        }
    }

    private var collapsed: Set<Guid> {
        Set(
            collapsedRaw
                .split(separator: ",")
                .compactMap { Guid(String($0)) }
        )
    }

    private func toggle(_ guid: Guid) {
        var next = collapsed
        if next.contains(guid) {
            next.remove(guid)
        } else {
            next.insert(guid)
        }
        collapsedRaw = next.map(\.rawValue).sorted().joined(separator: ",")
    }

    @ViewBuilder
    private var content: some View {
        if !session.isOpen {
            ContentUnavailableView {
                Label("No book yet", systemImage: "building.columns")
            } description: {
                Text("Create a book to start. It lives on this device and works with no account or network.")
            } actions: {
                Picker("Template", selection: $template) {
                    ForEach(BookTemplates.all) { option in
                        Text(option.name).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Button("Create book") {
                    Task { await session.createBook(from: template) }
                }
                .buttonStyle(.borderedProminent)
            }
        } else if session.accounts.isEmpty {
            ContentUnavailableView(
                "No accounts",
                systemImage: "list.bullet.indent",
                description: Text("Add an account to start the chart.")
            )
        } else {
            List {
                Section {
                    ForEach(rows(session.accounts, collapsed: collapsed)) { row in
                        HStack(spacing: 4) {
                            if row.account.children.isEmpty {
                                Color.clear.frame(width: 28, height: 1)
                            } else {
                                Button {
                                    toggle(row.account.guid)
                                } label: {
                                    Image(
                                        systemName: collapsed.contains(row.account.guid)
                                            ? "chevron.right"
                                            : "chevron.down"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 32)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    collapsed.contains(row.account.guid)
                                        ? "Expand \(row.account.name)"
                                        : "Collapse \(row.account.name)"
                                )
                            }
                            Button {
                                editor = EditorTarget(account: row.account)
                            } label: {
                                AccountLabel(account: row.account, depth: row.depth)
                            }
                            .buttonStyle(.plain)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if row.account.accountType != "ROOT" {
                                Button(role: .destructive) {
                                    Task { await session.delete(row.account) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } footer: {
                    Text(session.bookName)
                }
            }
        }
    }
}

private struct AccountLabel: View {
    let account: Account
    let depth: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: account.placeholder ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(account.accountType == "ROOT" ? .headline : .body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [account.accountType.capitalized]
        if account.hidden { parts.append("hidden") }
        if account.placeholder { parts.append("placeholder") }
        if !account.code.isEmpty { parts.append(account.code) }
        return parts.joined(separator: " · ")
    }
}

private struct AccountEditor: View {
    let session: BookSession
    let editing: Account?
    let accounts: [Account]

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var type: AccountType
    @State private var parent: Guid?
    @State private var code: String
    @State private var details: String
    @State private var hidden: Bool
    @State private var placeholder: Bool
    @State private var confirmingDelete = false

    init(session: BookSession, editing: Account?, accounts: [Account]) {
        self.session = session
        self.editing = editing
        self.accounts = accounts
        _name = State(initialValue: editing?.name ?? "")
        _type = State(initialValue: AccountType(rawValue: editing?.accountType ?? "") ?? .asset)
        _parent = State(initialValue: editing?.parentGuid)
        _code = State(initialValue: editing?.code ?? "")
        _details = State(initialValue: editing?.description ?? "")
        _hidden = State(initialValue: editing?.hidden ?? false)
        _placeholder = State(initialValue: editing?.placeholder ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("account.name")
                    Picker("Type", selection: $type) {
                        ForEach(AccountType.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Picker("Parent", selection: $parent) {
                        Text("No parent (top level)").tag(Guid?.none)
                        ForEach(parentOptions, id: \.guid) { option in
                            Text(String(repeating: "  ", count: option.depth) + option.name)
                                .tag(Guid?.some(option.guid))
                        }
                    }
                }
                Section {
                    TextField("Code", text: $code)
                    TextField("Description", text: $details, axis: .vertical)
                }
                Section {
                    Toggle("Hidden", isOn: $hidden)
                    Toggle("Placeholder", isOn: $placeholder)
                }
                if editing != nil {
                    Section {
                        Button("Delete account", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle(editing == nil ? "New account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog(
                "Delete this account?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let editing else { return }
                    Task {
                        if await session.delete(editing) { dismiss() }
                    }
                }
            } message: {
                Text("Accounts with children or postings cannot be deleted.")
            }
        }
    }

    private var parentOptions: [(guid: Guid, name: String, depth: Int)] {
        let excluded = editing.map { descendants(of: $0.guid, in: accounts) } ?? []
        return rows(accounts)
            .filter { !excluded.contains($0.account.guid) }
            .filter { $0.account.accountType != "ROOT" }
            .map { ($0.account.guid, $0.account.name, max(0, $0.depth - 1)) }
    }

    private func save() {
        let draft = AccountDraft(
            name: name,
            type: type,
            parentGuid: parent,
            code: code,
            description: details,
            hidden: hidden,
            placeholder: placeholder
        )
        Task {
            if await session.save(draft, editing: editing) {
                dismiss()
            }
        }
    }
}

#Preview {
    AccountsView(session: BookSession())
}
