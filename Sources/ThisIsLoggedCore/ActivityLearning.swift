import CryptoKit
import Foundation
import SQLite3

public struct ActivityTrainingSample: Sendable {
  public let day: LocalDay
  public let features: ActivityFeatures
  public let reportedMinutes: Double
  public let baselineMinutes: Double

  public init(day: LocalDay, features: ActivityFeatures, reportedMinutes: Double, baselineMinutes: Double? = nil) {
    self.day = day
    self.features = features
    self.reportedMinutes = reportedMinutes
    self.baselineMinutes = baselineMinutes ?? features.activeMinutes
  }
}

/// Small ridge regression, with a chronological holdout and a prior equal to the raw time rule.
public struct ActivityTimeModel: Codable, Sendable {
  public let trainedAt: Date
  public let trainedThrough: LocalDay?
  public let sampleCount: Int
  public let dayCount: Int
  public let validationDays: Int
  public let baselineMAE: Double?
  public let modelMAE: Double?
  private let weights: [Double]?

  public var validated: Bool { weights?.count == 2 && weights?.allSatisfy(\.isFinite) == true }

  public func isUsable(on day: LocalDay, now: Date) -> Bool {
    validated && trainedThrough.map { $0 < day } == true && now >= trainedAt && now.timeIntervalSince(trainedAt) <= 14 * 86400
  }

  public func summary(on day: LocalDay, now: Date = Date()) -> String {
    if isUsable(on: day, now: now) { return "ML lokalny · \(dayCount) dni nauki" }
    if validated { return "ML · reguły dla tego dnia lub nieaktualnego modelu" }
    if modelMAE != nil { return "ML · test nie potwierdził poprawy, używam reguł" }
    return "ML · nauka: \(dayCount)/20 dni, \(sampleCount)/30 próbek"
  }

  public func predict(_ features: ActivityFeatures) -> Double {
    guard let weights, validated else { return features.activeMinutes }
    return Self.prediction(features, weights)
  }

  public static func train(_ input: [ActivityTrainingSample], now: Date = Date()) -> Self {
    let cutoff = LocalDay(now).adding(days: -2)
    let samples = input.filter {
      $0.day <= cutoff && $0.features.activeMinutes.isFinite && (5...960).contains($0.features.activeMinutes) &&
      (1...1000).contains($0.features.promptCount) && $0.reportedMinutes.isFinite && (1...960).contains($0.reportedMinutes) &&
      $0.baselineMinutes.isFinite && $0.baselineMinutes >= 0
    }.sorted { $0.day < $1.day }
    let days = Set(samples.map(\.day)).sorted()
    var validationDays = 0
    var baselineMAE: Double?
    var modelMAE: Double?
    var weights: [Double]?
    if days.count >= 20, samples.count >= 30 {
      validationDays = max(5, days.count / 4)
      let split = days[days.count - validationDays]
      let training = samples.filter { $0.day < split }
      let validation = samples.filter { $0.day >= split }
      let candidate = fit(training)
      baselineMAE = validation.reduce(0) { $0 + abs($1.baselineMinutes - $1.reportedMinutes) } / Double(validation.count)
      modelMAE = validation.reduce(0) { $0 + abs(prediction($1.features, candidate) - $1.reportedMinutes) } / Double(validation.count)
      // Require both a relative and an absolute improvement, not rounding noise.
      if let baselineMAE, let modelMAE, modelMAE <= baselineMAE * 0.9, baselineMAE - modelMAE >= 5 {
        weights = fit(samples)
      }
    }
    return Self(trainedAt: now, trainedThrough: days.last, sampleCount: samples.count, dayCount: days.count,
                validationDays: validationDays, baselineMAE: baselineMAE, modelMAE: modelMAE, weights: weights)
  }

  private static func fit(_ samples: [ActivityTrainingSample]) -> [Double] {
    // Two normalized features; closed-form ridge toward [1, 0]. No intercept: no activity means no invented time.
    var a = 1.0, b = 0.0, d = 1.0, u = 1.0, v = 0.0
    for sample in samples {
      let x = sample.features.activeMinutes / 60, z = Double(sample.features.promptCount) / 10
      let y = sample.reportedMinutes / 60
      a += x * x; b += x * z; d += z * z; u += x * y; v += z * y
    }
    let determinant = a * d - b * b
    guard determinant > 0, determinant.isFinite else { return [1, 0] }
    return [(u * d - b * v) / determinant, (a * v - b * u) / determinant]
  }

