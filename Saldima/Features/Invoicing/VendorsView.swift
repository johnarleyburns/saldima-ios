// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

/// Vendors to pay, the GnuCash `GncVendor` business object. Reached from
/// Bills, since picking a vendor is the first step in starting one.
struct VendorsView: View {
    let session: BookSession
    @State private var sheet: SheetTarget?

    private enum SheetTarget: Identifiable {
        case vendor(Vendor?)
        var id: String {
            switch self {
            case .vendor(let vendor): vendor?.guid.rawValue ?? "new-vendor"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.vendors.isEmpty {
                    ContentUnavailableView {
                        Label("No vendors", systemImage: "truck.box")
                    } description: {
                        Text("Add a vendor to start tracking bills owed to them.")
                    } actions: {
                        Button("Add vendor") { sheet = .vendor(nil) }
                            .buttonStyle(.glassProminent)
                            .disabled(!session.isOpen)
                    }
                } else {
                    List {
                        ForEach(session.vendors) { vendor in
                            Button {
                                sheet = .vendor(vendor)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vendor.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    if !vendor.email.isEmpty {
                                        Text(vendor.email)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Vendors")
            .toolbar {
                if session.isOpen {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            sheet = .vendor(nil)
                        } label: {
                            Label("Add vendor", systemImage: "plus")
                        }
                        .accessibilityIdentifier("vendors.add")
                    }
                }
            }
            .sheet(item: $sheet) { target in
                switch target {
                case .vendor(let vendor):
                    VendorEditor(session: session, editing: vendor)
                }
            }
        }
    }
}

private struct VendorEditor: View {
    let session: BookSession
    let editing: Vendor?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var vendorNumber: String
    @State private var addressLine1: String
    @State private var phone: String
    @State private var email: String
    @State private var notes: String
    @State private var active: Bool
    @State private var localError: String?
    @State private var confirmingDelete = false

    init(session: BookSession, editing: Vendor?) {
        self.session = session
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _vendorNumber = State(initialValue: editing?.vendorNumber ?? "")
        _addressLine1 = State(initialValue: editing?.addressLine1 ?? "")
        _phone = State(initialValue: editing?.phone ?? "")
        _email = State(initialValue: editing?.email ?? "")
        _notes = State(initialValue: editing?.notes ?? "")
        _active = State(initialValue: editing?.active ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Vendor") {
                    TextField("Name", text: $name)
                    TextField("Vendor number", text: $vendorNumber)
                }
                Section("Address") {
                    TextField("Address line 1", text: $addressLine1)
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
                        Button("Delete vendor", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle(editing == nil ? "Add vendor" : "Edit vendor")
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
                "Delete this vendor?",
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
        let draft = VendorDraft(
            name: name,
            vendorNumber: vendorNumber,
            addressLine1: addressLine1,
            phone: phone,
            email: email,
            notes: notes,
            active: active
        )
        Task {
            if await session.saveVendor(draft, editing: editing) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

#Preview {
    VendorsView(session: BookSession())
}
