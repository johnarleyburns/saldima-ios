// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

/// Bills, GnuCash's vendor-owned `GncInvoice` business object: record what
/// a vendor billed, add lines, then post -- the one-way action that
/// creates the real payable/expense transaction behind it, exactly like
/// desktop GnuCash's own "Post Bill". A draft can be edited freely; a
/// posted bill cannot.
struct BillsView: View {
    let session: BookSession
    @State private var showingNewBill = false
    @State private var showingVendors = false

    var body: some View {
        NavigationStack {
            Group {
                if session.bills.isEmpty {
                    ContentUnavailableView {
                        Label("No bills", systemImage: "truck.box")
                    } description: {
                        Text("Add a vendor, then create a bill to track what you owe them.")
                    } actions: {
                        Button("New bill") { showingNewBill = true }
                            .buttonStyle(.glassProminent)
                            .disabled(!session.isOpen || session.vendors.isEmpty)
                    }
                } else {
                    List {
                        ForEach(session.bills) { bill in
                            NavigationLink {
                                BillDetailView(session: session, billGuid: bill.guid)
                            } label: {
                                BillRow(session: session, bill: bill)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bills")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingVendors = true
                    } label: {
                        Label("Vendors", systemImage: "truck.box")
                    }
                    .accessibilityIdentifier("bills.vendors")
                }
                if session.isOpen {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingNewBill = true
                        } label: {
                            Label("New bill", systemImage: "plus")
                        }
                        .accessibilityIdentifier("bills.add")
                        .disabled(session.vendors.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingNewBill) {
                NewBillSheet(session: session)
            }
            .sheet(isPresented: $showingVendors) {
                VendorsView(session: session)
            }
        }
    }
}

private struct BillRow: View {
    let session: BookSession
    let bill: Bill

    private var vendorName: String {
        session.vendors.first { $0.guid == bill.vendorGuid }?.name ?? "Unknown vendor"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bill.billNumber.isEmpty ? "Bill" : bill.billNumber)
                    .font(.headline)
                Spacer()
                Text(bill.isPosted ? "Posted" : "Draft")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(bill.isPosted ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .clipShape(Capsule())
            }
            Text(vendorName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(session.formatted(bill.total))
                .font(.subheadline.monospacedDigit())
        }
        .padding(.vertical, 4)
    }
}

private struct NewBillSheet: View {
    let session: BookSession
    @Environment(\.dismiss) private var dismiss
    @State private var vendorGuid: Guid?
    @State private var billNumber = ""
    @State private var dateOpened = Date()
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Vendor", selection: $vendorGuid) {
                        Text("Choose").tag(Guid?.none)
                        ForEach(session.vendors) { vendor in
                            Text(vendor.name).tag(Guid?.some(vendor.guid))
                        }
                    }
                    TextField("Bill number", text: $billNumber)
                    DatePicker("Date opened", selection: $dateOpened, displayedComponents: .date)
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .buttonStyle(.glassProminent)
                        .disabled(vendorGuid == nil || billNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        guard let vendorGuid, let vendor = session.vendors.first(where: { $0.guid == vendorGuid }) else {
            localError = "Choose a vendor."
            return
        }
        Task {
            if await session.createBillDraft(
                vendor: vendor,
                billNumber: billNumber.trimmingCharacters(in: .whitespaces),
                dateOpened: dateOpened
            ) != nil {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

private struct BillDetailView: View {
    let session: BookSession
    let billGuid: Guid

    @State private var showingNewLine = false
    @State private var showingPost = false

    private var bill: Bill? {
        session.bills.first { $0.guid == billGuid }
    }

    private var vendorName: String {
        guard let bill else { return "" }
        return session.vendors.first { $0.guid == bill.vendorGuid }?.name ?? "Unknown vendor"
    }

    var body: some View {
        Group {
            if let bill {
                List {
                    Section {
                        LabeledContent("Vendor", value: vendorName)
                        LabeledContent("Opened", value: String(bill.dateOpened.prefix(10)))
                        if let posted = bill.datePosted {
                            LabeledContent("Posted", value: String(posted.prefix(10)))
                        }
                        if !bill.notes.isEmpty {
                            LabeledContent("Notes", value: bill.notes)
                        }
                    }
                    Section("Lines") {
                        if bill.lines.isEmpty {
                            Text("No lines yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(bill.lines) { line in
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
                            delete(offsets, from: bill)
                        }
                        .deleteDisabled(bill.isPosted)
                        HStack {
                            Text("Total")
                                .font(.headline)
                            Spacer()
                            Text(session.formatted(bill.total))
                                .font(.headline.monospacedDigit())
                        }
                    }
                    if !bill.isPosted {
                        Section {
                            Button("Add line") { showingNewLine = true }
                            Button("Post bill\u{2026}") { showingPost = true }
                                .disabled(bill.lines.isEmpty)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Bill not found", systemImage: "truck.box")
            }
        }
        .navigationTitle(bill?.billNumber ?? "Bill")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingNewLine) {
            if let bill {
                NewBillLineSheet(session: session, bill: bill)
            }
        }
        .sheet(isPresented: $showingPost) {
            if let bill {
                PostBillSheet(session: session, bill: bill)
            }
        }
    }

    private func quantityAndPrice(_ line: BillLine) -> String {
        "\(session.formatted(line.quantity)) \u{00d7} \(session.formatted(line.unitPrice))"
    }

    private func delete(_ offsets: IndexSet, from bill: Bill) {
        for index in offsets {
            let line = bill.lines[index]
            Task { await session.deleteBillLine(line, from: bill) }
        }
    }
}

private struct NewBillLineSheet: View {
    let session: BookSession
    let bill: Bill

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var description = ""
    @State private var quantity = "1"
    @State private var unitPrice = ""
    @State private var expenseAccount: Guid?
    @State private var localError: String?

    private var expenseAccountOptions: [(guid: Guid, name: String, depth: Int)] {
        func walk(_ nodes: [Account], depth: Int, into rows: inout [(Guid, String, Int)]) {
            for node in nodes {
                if node.accountType == "EXPENSE" && !node.placeholder {
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
                    Picker("Expense account", selection: $expenseAccount) {
                        Text("Choose").tag(Guid?.none)
                        ForEach(expenseAccountOptions, id: \.guid) { option in
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
        guard let expenseAccount else {
            localError = "Choose an expense account."
            return
        }
        guard let quantityValue = try? Money.parseHalfUp(quantity, fraction: 10000), quantityValue != .zero else {
            localError = "Enter a quantity like 1 or 2.5."
            return
        }
        guard let priceValue = try? Money.parseHalfUp(unitPrice, fraction: 100), priceValue != .zero else {
            localError = "Enter a unit price like 60.00."
            return
        }
        Task {
            if await session.addBillLine(
                to: bill,
                date: date,
                description: trimmedDescription,
                quantity: quantityValue,
                unitPrice: priceValue,
                expenseAccount: expenseAccount
            ) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

private struct PostBillSheet: View {
    let session: BookSession
    let bill: Bill

    @Environment(\.dismiss) private var dismiss
    @State private var payableAccount: Guid?
    @State private var postedDate = Date()
    @State private var localError: String?

    private var payableAccountOptions: [(guid: Guid, name: String, depth: Int)] {
        let payableTypes: Set<String> = ["ASSET", "BANK", "CASH", "LIABILITY", "CREDIT", "PAYABLE"]
        func walk(_ nodes: [Account], depth: Int, into rows: inout [(Guid, String, Int)]) {
            for node in nodes {
                if payableTypes.contains(node.accountType) && !node.placeholder {
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
                    Text("Posting debits each line's expense account and credits the account below for \(session.formatted(bill.total)). This cannot be undone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Pay from", selection: $payableAccount) {
                        Text("Choose").tag(Guid?.none)
                        ForEach(payableAccountOptions, id: \.guid) { option in
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
            .navigationTitle("Post bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { post() }
                        .buttonStyle(.glassProminent)
                        .disabled(payableAccount == nil)
                }
            }
        }
    }

    private func post() {
        guard let payableAccount else {
            localError = "Choose an account."
            return
        }
        Task {
            if await session.postBill(bill, payableAccount: payableAccount, postedDate: postedDate) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

#Preview {
    BillsView(session: BookSession())
}
