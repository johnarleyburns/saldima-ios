// SPDX-License-Identifier: AGPL-3.0-only

/// Desktop GnuCash's "Scheduled Transactions" calendar math, ported
/// verbatim from the web track's `packages/gnucash/src/recurrence.ts` (the
/// web's own locked design, `johnarleyburns/saldima#98`). Dates are plain
/// `YYYY-MM-DD` strings throughout, exactly as the rest of `SaldimaCore`
/// represents dates (`StoredTransaction.date`, etc.) -- never a Foundation
/// `Date`/`Calendar`, so the arithmetic is deterministic and identical on
/// every platform this module builds for, including the Linux CI job. The
/// day-count conversions are Howard Hinnant's well-known constexpr
/// `days_from_civil`/`civil_from_days` (a proleptic Gregorian calendar,
/// public-domain algorithm, not GnuCash's own code).
public enum PeriodType: String, Sendable, Hashable, Codable, CaseIterable {
    case once
    case day
    case week
    case month
    case endOfMonth
    case nthWeekday
    case lastWeekday
    case year

    /// The literal string GnuCash's XML uses -- three of these contain a
    /// space, matching `recurrence:period_type` exactly.
    public var xmlValue: String {
        switch self {
        case .once: return "once"
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .endOfMonth: return "end of month"
        case .nthWeekday: return "nth weekday"
        case .lastWeekday: return "last weekday"
        case .year: return "year"
        }
    }

    public init?(xmlValue: String) {
        switch xmlValue {
        case "once": self = .once
        case "day": self = .day
        case "week": self = .week
        case "month": self = .month
        case "end of month": self = .endOfMonth
        case "nth weekday": self = .nthWeekday
        case "last weekday": self = .lastWeekday
        case "year": self = .year
        default: return nil
        }
    }
}

/// The final adjustment applied when a computed instance lands on a
/// weekend. A weekday instance is never touched.
public enum WeekendAdjust: String, Sendable, Hashable, Codable, CaseIterable {
    case none
    case back
    case forward
}

/// One schedule's recurrence rule. `start` both anchors the sequence (every
/// instance is an integral number of periods after it) and, for
/// `nthWeekday`/`lastWeekday`, fixes which weekday and which ordinal
/// occurrence of it to repeat.
public struct Recurrence: Sendable, Hashable, Codable {
    public var periodType: PeriodType
    public var multiplier: Int
    public var start: String
    public var weekendAdjust: WeekendAdjust

    public init(
        periodType: PeriodType,
        multiplier: Int = 1,
        start: String,
        weekendAdjust: WeekendAdjust = .none
    ) {
        self.periodType = periodType
        self.multiplier = multiplier
        self.start = start
        self.weekendAdjust = weekendAdjust
    }
}

public enum RecurrenceError: Error, Equatable, Sendable {
    case invalidMultiplier
    case invalidDate
    /// Defensive only -- the walk-forward search should always resolve in a
    /// handful of steps past its estimate; this guards against an
    /// unforeseen infinite loop rather than a real input.
    case iterationLimitExceeded
}

/// The earliest date strictly after `refDate` that `recurrence` lands on.
/// `nil` only for `.once` once its single instance is in the past.
public func nextInstance(_ recurrence: Recurrence, after refDate: String) throws -> String? {
    guard recurrence.multiplier >= 1 else { throw RecurrenceError.invalidMultiplier }
    let ref = try parseDate(refDate)
    let start = try parseDate(recurrence.start)
    let refDays = daysFromCivil(ref)
    let startDays = daysFromCivil(start)

    switch recurrence.periodType {
    case .once:
        return refDays < startDays ? recurrence.start : nil

    case .day, .week:
        let periodDays = recurrence.periodType == .week ? recurrence.multiplier * 7 : recurrence.multiplier
        let diff = refDays - startDays
        let k = diff < 0 ? 0 : diff / periodDays + 1
        let candidateDays = startDays + k * periodDays
        let candidate = civilFromDays(candidateDays)
        return formatDate(applyWeekendAdjust(candidate, recurrence.weekendAdjust))

    default:
        // month, endOfMonth, nthWeekday, lastWeekday, year.
        let monthMultiplier = recurrence.periodType == .year ? recurrence.multiplier * 12 : recurrence.multiplier
        let startMonthIndex = start.y * 12 + (start.m - 1)
        let refMonthIndex = ref.y * 12 + (ref.m - 1)
        let monthDiff = refMonthIndex - startMonthIndex
        let estimate = monthDiff < 0 ? 0 : monthDiff / monthMultiplier
        var k = max(0, estimate - 2)
        var iterations = 0
        while true {
            iterations += 1
            guard iterations <= 10_000 else { throw RecurrenceError.iterationLimitExceeded }
            let targetMonthIndex = startMonthIndex + k * monthMultiplier
            let targetYear = targetMonthIndex / 12
            let targetMonth = targetMonthIndex % 12 + 1
            let resolved = resolveDay(
                periodType: recurrence.periodType,
                start: start,
                targetYear: targetYear,
                targetMonth: targetMonth
            )
            if daysFromCivil(resolved) > refDays {
                return formatDate(applyWeekendAdjust(resolved, recurrence.weekendAdjust))
            }
            k += 1
        }
    }
}

