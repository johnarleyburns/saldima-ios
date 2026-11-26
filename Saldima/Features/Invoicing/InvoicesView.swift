// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

/// Invoices, the GnuCash `GncInvoice` business object: bill a client, add
/// lines, then post -- the one-way action that creates the real receivable/
/// income transaction behind it, exactly like desktop GnuCash's own
/// "Post Invoice". A draft can be edited freely; a posted invoice cannot.
struct InvoicesView: View {
    let session: BookSession
    @State private var showingNewInvoice = false
    @State private var showingClients = false

    var body: some View {
        NavigationStack {
            Group {
                if session.invoices.isEmpty {
                    ContentUnavailableView {
                        Label("No invoices", systemImage: "doc.text")
                    } description: {
                        Text("Add a client, then create an invoice to bill them.")
                    } actions: {
                        Button("New invoice") { showingNewInvoice = true }
                            .buttonStyle(.glassProminent)
                            .disabled(!session.isOpen || session.customers.isEmpty)
                    }
                } else {
                    List {
                        ForEach(session.invoices) { invoice in
                            NavigationLink {
                                InvoiceDetailView(session: session, invoiceGuid: invoice.guid)
                            } label: {
                                InvoiceRow(session: session, invoice: invoice)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Invoices")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingClients = true
                    } label: {
                        Label("Clients", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("invoices.clients")
                }
                if session.isOpen {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingNewInvoice = true
                        } label: {
                            Label("New invoice", systemImage: "plus")
                        }
                        .accessibilityIdentifier("invoices.add")
                        .disabled(session.customers.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingNewInvoice) {
                NewInvoiceSheet(session: session)
            }
            .sheet(isPresented: $showingClients) {
                CustomersView(session: session)
            }
        }
    }
}

private struct InvoiceRow: View {
    let session: BookSession
    let invoice: Invoice

    private var customerName: String {
        session.customers.first { $0.guid == invoice.customerGuid }?.name ?? "Unknown client"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(invoice.invoiceNumber.isEmpty ? "Invoice" : invoice.invoiceNumber)
                    .font(.headline)
                Spacer()
                Text(invoice.isPosted ? "Posted" : "Draft")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(invoice.isPosted ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .clipShape(Capsule())
            }
            Text(customerName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(session.formatted(invoice.total))
                .font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 4)
    }
}

private struct NewInvoiceSheet: View {
    let session: BookSession
    @Environment(\.dismiss) private var dismiss
    @State private var customerGuid: Guid?
    @State private var invoiceNumber = ""
    @State private var dateOpened = Date()
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Client", selection: $customerGuid) {
                        Text("Choose").tag(Guid?.none)
                        ForEach(session.customers) { customer in
                            Text(customer.name).tag(Guid?.some(customer.guid))
                        }
                    }
                    TextField("Invoice number", text: $invoiceNumber)
                    DatePicker("Date opened", selection: $dateOpened, displayedComponents: .date)
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .buttonStyle(.glassProminent)
                        .disabled(customerGuid == nil || invoiceNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        guard let customerGuid, let customer = session.customers.first(where: { $0.guid == customerGuid }) else {
            localError = "Choose a client."
            return
        }
        Task {
            if await session.createInvoiceDraft(
                customer: customer,
                invoiceNumber: invoiceNumber.trimmingCharacters(in: .whitespaces),
                dateOpened: dateOpened
            ) != nil {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

private struct InvoiceDetailView: View {
    let session: BookSession
    let invoiceGuid: Guid

    @State private var showingNewLine = false
    @State private var showingPost = false

    private var invoice: Invoice? {
        session.invoices.first { $0.guid == invoiceGuid }
    }

    private var customerName: String {
        guard let invoice else { return "" }
        return session.customers.first { $0.guid == invoice.customerGuid }?.name ?? "Unknown client"
    }

    var body: some View {
        Group {
            if let invoice {
                List {
                    Section {
                        LabeledContent("Client", value: customerName)
                        LabeledContent("Opened", value: String(invoice.dateOpened.prefix(10)))
                        if let posted = invoice.datePosted {
                            LabeledContent("Posted", value: String(posted.prefix(10)))
                        }
                        if !invoice.notes.isEmpty {
                            LabeledContent("Notes", value: invoice.notes)
                        }
                    }
                    Section("Lines") {
                        if invoice.lines.isEmpty {
                            Text("No lines yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(invoice.lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.description)
                                HStack {
                                    Text(quantityAndPrice(line))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(session.formatted(line.amount))
                                        .font(.subheadline.monospacedDigit())
                                }
                            }
                        }
                        .onDelete { offsets in
                            delete(offsets, from: invoice)
                        }
                        .deleteDisabled(invoice.isPosted)
                        HStack {
                            Text("Total")
                                .font(.headline)
                            Spacer()
                            Text(session.formatted(invoice.total))
                                .font(.headline.monospacedDigit())
                        }
                    }
                    if !invoice.isPosted {
                        Section {
                            Button("Add line") { showingNewLine = true }
                            Button("Post invoice\u{2026}") { showingPost = true }
                                .disabled(invoice.lines.isEmpty)
                        }
                    } else {
                        Section {
                            ShareLink(item: shareText(invoice)) {
                                Label("Share invoice", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Invoice not found", systemImage: "doc.text")
            }
        }
        .navigationTitle(invoice?.invoiceNumber ?? "Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingNewLine) {
            if let invoice {
                NewInvoiceLineSheet(session: session, invoice: invoice)
            }
        }
        .sheet(isPresented: $showingPost) {
            if let invoice {
                PostInvoiceSheet(session: session, invoice: invoice)
            }
        }
    }

    private func quantityAndPrice(_ line: InvoiceLine) -> String {
        "\(session.formatted(line.quantity)) \u{00d7} \(session.formatted(line.unitPrice))"
    }

    private func delete(_ offsets: IndexSet, from invoice: Invoice) {
        for index in offsets {
            let line = invoice.lines[index]
            Task { await session.deleteInvoiceLine(line, from: invoice) }
        }
    }

    private func shareText(_ invoice: Invoice) -> String {
        var lines = [
            "Invoice \(invoice.invoiceNumber)",
            "Client: \(customerName)",
            "Date: \(String(invoice.dateOpened.prefix(10)))",
            "",
        ]
        for line in invoice.lines {
            lines.append("\(line.description) — \(quantityAndPrice(line)) = \(session.formatted(line.amount))")
        }
        lines.append("")
        lines.append("Total: \(session.formatted(invoice.total))")
        return lines.joined(separator: "\n")
    }
}

private struct NewInvoiceLineSheet: View {
    let session: BookSession
    let invoice: Invoice

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var description = ""
    @State private var quantity = "1"
    @State private var unitPrice = ""
    @State private var incomeAccount: Guid?
    @State private var localError: String?

    private var incomeAccountOptions: [(guid: Guid, name: String, depth: Int)] {
        func walk(_ nodes: [Account], depth: Int, into rows: inout [(Guid, String, Int)]) {
            for node in nodes {
                if node.accountType == "INCOME" && !node.placeholder {
                    rows.append((node.guid, node.name, depth))
                }
                walk(node.children, depth: depth + 1, into: &rows)
            }
        }
        var rows: [(Guid, String, Int)] = []
        walk(session.accounts, depth: 0, into: &rows)
        return rows
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Description", text: $description)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Quantity", text: $quantity)
                        .keyboardType(.decimalPad)
                    TextField("Unit price", text: $unitPrice)
                        .keyboardType(.decimalPad)
                    Picker("Income account", selection: $incomeAccount) {
                        Text("Choose").tag(Guid?.none)
                        ForEach(incomeAccountOptions, id: \.guid) { option in
                            Text(String(repeating: "  ", count: option.depth) + option.name)
                                .tag(Guid?.some(option.guid))
                        }
                    }
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Add line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private func add() {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            localError = "Enter a description."
            return
        }
        guard let incomeAccount else {
            localError = "Choose an income account."
            return
        }
        guard let quantityValue = try? Money.parseHalfUp(quantity, fraction: 10000), quantityValue != .zero else {
            localError = "Enter a quantity like 1 or 2.5."
            return
        }
        guard let priceValue = try? Money.parseHalfUp(unitPrice, fraction: 100), priceValue != .zero else {
            localError = "Enter a unit price like 250.00."
            return
        }
        Task {
            if await session.addInvoiceLine(
                to: invoice,
                date: date,
                description: trimmedDescription,
                quantity: quantityValue,
                unitPrice: priceValue,
                incomeAccount: incomeAccount
            ) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

private struct PostInvoiceSheet: View {
    let session: BookSession
    let invoice: Invoice

    @Environment(\.dismiss) private var dismiss
    @State private var receivableAccount: Guid?
    @State private var postedDate = Date()
    @State private var localError: String?

    private var receivableAccountOptions: [(guid: Guid, name: String, depth: Int)] {
        let receivableTypes: Set<String> = ["ASSET", "BANK", "CASH", "RECEIVABLE"]
        func walk(_ nodes: [Account], depth: Int, into rows: inout [(Guid, String, Int)]) {
            for node in nodes {
                if receivableTypes.contains(node.accountType) && !node.placeholder {
                    rows.append((node.guid, node.name, depth))
                }
                walk(node.children, depth: depth + 1, into: &rows)
            }
        }
        var rows: [(Guid, String, Int)] = []
        walk(session.accounts, depth: 0, into: &rows)
        return rows
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Posting debits the account below for \(session.formatted(invoice.total)) and credits each line's income account. This cannot be undone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Deposit to", selection: $receivableAccount) {
                        Text("Choose").tag(Guid?.none)
                        ForEach(receivableAccountOptions, id: \.guid) { option in
                            Text(String(repeating: "  ", count: option.depth) + option.name)
                                .tag(Guid?.some(option.guid))
                        }
                    }
                    DatePicker("Posted date", selection: $postedDate, displayedComponents: .date)
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Post invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { post() }
                        .buttonStyle(.glassProminent)
                        .disabled(receivableAccount == nil)
                }
            }
        }
    }

    private func post() {
        guard let receivableAccount else {
            localError = "Choose an account."
            return
        }
        Task {
            if await session.postInvoice(invoice, receivableAccount: receivableAccount, postedDate: postedDate) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

#Preview {
    InvoicesView(session: BookSession())
}
