import Foundation

public struct LocalDay: Hashable, Comparable, Codable, CustomStringConvertible, Sendable {
  public let year: Int
  public let month: Int
  public let day: Int

  public init?(_ value: String) {
    guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
    let parts = value.split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
    guard parts.count == 3,
          let date = Self.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
          Self.calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: parts[0], month: parts[1], day: parts[2])
    else { return nil }
    year = parts[0]
    month = parts[1]
    day = parts[2]
  }

  public init(_ date: Date, calendar: Calendar = .current) {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    year = parts.year!
    month = parts.month!
    day = parts.day!
  }

  public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
  public var monthID: String { String(format: "%04d-%02d", year, month) }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  public func adding(days: Int) -> Self {
    Self(Self.calendar.date(byAdding: .day, value: days, to: date)!, calendar: Self.calendar)
  }

  public func adding(months: Int) -> Self {
    Self(Self.calendar.date(byAdding: .month, value: months, to: date)!, calendar: Self.calendar)
  }

  public var weekday: Int { Self.calendar.component(.weekday, from: date) }

  public var date: Date {
    Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
  }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    guard let day = Self(value) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date: \(value)"))
    }
    self = day
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  private static let calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }()
}

public struct DayTotal: Equatable, Codable, Sendable {
  public var seconds: Int
  public var issueKeys: [String]
  public var worklogIDs: [String]

  public init(seconds: Int = 0, issueKeys: [String] = [], worklogIDs: [String] = []) {
    self.seconds = seconds
    self.issueKeys = issueKeys
    self.worklogIDs = worklogIDs
  }
}

public struct MissingDay: Equatable, Codable, Sendable {
  public let date: LocalDay
  public let sourceSeconds: Int

  public init(date: LocalDay, sourceSeconds: Int) {
    self.date = date
    self.sourceSeconds = sourceSeconds
  }
}

public struct TargetDifference: Equatable, Codable, Sendable {
  public let date: LocalDay
  public let sourceSeconds: Int
  public let targetSeconds: Int

  public init(date: LocalDay, sourceSeconds: Int, targetSeconds: Int) {
    self.date = date
    self.sourceSeconds = sourceSeconds
    self.targetSeconds = targetSeconds
  }
}

public struct PeriodReport: Equatable, Codable, Sendable {
  public let from: LocalDay
  public let to: LocalDay
  public let workingDays: Int
  public let sourceSeconds: Int
  public let targetSeconds: Int?
  public let missing: [MissingDay]
  public let differences: [TargetDifference]?
}

public struct MonthCapacity: Equatable, Codable, Sendable {
  public let workingDays: Int
  public let daysOff: Int
  public let expectedSeconds: Int
  public let reportedSeconds: Int

  public init(workingDays: Int, daysOff: Int, expectedSeconds: Int, reportedSeconds: Int) {
    self.workingDays = workingDays
    self.daysOff = daysOff
    self.expectedSeconds = expectedSeconds
    self.reportedSeconds = reportedSeconds
  }
}

public struct ReportAnalysis: Equatable, Codable, Sendable {
  public let today: PeriodReport
  public let yesterday: PeriodReport
  public let week: PeriodReport
  public let month: PeriodReport
  public let underreported: [LocalDay]
  public let monthCapacity: MonthCapacity
}

public enum Reporting {
  public static func synchronizationWindow(now: LocalDay) -> ClosedRange<LocalDay> {
    LocalDay("\(now.monthID)-01")!.adding(months: -1)...now
  }

  public static func reportWindow(now: LocalDay) -> ClosedRange<LocalDay> {
    let weekFrom = workWeek(now: now).lowerBound
    return min(LocalDay("\(now.monthID)-01")!, weekFrom)...now
  }

  public static func analyze(
    now: LocalDay,
    expectedSeconds: Int,
    sourceDays: [LocalDay: DayTotal],
    targetDays: [LocalDay: DayTotal]? = nil
  ) -> ReportAnalysis {
    let yesterday = previousWorkday(before: now)
    let week = workWeek(now: now)
    let monthFrom = LocalDay("\(now.monthID)-01")!
    let nextMonth = monthFrom.adding(months: 1)
    let monthTo = nextMonth.adding(days: -1)
    let monthWorkdays = workdays(from: monthFrom, through: monthTo)

    return ReportAnalysis(
      today: status(from: now, to: now, expectedSeconds: expectedSeconds, sourceDays: sourceDays, targetDays: targetDays),
      yesterday: status(from: yesterday, to: yesterday, expectedSeconds: expectedSeconds, sourceDays: sourceDays, targetDays: targetDays),
      week: status(from: week.lowerBound, to: week.upperBound, expectedSeconds: expectedSeconds, sourceDays: sourceDays, targetDays: targetDays),
      month: status(from: monthFrom, to: yesterday, expectedSeconds: expectedSeconds, sourceDays: sourceDays, targetDays: targetDays),
      underreported: workdays(from: monthFrom, through: now).filter { sourceDays[$0, default: DayTotal()].seconds < expectedSeconds },
      monthCapacity: MonthCapacity(
        workingDays: monthWorkdays.count,
        daysOff: monthTo.day - monthWorkdays.count,
        expectedSeconds: monthWorkdays.count * expectedSeconds,
        reportedSeconds: sourceDays.filter { $0.key >= monthFrom && $0.key <= now }.values.reduce(0) { $0 + $1.seconds }
      )
    )
  }