/// Plain calendar-day arithmetic (`days` may be negative), used for the
/// create/remind horizon math in `BookStore.dueScheduledInstances`.
public func addDays(_ date: String, _ days: Int) throws -> String {
    let parts = try parseDate(date)
    return formatDate(civilFromDays(daysFromCivil(parts) + days))
}

// MARK: - Day resolution

private func resolveDay(periodType: PeriodType, start: DateParts, targetYear: Int, targetMonth: Int) -> DateParts {
    switch periodType {
    case .endOfMonth:
        return DateParts(y: targetYear, m: targetMonth, d: daysInMonth(targetYear, targetMonth))

    case .nthWeekday:
        let weekday = dayOfWeek(start)
        let occurrence = (start.d - 1) / 7 + 1
        if let day = nthWeekdayOfMonth(year: targetYear, month: targetMonth, weekday: weekday, occurrence: occurrence) {
            return DateParts(y: targetYear, m: targetMonth, d: day)
        }
        // The ordinal occurrence doesn't exist this month (e.g. a 5th
        // Tuesday): fall back to the last occurrence instead of skipping
        // the month entirely.
        return DateParts(
            y: targetYear,
            m: targetMonth,
            d: lastWeekdayOfMonth(year: targetYear, month: targetMonth, weekday: weekday)
        )

    case .lastWeekday:
        let weekday = dayOfWeek(start)
        return DateParts(
            y: targetYear,
            m: targetMonth,
            d: lastWeekdayOfMonth(year: targetYear, month: targetMonth, weekday: weekday)
        )

    case .month, .year:
        return DateParts(y: targetYear, m: targetMonth, d: min(start.d, daysInMonth(targetYear, targetMonth)))

    case .once, .day, .week:
        // Unreachable: the caller only reaches `resolveDay` for the
        // month-based period types handled above.
        return DateParts(y: targetYear, m: targetMonth, d: min(start.d, daysInMonth(targetYear, targetMonth)))
    }
}

private func nthWeekdayOfMonth(year: Int, month: Int, weekday: Int, occurrence: Int) -> Int? {
    let firstDayWeekday = dayOfWeek(DateParts(y: year, m: month, d: 1))
    let offset = (weekday - firstDayWeekday + 7) % 7
    let day = 1 + offset + (occurrence - 1) * 7
    return day <= daysInMonth(year, month) ? day : nil
}

private func lastWeekdayOfMonth(year: Int, month: Int, weekday: Int) -> Int {
    let last = daysInMonth(year, month)
    let lastDayWeekday = dayOfWeek(DateParts(y: year, m: month, d: last))
    let diff = (lastDayWeekday - weekday + 7) % 7
    return last - diff
}

/// Applied as the final step, after the raw period/day math resolves a
/// candidate -- never re-checked against the reference date afterward.
private func applyWeekendAdjust(_ parts: DateParts, _ adjust: WeekendAdjust) -> DateParts {
    guard adjust != .none else { return parts }
    let weekday = dayOfWeek(parts)
    guard weekday == 0 || weekday == 6 else { return parts }
    let shift: Int
    if adjust == .back {
        shift = weekday == 0 ? -2 : -1
    } else {
        shift = weekday == 6 ? 2 : 1
    }
    return civilFromDays(daysFromCivil(parts) + shift)
}

// MARK: - Pure civil-calendar arithmetic (no Foundation)

private struct DateParts: Equatable {
    var y: Int
    var m: Int
    var d: Int
}

private func isLeapYear(_ year: Int) -> Bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

private func daysInMonth(_ year: Int, _ month: Int) -> Int {
    switch month {
    case 1, 3, 5, 7, 8, 10, 12: return 31
    case 4, 6, 9, 11: return 30
    case 2: return isLeapYear(year) ? 29 : 28
    default: return 30
    }
}

/// `0 = Sunday ... 6 = Saturday`.
private func dayOfWeek(_ parts: DateParts) -> Int {
    let z = daysFromCivil(parts)
    return ((z + 4) % 7 + 7) % 7
}

/// Howard Hinnant's `days_from_civil`: days since 1970-01-01 for a
/// proleptic Gregorian calendar date. Public-domain calendar algorithm.
private func daysFromCivil(_ parts: DateParts) -> Int {
    var y = parts.y
    let m = parts.m
    let d = parts.d
    if m <= 2 { y -= 1 }
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

/// The inverse of `daysFromCivil`.
private func civilFromDays(_ zInput: Int) -> DateParts {
    let z = zInput + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp + (mp < 10 ? 3 : -9)
    return DateParts(y: m <= 2 ? y + 1 : y, m: m, d: d)
}

private func parseDate(_ text: String) throws -> DateParts {
    let chars = Array(text)
    guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { throw RecurrenceError.invalidDate }
    func digits(_ range: Range<Int>) -> Int? {
        let slice = chars[range]
        guard slice.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(String(slice))
    }
    guard let y = digits(0..<4), let m = digits(5..<7), let d = digits(8..<10), m >= 1, m <= 12, d >= 1, d <= 31 else {
        throw RecurrenceError.invalidDate
    }
    return DateParts(y: y, m: m, d: d)
}

private func formatDate(_ parts: DateParts) -> String {
    "\(pad(parts.y, 4))-\(pad(parts.m, 2))-\(pad(parts.d, 2))"
}

private func pad(_ value: Int, _ width: Int) -> String {
    let text = String(value)
    guard text.count < width else { return text }
    return String(repeating: "0", count: width - text.count) + text
}