  private static func prediction(_ feature: ActivityFeatures, _ weights: [Double]) -> Double {
    let minutes = weights[0] * feature.activeMinutes + weights[1] * Double(feature.promptCount) * 6
    return min(feature.activeMinutes * 3, max(0, minutes))
  }
}

extension ActivityStore {
  public static func learningProfile(_ settings: AppSettings) -> String {
    let parts = ["time-model-v1", settings.source.url.absoluteString, settings.source.email, settings.source.token,
                 settings.catchAllIssue, String(settings.workdayHours), TimeZone.current.identifier]
    return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public func learningModel(profile: String) throws -> ActivityTimeModel? {
    try withDatabase { database in
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, "SELECT model FROM activity_learning_state WHERE profile = ?", -1, &statement, nil) == SQLITE_OK else { throw databaseError(database) }
      defer { sqlite3_finalize(statement) }
      bind(profile, to: statement, at: 1)
      let step = sqlite3_step(statement)
      guard step == SQLITE_ROW || step == SQLITE_DONE else { throw databaseError(database) }
      guard let value = string(statement, 0) else { return nil }
      return try JSONDecoder().decode(ActivityTimeModel.self, from: Data(value.utf8))
    }
  }

  /// At most daily after success, hourly after failure. Claim is atomic across app/launchd processes.
  public func claimLearningRefresh(profile: String, now: Date) throws -> Bool {
    try withDatabase { database in
      let sql = """
        INSERT INTO activity_learning_state(profile, attempted_at) VALUES (?, ?)
        ON CONFLICT(profile) DO UPDATE SET attempted_at = excluded.attempted_at
        WHERE attempted_at <= excluded.attempted_at - 3600
          AND (completed_at IS NULL OR completed_at <= excluded.attempted_at - 86400)
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError(database) }
      defer { sqlite3_finalize(statement) }
      bind(profile, to: statement, at: 1)
      sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
      return sqlite3_changes(database) == 1
    }
  }

  public func recordLearningDay(profile: String, day: LocalDay, features: [String: ActivityFeatures], reports: [String: Int], baselines: [String: Double] = [:], now: Date) throws {
    guard day <= LocalDay(now).adding(days: -2) else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let featureJSON = String(decoding: try encoder.encode(features), as: UTF8.self)
    let reportJSON = String(decoding: try encoder.encode(reports), as: UTF8.self)
    let baselineJSON = String(decoding: try encoder.encode(baselines), as: UTF8.self)
    try withDatabase { database in
      let sql = """
        INSERT INTO activity_learning_days(profile, day, features, reports, baselines, stable_since, confirmed_at) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(profile, day) DO UPDATE SET features = excluded.features, reports = excluded.reports,
          baselines = excluded.baselines, confirmed_at = excluded.confirmed_at,
          stable_since = CASE WHEN features = excluded.features AND reports = excluded.reports AND baselines = excluded.baselines
            THEN stable_since ELSE excluded.stable_since END
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError(database) }
      defer { sqlite3_finalize(statement) }
      for (index, value) in [profile, day.description, featureJSON, reportJSON, baselineJSON].enumerated() { bind(value, to: statement, at: Int32(index + 1)) }
      sqlite3_bind_double(statement, 6, now.timeIntervalSince1970)
      sqlite3_bind_double(statement, 7, now.timeIntervalSince1970)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
    }
  }

  public func trainLearningModel(profile: String, now: Date) throws -> ActivityTimeModel {
    try withDatabase { database in
      // ponytail: fit the latest 90 days to bound work and adapt to drift; the full history remains archived.
      let sql = "SELECT day, features, reports, baselines FROM activity_learning_days WHERE profile = ? AND day >= ? AND day <= ? AND confirmed_at >= stable_since + 86400 AND confirmed_at >= ? ORDER BY day"
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError(database) }
      defer { sqlite3_finalize(statement) }
      bind(profile, to: statement, at: 1)
      bind(LocalDay(now).adding(days: -90).description, to: statement, at: 2)
      bind(LocalDay(now).adding(days: -2).description, to: statement, at: 3)
      sqlite3_bind_double(statement, 4, now.timeIntervalSince1970 - 36 * 3600)
      var samples: [ActivityTrainingSample] = []
      var step = sqlite3_step(statement)
      while step == SQLITE_ROW {
        guard let day = string(statement, 0).flatMap(LocalDay.init),
              let raw = string(statement, 1), let logged = string(statement, 2), let base = string(statement, 3) else { throw databaseError(database) }
        let features = try JSONDecoder().decode([String: ActivityFeatures].self, from: Data(raw.utf8))
        let reports = try JSONDecoder().decode([String: Int].self, from: Data(logged.utf8))
        let baselines = try JSONDecoder().decode([String: Double].self, from: Data(base.utf8))
        // An unreported observed task is unknown, not a zero-minute training label.
        if features.keys.allSatisfy({ reports[$0, default: 0] > 0 }) {
          samples += features.keys.sorted().map {
            ActivityTrainingSample(day: day, features: features[$0]!, reportedMinutes: Double(reports[$0]!) / 60, baselineMinutes: baselines[$0])
          }
        }
        step = sqlite3_step(statement)
      }
      guard step == SQLITE_DONE else { throw databaseError(database) }
      return ActivityTimeModel.train(samples, now: now)
    }
  }

  public func refreshLearning(settings: AppSettings, client: JiraClient? = nil, now: Date = Date()) async throws {
    guard settings.claudeIntegrationEnabled, !settings.isOnVacation(on: LocalDay(now)) else { return }
    let profile = Self.learningProfile(settings)
    guard try claimLearningRefresh(profile: profile, now: now) else { return }
    let from = LocalDay(now).adding(days: -90), to = LocalDay(now).adding(days: -2)
    let calendar = Calendar.current
    func midnight(_ day: LocalDay) -> Date {
      calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
    }
    let history = try events(from: midnight(from), to: midnight(to.adding(days: 1)))
    let days = Dictionary(grouping: history, by: { LocalDay($0.occurredAt) })
    var reports: [LocalDay: [String: Int]] = [:]
    if !days.isEmpty {
      let source = client ?? JiraClient(credentials: settings.source)
      let user = try await source.currentUser()
      reports = try await source.worklogSecondsByDayAndIssue(userID: user.id, from: from, to: to)
    }
    var day = from
    while day <= to {
      let events = days[day] ?? []
      let end = midnight(day.adding(days: 1))
      let features = ActivityEstimator.features(events: events, end: end, fallbackIssue: settings.catchAllIssue)
        .filter { $0.key != settings.catchAllIssue && $0.key != "Nieprzypisane" && $0.value.activeMinutes >= 5 }
      let baseline = ActivityEstimator.analyze(events: events, start: midnight(day), end: end,
        targetMinutes: calendar.isDateInWeekend(midnight(day)) ? nil : Int(settings.workdayHours * 60),
        reservedIntervals: [], loggedSecondsByIssue: [:], fallbackIssue: settings.catchAllIssue, model: nil)
      let baselines = Dictionary(uniqueKeysWithValues: baseline.allocations.map { ($0.issueKey, Double($0.minutes)) })
      try recordLearningDay(profile: profile, day: day, features: features, reports: reports[day] ?? [:], baselines: baselines, now: now)
      day = day.adding(days: 1)
    }
    let model = try trainLearningModel(profile: profile, now: now)
    let json = String(decoding: try JSONEncoder().encode(model), as: UTF8.self)
    try withDatabase { database in
      var statement: OpaquePointer?
      // A correction or a newer refresh can revoke this claim while Jira is being read.
      guard sqlite3_prepare_v2(database, "UPDATE activity_learning_state SET completed_at = ?, model = ? WHERE profile = ? AND attempted_at = ?", -1, &statement, nil) == SQLITE_OK else { throw databaseError(database) }
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
      bind(json, to: statement, at: 2)
      bind(profile, to: statement, at: 3)
      sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
    }
  }
}