  public static func workdays(from: LocalDay, through to: LocalDay) -> [LocalDay] {
    guard from <= to else { return [] }
    var result: [LocalDay] = []
    var date = from
    while date <= to {
      if isWorkday(date) { result.append(date) }
      date = date.adding(days: 1)
    }
    return result
  }

  private static func previousWorkday(before date: LocalDay) -> LocalDay {
    var candidate = date.adding(days: -1)
    while !isWorkday(candidate) { candidate = candidate.adding(days: -1) }
    return candidate
  }

  private static func isWorkday(_ date: LocalDay) -> Bool {
    date.weekday != 1 && date.weekday != 7 && !holidays(year: date.year).contains(date)
  }

  private static func workWeek(now: LocalDay) -> ClosedRange<LocalDay> {
    let mondayBasedWeekday = now.weekday == 1 ? 7 : now.weekday - 1
    let yesterday = now.adding(days: -1)
    let from = mondayBasedWeekday == 1 ? now.adding(days: -7) : now.adding(days: -(mondayBasedWeekday - 1))
    return from...yesterday
  }

  private static func status(
    from: LocalDay,
    to: LocalDay,
    expectedSeconds: Int,
    sourceDays: [LocalDay: DayTotal],
    targetDays: [LocalDay: DayTotal]?
  ) -> PeriodReport {
    let expectedDays = workdays(from: from, through: to)
    let sourceSeconds = sourceDays.filter { $0.key >= from && $0.key <= to }.values.reduce(0) { $0 + $1.seconds }
    let targetSeconds = targetDays.map { $0.filter { $0.key >= from && $0.key <= to }.values.reduce(0) { $0 + $1.seconds } }
    let differences = targetDays.map { target in
      Set(sourceDays.keys).union(target.keys).filter { $0 >= from && $0 <= to }.sorted().compactMap { day in
        let source = sourceDays[day, default: DayTotal()].seconds
        let destination = target[day, default: DayTotal()].seconds
        return source == destination ? nil : TargetDifference(date: day, sourceSeconds: source, targetSeconds: destination)
      }
    }
    return PeriodReport(
      from: from,
      to: to,
      workingDays: expectedDays.count,
      sourceSeconds: sourceSeconds,
      targetSeconds: targetSeconds,
      missing: expectedDays.compactMap {
        let seconds = sourceDays[$0, default: DayTotal()].seconds
        return seconds < expectedSeconds ? MissingDay(date: $0, sourceSeconds: seconds) : nil
      },
      differences: differences
    )
  }

  private static func holidays(year: Int) -> Set<LocalDay> {
    let sunday = easter(year: year)
    return Set([
      "\(year)-01-01", "\(year)-01-06", sunday.description, sunday.adding(days: 1).description,
      "\(year)-05-01", "\(year)-05-03", sunday.adding(days: 49).description,
      sunday.adding(days: 60).description, "\(year)-08-15", "\(year)-11-01", "\(year)-11-11",
      "\(year)-12-24", "\(year)-12-25", "\(year)-12-26",
    ].compactMap(LocalDay.init))
  }

  private static func easter(year: Int) -> LocalDay {
    let a = year % 19
    let b = year / 100
    let c = year % 100
    let d = b / 4
    let e = b % 4
    let f = (b + 8) / 25
    let g = (b - f + 1) / 3
    let h = (19 * a + b - d - g + 15) % 30
    let i = c / 4
    let k = c % 4
    let l = (32 + 2 * e + 2 * i - h - k) % 7
    let m = (a + 11 * h + 22 * l) / 451
    let month = (h + l - 7 * m + 114) / 31
    let day = (h + l - 7 * m + 114) % 31 + 1
    return LocalDay(String(format: "%04d-%02d-%02d", year, month, day))!
  }
}
