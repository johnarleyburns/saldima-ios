// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

/// Clients to bill, the GnuCash `GncCustomer` business object. Reached from
/// Invoices, since picking a client is the first step in starting one.
struct CustomersView: View {
    let session: BookSession
    @State private var sheet: SheetTarget?

    private enum SheetTarget: Identifiable {
        case customer(Customer?)
        var id: String {
            switch self {
            case .customer(let customer): customer?.guid.rawValue ?? "new-customer"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.customers.isEmpty {
                    ContentUnavailableView {
                        Label("No clients", systemImage: "person.2")
                    } description: {
                        Text("Add a client to start billing them.")
                    } actions: {
                        Button("Add client") { sheet = .customer(nil) }
                            .buttonStyle(.glassProminent)
                            .disabled(!session.isOpen)
                    }
                } else {
                    List {
                        ForEach(session.customers) { customer in
                            Button {
                                sheet = .customer(customer)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(customer.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    if !customer.email.isEmpty {
                                        Text(customer.email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Clients")
            .toolbar {
                if session.isOpen {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            sheet = .customer(nil)
                        } label: {
                            Label("Add client", systemImage: "plus")
                        }
                        .accessibilityIdentifier("customers.add")
                    }
                }
            }
            .sheet(item: $sheet) { target in
                switch target {
                case .customer(let customer):
                    CustomerEditor(session: session, editing: customer)
                }
            }
        }
    }
}

private struct CustomerEditor: View {
    let session: BookSession
    let editing: Customer?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var customerNumber: String
    @State private var addressName: String
    @State private var addressLine1: String
    @State private var addressLine2: String
    @State private var phone: String
    @State private var email: String
    @State private var notes: String
    @State private var active: Bool
    @State private var localError: String?
    @State private var confirmingDelete = false

    init(session: BookSession, editing: Customer?) {
        self.session = session
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _customerNumber = State(initialValue: editing?.customerNumber ?? "")
        _addressName = State(initialValue: editing?.addressName ?? "")
        _addressLine1 = State(initialValue: editing?.addressLine1 ?? "")
        _addressLine2 = State(initialValue: editing?.addressLine2 ?? "")
        _phone = State(initialValue: editing?.phone ?? "")
        _email = State(initialValue: editing?.email ?? "")
        _notes = State(initialValue: editing?.notes ?? "")
        _active = State(initialValue: editing?.active ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Client") {
                    TextField("Name", text: $name)
                    TextField("Client number", text: $customerNumber)
                }
                Section("Billing address") {
                    TextField("Name on address", text: $addressName)
                    TextField("Address line 1", text: $addressLine1)
                    TextField("Address line 2", text: $addressLine2)
                }
                Section("Contact") {
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                if editing != nil {
                    Section {
                        Toggle("Active", isOn: $active)
                    }
                    Section {
                        Button("Delete client", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle(editing == nil ? "Add client" : "Edit client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                }
            }
            .confirmationDialog(
                "Delete this client?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let editing else { return }
                    Task {
                        if await session.delete(editing) {
                            dismiss()
                        } else {
                            localError = session.lastError
                        }
                    }
                }
            }
        }
    }

    private func save() {
        let draft = CustomerDraft(
            name: name,
            customerNumber: customerNumber,
            addressName: addressName,
            addressLine1: addressLine1,
            addressLine2: addressLine2,
            phone: phone,
            email: email,
            notes: notes,
            active: active
        )
        Task {
            if await session.saveCustomer(draft, editing: editing) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

#Preview {
    CustomersView(session: BookSession())
}
