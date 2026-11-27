// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

private func isoDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

/// Desktop GnuCash's "Budgets" (Actions -> Budget): list, create, edit and
/// delete budgets, and a grid screen (accounts down, periods across) for
/// entering budgeted amounts with a live "actual" readout -- mirrors the
/// web engine's locked design (`johnarleyburns/saldima#102`). The
/// recurrence is immutable once created, the same convention scheduled
/// transactions use: change it by deleting and recreating the budget.
struct BudgetsView: View {
    let session: BookSession
    @State private var composing = false
    @State private var editing: Budget?

    var body: some View {
        NavigationStack {
            Group {
                if session.budgets.isEmpty {
                    ContentUnavailableView {
                        Label("No budgets", systemImage: "tablecells")
                    } description: {
                        Text("Create a budget to track planned amounts against actual spending, by account and period.")
                    } actions: {
                        Button("New budget") { composing = true }
                            .buttonStyle(.glassProminent)
                            .disabled(!session.isOpen)
                    }
                } else {
                    List {
                        ForEach(session.budgets.sorted { $0.name < $1.name }) { budget in
                            NavigationLink {
                                BudgetGridView(session: session, budget: budget)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(budget.name)
                                        .font(.headline)
                                    Text(summary(budget))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    Task { await session.delete(budget) }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Edit") { editing = budget }
                                    .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Budgets")
            .toolbar {
                if session.isOpen {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            composing = true
                        } label: {
                            Label("New budget", systemImage: "plus")
                        }
                        .accessibilityIdentifier("budgets.add")
                    }
                }
            }
            .sheet(isPresented: $composing) {
                NewBudgetSheet(session: session)
            }
            .sheet(item: $editing) { budget in
                EditBudgetSheet(session: session, budget: budget)
            }
        }
    }

    private func summary(_ budget: Budget) -> String {
        let recurrence = budget.recurrence
        let noun = recurrence.periodType.displayNoun
        let cadence = recurrence.multiplier > 1 ? "Every \(recurrence.multiplier) \(noun)s" : "Every \(noun)"
        let periods = budget.periodCount == 1 ? "1 period" : "\(budget.periodCount) periods"
        return "\(cadence) \u{00b7} \(periods), starting \(recurrence.start)"
    }
}

private struct NewBudgetSheet: View {
    let session: BookSession

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var start = Date()
    @State private var periodType = PeriodType.month
    @State private var multiplier = 1
    @State private var weekendAdjust = WeekendAdjust.none
    @State private var periodCount = 12
    @State private var localError: String?

    /// Desktop GnuCash's own budget editor only offers repeating period
    /// types -- "once" would make every period after the first undefined.
    private var periodTypes: [PeriodType] { PeriodType.allCases.filter { $0 != .once } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("budgets.name")
                    TextField("Description (optional)", text: $description)
                    DatePicker("First period starts", selection: $start, displayedComponents: .date)
                }

                Section("Recurrence") {
                    Picker("Each period is", selection: $periodType) {
                        ForEach(periodTypes, id: \.self) { period in
                            Text(period.displayNoun.capitalized).tag(period)
                        }
                    }
                    Stepper(
                        "Every \(multiplier) \(periodType.displayNoun)\(multiplier > 1 ? "s" : "")",
                        value: $multiplier, in: 1...30
                    )
                    Picker("If a period boundary falls on a weekend", selection: $weekendAdjust) {
                        ForEach(WeekendAdjust.allCases, id: \.self) { adjust in
                            Text(adjust.displayName).tag(adjust)
                        }
                    }
                }

                Section("Periods") {
                    Stepper("\(periodCount) period\(periodCount == 1 ? "" : "s")", value: $periodCount, in: 1...999)
                }

                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New budget")
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
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            localError = "Enter a name."
            return
        }
        let startText = isoDate(start)
        let draft = BudgetDraft(
            name: trimmed,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            periodCount: periodCount,
            recurrence: Recurrence(
                periodType: periodType,
                multiplier: multiplier,
                start: startText,
                weekendAdjust: weekendAdjust
            )
        )
        Task {
            if await session.saveBudget(draft) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

/// Only name, description and periodCount are editable here -- the
/// recurrence is shown read-only; change it by deleting and recreating
/// the budget, matching the web engine's own `UpdateBudgetInput`.
private struct EditBudgetSheet: View {
    let session: BookSession
    let budget: Budget

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var periodCount: Int
    @State private var localError: String?

    init(session: BookSession, budget: Budget) {
        self.session = session
        self.budget = budget
        _name = State(initialValue: budget.name)
        _description = State(initialValue: budget.description)
        _periodCount = State(initialValue: budget.periodCount)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description)
                }
                Section("Periods") {
                    Stepper("\(periodCount) period\(periodCount == 1 ? "" : "s")", value: $periodCount, in: 1...999)
                }
                Section("Recurrence") {
                    Text(recurrenceDescription)
                        .foregroundStyle(.secondary)
                    Text("To change the recurrence, delete this budget and create a new one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Edit budget")
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
        }
    }

    private var recurrenceDescription: String {
        let recurrence = budget.recurrence
        let noun = recurrence.periodType.displayNoun
        let cadence = recurrence.multiplier > 1 ? "Every \(recurrence.multiplier) \(noun)s" : "Every \(noun)"
        return "\(cadence), starting \(recurrence.start)"
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            localError = "Enter a name."
            return
        }
        let draft = BudgetEditDraft(
            name: trimmed,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            periodCount: periodCount
        )
        Task {
            if await session.updateBudget(budget.guid, with: draft) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

/// Accounts x periods: enter a budgeted amount per account/period, see a
/// live computed "actual" alongside it, and save the whole grid in one
/// action -- matching the web engine's own `updateBudgetAmountsRoute`,
/// which the web PR explicitly chose over saving each cell separately.
struct BudgetGridView: View {
    let session: BookSession
    let budget: Budget

    @State private var grid: BudgetGrid?
    @State private var amounts: [Guid: [Int: String]] = [:]
    @State private var localError: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let grid {
                if grid.rows.isEmpty {
                    ContentUnavailableView {
                        Label("No budgetable accounts yet", systemImage: "tablecells")
                    }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            GridRow {
                                Text("Account")
                                    .font(.caption.bold())
                                    .frame(width: 140, alignment: .leading)
                                ForEach(Array(grid.periods.enumerated()), id: \.offset) { _, period in
                                    Text(period.start)
                                        .font(.caption.bold())
                                        .frame(width: 92)
                                }
                            }
                            ForEach(grid.rows) { row in
                                GridRow {
                                    Text(row.accountName)
                                        .frame(width: 140, alignment: .leading)
                                    ForEach(row.budgeted.indices, id: \.self) { index in
                                        TextField("0.00", text: binding(accountGuid: row.accountGuid, periodIndex: index))
                                            .keyboardType(.decimalPad)
                                            .multilineTextAlignment(.trailing)
                                            .frame(width: 92)
                                            .accessibilityIdentifier("budgets.grid.\(row.accountGuid.rawValue).\(index)")
                                    }
                                }
                                GridRow {
                                    Text("actual")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ForEach(row.actual.indices, id: \.self) { index in
                                        Text(session.formatted(row.actual[index]))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 92, alignment: .trailing)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
                if let localError {
                    Text(localError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .padding(.horizontal)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(budget.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save amounts") { save() }
                    .buttonStyle(.glassProminent)
                    .disabled(grid == nil || isSaving)
                    .accessibilityIdentifier("budgets.grid.save")
            }
        }
        .task { await load() }
    }

    private func binding(accountGuid: Guid, periodIndex: Int) -> Binding<String> {
        Binding(
            get: { amounts[accountGuid]?[periodIndex] ?? "" },
            set: { amounts[accountGuid, default: [:]][periodIndex] = $0 }
        )
    }

    private func load() async {
        guard let loaded = await session.budgetGrid(for: budget) else { return }
        var seeded: [Guid: [Int: String]] = [:]
        for row in loaded.rows {
            var periods: [Int: String] = [:]
            for (index, amount) in row.budgeted.enumerated() {
                if let amount { periods[index] = session.formatted(amount) }
            }
            seeded[row.accountGuid] = periods
        }
        grid = loaded
        amounts = seeded
    }

    private func save() {
        guard let grid else { return }
        var edits: [BookStore.BudgetAmountEdit] = []
        for row in grid.rows {
            for index in row.budgeted.indices {
                let text = (amounts[row.accountGuid]?[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    edits.append(BookStore.BudgetAmountEdit(accountGuid: row.accountGuid, periodIndex: index, amount: nil))
                    continue
                }
                guard let value = try? Money.parseHalfUp(text, fraction: session.fraction) else {
                    localError = "\"\(text)\" isn't a valid amount for \(row.accountName), period \(index)."
                    return
                }
                edits.append(BookStore.BudgetAmountEdit(accountGuid: row.accountGuid, periodIndex: index, amount: value))
            }
        }
        localError = nil
        isSaving = true
        Task {
            let success = await session.saveBudgetAmounts(budget.guid, edits: edits)
            isSaving = false
            if success {
                await load()
            } else {
                localError = session.lastError
            }
        }
    }
}

#Preview {
    BudgetsView(session: BookSession())
}
