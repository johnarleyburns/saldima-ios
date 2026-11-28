// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var sheet: SheetTarget?
    @State private var showImporter = false
    @AppStorage(ThemeKeys.accent) private var accentRaw = AccentChoice.indigo.rawValue
    /// GnuCash remembers which branches are folded; so do we, per device.
    @AppStorage("saldima.collapsedAccounts") private var collapsedRaw = ""

    private enum SheetTarget: Identifiable {
        case newBook
        case account(Account?)
        case settings
        case register
        case reports
        case scheduled
        case budgets
        case prices
        case bills

        var id: String {
            switch self {
            case .newBook: "new-book"
            case .account(let account): account?.guid.rawValue ?? "new-account"
            case .settings: "settings"
            case .register: "register"
            case .reports: "reports"
            case .scheduled: "scheduled"
            case .budgets: "budgets"
            case .prices: "prices"
            case .bills: "bills"
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Accounts")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(session.books, id: \.absoluteString) { url in
                                Button {
                                    Task { try? await session.open(url: url) }
                                } label: {
                                    Label(
                                        url.lastPathComponent,
                                        systemImage: url == session.bookURL
                                            ? "checkmark.circle.fill"
                                            : "building.2"
                                    )
                                }
                            }
                            Divider()
                            Button {
                                sheet = .newBook
                            } label: {
                                Label("New book\u{2026}", systemImage: "plus.rectangle.on.folder")
                            }
                            Button {
                                showImporter = true
                            } label: {
                                Label("Import book\u{2026}", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Label(session.bookName, systemImage: "building.2")
                                .labelStyle(.titleAndIcon)
                        }
                        .accessibilityIdentifier("books.menu")
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if session.isOpen {
                                Button {
                                    sheet = .account(nil)
                                } label: {
                                    Label("Add account", systemImage: "plus")
                                }
                                .accessibilityIdentifier("accounts.add")
                                Button("Expand All") { collapsedRaw = "" }
                                Button("Collapse All") {
                                    collapsedRaw = branchGuids(session.accounts)
                                        .map(\.rawValue)
                                        .sorted()
                                        .joined(separator: ",")
                                }
                                Divider()
                                Button {
                                    sheet = .register
                                } label: {
                                    Label("Register", systemImage: "list.bullet.rectangle")
                                }
                                .accessibilityIdentifier("accounts.register")
                                Button {
                                    sheet = .reports
                                } label: {
                                    Label("Reports", systemImage: "chart.bar")
                                }
                                .accessibilityIdentifier("accounts.reports")
                                Button {
                                    sheet = .scheduled
                                } label: {
                                    Label("Scheduled", systemImage: "calendar.badge.clock")
                                }
                                .accessibilityIdentifier("accounts.scheduled")
                                Button {
                                    sheet = .budgets
                                } label: {
                                    Label("Budgets", systemImage: "tablecells")
                                }
                                .accessibilityIdentifier("accounts.budgets")
                                Button {
                                    sheet = .prices
                                } label: {
                                    Label("Prices", systemImage: "arrow.left.arrow.right")
                                }
                                .accessibilityIdentifier("accounts.prices")
                                Button {
                                    sheet = .bills
                                } label: {
                                    Label("Bills", systemImage: "truck.box")
                                }
                                .accessibilityIdentifier("accounts.bills")
                                Divider()
                            }
                            Button {
                                sheet = .settings
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                            .accessibilityIdentifier("accounts.settings")
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("accounts.view")
                    }
                }
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: [.data],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        Task { await session.importBook(from: url) }
                    }
                }
                .sheet(item: $sheet) { target in
                    switch target {
                    case .newBook:
                        NewBookSheet(session: session)
                    case .account(let account):
                        AccountEditor(
                            session: session,
                            editing: account,
                            accounts: session.accounts
                        )
                    case .settings:
                        SettingsView(session: session)
                    case .register:
                        RegisterView(session: session)
                    case .reports:
                        ReportsView(session: session)
                    case .scheduled:
                        ScheduledTransactionsView(session: session)
                    case .budgets:
                        BudgetsView(session: session)
                    case .prices:
                        PricesView(session: session)
                    case .bills:
                        BillsView(session: session)
                    }
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

    private var accent: AccentChoice {
        AccentChoice(rawValue: accentRaw) ?? .indigo
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
                Button("New book\u{2026}") { sheet = .newBook }
                    .buttonStyle(.glassProminent)
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
                    GlassEffectContainer(spacing: 12) {
                        HStack(spacing: 12) {
                            SummaryCard(
                                title: "Net assets",
                                value: session.formatted(session.netAssets),
                                tint: accent.color
                            )
                            SummaryCard(
                                title: "Profit",
                                value: session.formatted(session.profit),
                                tint: session.profit.num < 0 ? .red : .green
                            )
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

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
                                sheet = .account(row.account)
                            } label: {
                                AccountLabel(
                                    account: row.account,
                                    depth: row.depth,
                                    balance: session.totals[row.account.guid].map(session.formatted)
                                )
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

private struct SummaryCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            LinearGradient(
                colors: [tint, tint.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: tint.opacity(0.25), radius: 10, y: 4)
    }
}

private struct AccountLabel: View {
    let account: Account
    let depth: Int
    let balance: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: account.placeholder ? "folder" : "doc.text")
                .foregroundStyle(accountColor(account.accountType))
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(account.accountType == "ROOT" ? .headline : .body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let balance, account.accountType != "ROOT" {
                Text(balance)
                    .font(.callout.monospacedDigit())
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
    @State private var exportDocument: RegisterExportDocument?
    @State private var exportFilename = ""
    @State private var exportContentType = UTType.plainText
    @State private var exporting = false

    init(session: BookSession, editing: Account?, accounts: [Account]) {
        self.session = session
        self.editing = editing
        self.accounts = accounts
        _name = State(initialValue: editing?.name ?? "")
        let initialType = AccountType(rawValue: editing?.accountType ?? "") ?? .asset
        _type = State(initialValue: initialType)
        _parent = State(
            initialValue: editing?.parentGuid
                ?? Self.defaultParentGuid(for: initialType, in: accounts)
        )
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
                    .onChange(of: type) { _, newType in
                        guard editing == nil else { return }
                        parent = Self.defaultParentGuid(for: newType, in: accounts)
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
                        Button("Export QIF") { exportRegister(extension: "qif") }
                        Button("Export CSV") { exportRegister(extension: "csv") }
                    }
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
                        .buttonStyle(.glassProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .fileExporter(
                isPresented: $exporting,
                document: exportDocument,
                contentType: exportContentType,
                defaultFilename: exportFilename
            ) { _ in
                exportDocument = nil
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

    /// GnuCash's own type hierarchy: the top-level category a type always
    /// nests under on a real chart of accounts (e.g. a bank account is
    /// always under Assets, never left at the top level).
    private static func categoryRootType(for type: AccountType) -> AccountType {
        switch type {
        case .asset, .bank, .cash, .receivable: .asset
        case .liability, .credit, .payable: .liability
        case .income: .income
        case .expense: .expense
        case .equity: .equity
        }
    }

    /// The top-level account of the matching category, if the chart has
    /// one -- used to default a new account's parent instead of leaving it
    /// at "No parent" for types that are never really top level.
    private static func defaultParentGuid(for type: AccountType, in accounts: [Account]) -> Guid? {
        let category = categoryRootType(for: type)
        return rows(accounts)
            .first { $0.depth == 0 && AccountType(rawValue: $0.account.accountType) == category }?
            .account.guid
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

    private func exportRegister(extension fileExtension: String) {
        guard let editing else { return }
        let result = fileExtension == "qif"
            ? session.exportQif(accountGuid: editing.guid)
            : session.exportCsv(accountGuid: editing.guid)
        guard let result else { return }
        exportDocument = RegisterExportDocument(data: result.data)
        exportFilename = result.filename
        exportContentType = UTType(filenameExtension: fileExtension) ?? .plainText
        exporting = true
    }
}

/// Carries a finished QIF or CSV register export to the system document
/// picker -- the actual UTType written is whatever `.fileExporter` is
/// given at the call site, matching `XMLExportDocument`'s precedent.
private struct RegisterExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "qif") ?? .plainText, UTType(filenameExtension: "csv") ?? .commaSeparatedText]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    AccountsView(session: BookSession())
}


private struct NewBookSheet: View {
    let session: BookSession

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template: BookTemplate = BookTemplates.personal
    @State private var currency: BookCurrency = .usd

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Company name", text: $name)
                        .accessibilityIdentifier("newbook.name")
                    Picker("Template", selection: $template) {
                        ForEach(BookTemplates.all) { option in
                            Text(option.name).tag(option)
                        }
                    }
                    Picker("Currency", selection: $currency) {
                        Text("USD").tag(BookCurrency.usd)
                        Text("EUR").tag(BookCurrency.eur)
                        Text("GBP").tag(BookCurrency.gbp)
                    }
                } footer: {
                    Text(template.description)
                }
            }
            .navigationTitle("New book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let chosen = name
                        let chosenTemplate = template
                        let chosenCurrency = currency
                        Task {
                            await session.createBook(
                                named: chosen,
                                template: chosenTemplate,
                                currency: chosenCurrency
                            )
                            dismiss()
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
