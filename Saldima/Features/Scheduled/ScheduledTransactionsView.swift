// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

import SaldimaCore

extension PeriodType {
    /// A singular noun for display -- "Every 2 \(noun)s", or just
    /// "Every \(noun)" at multiplier 1.
    var displayNoun: String {
        switch self {
        case .once: return "time"
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .endOfMonth: return "end of month"
        case .nthWeekday: return "nth weekday"
        case .lastWeekday: return "last weekday"
        case .year: return "year"
        }
    }
}

extension WeekendAdjust {
    var displayName: String {
        switch self {
        case .none: return "Don't adjust"
        case .back: return "Move earlier"
        case .forward: return "Move later"
        }
    }
}

/// Desktop GnuCash's "Scheduled Transactions" editor: list, create, and
/// delete recurring schedules and their template splits. Editing an
/// existing schedule is restricted to the same six fields the web engine
/// allows (`johnarleyburns/saldima#98`) -- the recurrence and template
/// splits are immutable once created; change those by deleting and
/// recreating the schedule.
struct ScheduledTransactionsView: View {
    let session: BookSession
    @State private var composing = false
    @State private var editing: ScheduledTransaction?

    var body: some View {
        NavigationStack {
            Group {
                if session.scheduledTransactions.isEmpty {
                    ContentUnavailableView {
                        Label("No scheduled transactions", systemImage: "calendar.badge.clock")
                    } description: {
                        Text("Add a schedule to be reminded, or have Saldima post automatically, on a recurring basis.")
                    } actions: {
                        Button("New schedule") { composing = true }
                            .buttonStyle(.glassProminent)
                            .disabled(!session.isOpen)
                    }
                } else {
                    List {
                        ForEach(session.scheduledTransactions) { scheduled in
                            Button {
                                editing = scheduled
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(scheduled.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        if !scheduled.enabled {
                                            Text("OFF")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.secondary.opacity(0.15), in: Capsule())
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    Text(summary(scheduled))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    Task { await session.delete(scheduled) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scheduled")
            .toolbar {
                if session.isOpen {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            composing = true
                        } label: {
                            Label("New schedule", systemImage: "plus")
                        }
                        .accessibilityIdentifier("scheduled.add")
                    }
                }
            }
            .sheet(isPresented: $composing) {
                NewScheduledTransactionSheet(session: session)
            }
            .sheet(item: $editing) { scheduled in
                EditScheduledTransactionSheet(session: session, scheduled: scheduled)
            }
        }
    }

    private func summary(_ scheduled: ScheduledTransaction) -> String {
        let recurrence = scheduled.recurrence
        let cadence: String
        if recurrence.periodType == .once {
            cadence = "Once, on \(recurrence.start)"
        } else {
            let noun = recurrence.periodType.displayNoun
            cadence = recurrence.multiplier > 1 ? "Every \(recurrence.multiplier) \(noun)s" : "Every \(noun)"
        }
        let autoNote: String
        if scheduled.autoCreate {
            autoNote = scheduled.autoCreateNotify ? " \u{00b7} posts automatically, notifies" : " \u{00b7} posts automatically"
        } else {
            autoNote = ""
        }
        return cadence + autoNote
    }
}

/// Two splits cover a simple schedule; up to two more are optional, same
/// shape as the register's own `NewTransactionSheet`.
private let scheduledSplitRowCount = 4

private func isoDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private struct NewScheduledTransactionSheet: View {
    let session: BookSession

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = Date()
    @State private var periodType = PeriodType.month
    @State private var multiplier = 1
    @State private var weekendAdjust = WeekendAdjust.none
    @State private var endMode = 0 // 0 = no end, 1 = after N occurrences, 2 = on a date
    @State private var endOccurrences = 12
    @State private var endDate = Date()
    @State private var autoCreate = false
    @State private var autoCreateNotify = false
    @State private var advanceCreateDays = 0
    @State private var advanceRemindDays = 0
    @State private var splitAccounts: [Guid?] = Array(repeating: nil, count: scheduledSplitRowCount)
    @State private var splitAmounts: [String] = Array(repeating: "", count: scheduledSplitRowCount)
    @State private var localError: String?

    private var options: [(guid: Guid, name: String, depth: Int)] {
        session.accountOptions()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("scheduled.name")
                    DatePicker("Start", selection: $start, displayedComponents: .date)
                }

                Section("Recurrence") {
                    Picker("Repeats", selection: $periodType) {
                        ForEach(PeriodType.allCases, id: \.self) { period in
                            Text(period.displayNoun.capitalized).tag(period)
                        }
                    }
                    if periodType != .once {
                        Stepper("Every \(multiplier) \(periodType.displayNoun)\(multiplier > 1 ? "s" : "")", value: $multiplier, in: 1...30)
                    }
                    Picker("Weekend adjustment", selection: $weekendAdjust) {
                        ForEach(WeekendAdjust.allCases, id: \.self) { adjust in
                            Text(adjust.displayName).tag(adjust)
                        }
                    }
                }

                Section("Ends") {
                    Picker("Ends", selection: $endMode) {
                        Text("Never").tag(0)
                        Text("After a number of times").tag(1)
                        Text("On a date").tag(2)
                    }
                    .pickerStyle(.segmented)
                    if endMode == 1 {
                        Stepper("\(endOccurrences) occurrences", value: $endOccurrences, in: 1...999)
                    } else if endMode == 2 {
                        DatePicker("End date", selection: $endDate, displayedComponents: .date)
                    }
                }

                Section("Posting") {
                    Toggle("Post automatically", isOn: $autoCreate)
                    Toggle("Notify when posted automatically", isOn: $autoCreateNotify)
                        .disabled(!autoCreate)
                    Stepper("Create \(advanceCreateDays) day\(advanceCreateDays == 1 ? "" : "s") ahead", value: $advanceCreateDays, in: 0...90)
                    Stepper("Remind \(advanceRemindDays) day\(advanceRemindDays == 1 ? "" : "s") further ahead", value: $advanceRemindDays, in: 0...90)
                }

                Section("Template splits") {
                    Text("Each split takes a fixed, signed amount; the splits used must sum to zero.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(0..<scheduledSplitRowCount, id: \.self) { index in
                        Picker(index < 2 ? "Account" : "Account (optional)", selection: $splitAccounts[index]) {
                            Text("Choose").tag(Guid?.none)
                            ForEach(options, id: \.guid) { option in
                                Text(option.name).tag(Guid?.some(option.guid))
                            }
                        }
                        TextField("Amount", text: $splitAmounts[index])
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("scheduled.split.\(index).amount")
                    }
                }

                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New schedule")
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
        var splits: [ScheduledSplit] = []
        for index in 0..<scheduledSplitRowCount {
            let account = splitAccounts[index]
            let text = splitAmounts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if account == nil && text.isEmpty { continue }
            guard let account, let value = try? Money.parseHalfUp(text, fraction: session.fraction), value != .zero else {
                localError = "Fill in every split used: an account and a non-zero amount."
                return
            }
            splits.append(ScheduledSplit(accountGuid: account, value: value))
        }
        guard splits.count >= 2 else {
            localError = "Use at least two splits."
            return
        }

        let startText = isoDate(start)
        let end: ScheduledEndCondition?
        switch endMode {
        case 1: end = .occurrences(endOccurrences)
        case 2: end = .date(isoDate(endDate))
        default: end = nil
        }

        let draft = ScheduledTransactionDraft(
            name: trimmed,
            autoCreate: autoCreate,
            autoCreateNotify: autoCreate && autoCreateNotify,
            advanceCreateDays: advanceCreateDays,
            advanceRemindDays: advanceRemindDays,
            start: startText,
            end: end,
            recurrence: Recurrence(
                periodType: periodType,
                multiplier: multiplier,
                start: startText,
                weekendAdjust: weekendAdjust
            ),
            templateSplits: splits
        )

        Task {
            if await session.saveScheduledTransaction(draft) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

/// Only the six fields the web engine's own `UpdateScheduledTransactionInput`
/// allows are editable here -- the recurrence and template splits are
/// shown read-only; change those by deleting and recreating the schedule.
private struct EditScheduledTransactionSheet: View {
    let session: BookSession
    let scheduled: ScheduledTransaction

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var enabled: Bool
    @State private var autoCreate: Bool
    @State private var autoCreateNotify: Bool
    @State private var advanceCreateDays: Int
    @State private var advanceRemindDays: Int
    @State private var localError: String?

    init(session: BookSession, scheduled: ScheduledTransaction) {
        self.session = session
        self.scheduled = scheduled
        _name = State(initialValue: scheduled.name)
        _enabled = State(initialValue: scheduled.enabled)
        _autoCreate = State(initialValue: scheduled.autoCreate)
        _autoCreateNotify = State(initialValue: scheduled.autoCreateNotify)
        _advanceCreateDays = State(initialValue: scheduled.advanceCreateDays)
        _advanceRemindDays = State(initialValue: scheduled.advanceRemindDays)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Toggle("Enabled", isOn: $enabled)
                }
                Section("Posting") {
                    Toggle("Post automatically", isOn: $autoCreate)
                    Toggle("Notify when posted automatically", isOn: $autoCreateNotify)
                        .disabled(!autoCreate)
                    Stepper("Create \(advanceCreateDays) day\(advanceCreateDays == 1 ? "" : "s") ahead", value: $advanceCreateDays, in: 0...90)
                    Stepper("Remind \(advanceRemindDays) day\(advanceRemindDays == 1 ? "" : "s") further ahead", value: $advanceRemindDays, in: 0...90)
                }
                Section("Recurrence") {
                    Text(recurrenceDescription)
                        .foregroundStyle(.secondary)
                    Text("To change the recurrence or template splits, delete this schedule and create a new one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Edit schedule")
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
        let recurrence = scheduled.recurrence
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
        let draft = ScheduledTransactionEditDraft(
            name: trimmed,
            enabled: enabled,
            autoCreate: autoCreate,
            autoCreateNotify: autoCreate && autoCreateNotify,
            advanceCreateDays: advanceCreateDays,
            advanceRemindDays: advanceRemindDays
        )
        Task {
            if await session.updateScheduledTransaction(scheduled.guid, with: draft) {
                dismiss()
            } else {
                localError = session.lastError
            }
        }
    }
}

#Preview {
    ScheduledTransactionsView(session: BookSession())
}
