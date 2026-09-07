import Foundation

public struct JiraCredentials: Equatable, Sendable {
  public var url: URL
  public var email: String
  public var token: String

  public init(url: URL, email: String = "", token: String) {
    self.url = url
    self.email = email
    self.token = token
  }
}

public struct AppSettings: Equatable, Sendable {
  public var source: JiraCredentials
  public var synchronizationEnabled: Bool
  public var target: JiraCredentials?
  public var targetIssue: String
  public var commentIssueKeys: Bool
  public var synchronizationTime: String
  public var reminderTime: String
  public var workdayHours: Double
  public var claudeIntegrationEnabled: Bool
  public var calendarIntegrationEnabled: Bool
  public var calendarIdentifier: String
  public var catchAllIssue: String

  public init(
    source: JiraCredentials,
    synchronizationEnabled: Bool = false,
    target: JiraCredentials? = nil,
    targetIssue: String = "",
    commentIssueKeys: Bool = false,
    synchronizationTime: String = "23:00",
    reminderTime: String = "16:00",
    workdayHours: Double = 8,
    claudeIntegrationEnabled: Bool = false,
    calendarIntegrationEnabled: Bool = false,
    calendarIdentifier: String = "",
    catchAllIssue: String = "RPR-18"
  ) {
    self.source = source
    self.synchronizationEnabled = synchronizationEnabled
    self.target = target
    self.targetIssue = targetIssue
    self.commentIssueKeys = commentIssueKeys
    self.synchronizationTime = synchronizationTime
    self.reminderTime = reminderTime
    self.workdayHours = workdayHours
    self.claudeIntegrationEnabled = claudeIntegrationEnabled
    self.calendarIntegrationEnabled = calendarIntegrationEnabled
    self.calendarIdentifier = calendarIdentifier
    self.catchAllIssue = catchAllIssue
  }

  public func validated() throws -> Self {
    guard Self.validURL(source.url), !source.token.isEmpty else { throw SettingsError.invalidSource }
    if Self.isCloud(source.url), !source.email.contains("@") { throw SettingsError.sourceEmailRequired }
    guard Self.validClock(reminderTime), workdayHours > 0, workdayHours <= 24 else { throw SettingsError.invalidSchedule }
    if claudeIntegrationEnabled || calendarIntegrationEnabled {
      guard catchAllIssue.range(of: #"^[A-Z][A-Z0-9]*-\d+$"#, options: .regularExpression) != nil
      else { throw SettingsError.invalidActivity }
    }
    if calendarIntegrationEnabled, calendarIdentifier.isEmpty { throw SettingsError.invalidCalendar }
    if synchronizationEnabled {
      guard let target, Self.validURL(target.url), !target.token.isEmpty,
            targetIssue.range(of: #"^[A-Z][A-Z0-9]*-\d+$"#, options: .regularExpression) != nil
      else { throw SettingsError.invalidTarget }
      if Self.isCloud(target.url), !target.email.contains("@") { throw SettingsError.targetEmailRequired }
      guard Self.validClock(synchronizationTime) else { throw SettingsError.invalidSchedule }
    }
    return self
  }

  public static func normalizedURL(_ value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
      ? trimmed : "https://\(trimmed)"
    return URL(string: normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
  }

  public func jiraVerification(comparedTo previous: AppSettings?) -> (source: Bool, target: Bool) {
    (
      source: previous?.source != source,
      target: synchronizationEnabled && (
        previous?.synchronizationEnabled != true ||
        previous?.target != target ||
        previous?.targetIssue != targetIssue
      )
    )
  }

  private static func validURL(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
  }

  private static func isCloud(_ url: URL) -> Bool { url.host?.lowercased().hasSuffix(".atlassian.net") == true }
  private static func validClock(_ value: String) -> Bool {
    value.range(of: #"^(?:[01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
  }
}

public enum SettingsError: LocalizedError {
  case missing
  case invalidSource
  case sourceEmailRequired
  case invalidTarget
  case targetEmailRequired
  case invalidSchedule
  case invalidActivity
  case invalidCalendar

  public var errorDescription: String? {
    switch self {
    case .missing: "Brak konfiguracji."
    case .invalidSource: "Podaj poprawny URL i token Jiry głównej."
    case .sourceEmailRequired: "Jira Cloud wymaga emaila konta Atlassian."
    case .invalidTarget: "Uzupełnij URL, token i zadanie Jiry docelowej."
    case .targetEmailRequired: "Docelowa Jira Cloud wymaga emaila konta Atlassian."
    case .invalidSchedule: "Podaj godziny w formacie GG:MM i pełny dzień od 0 do 24 h."
    case .invalidActivity: "Podaj poprawne zadanie zbiorcze, np. RPR-18."
    case .invalidCalendar: "Wybierz konto kalendarza ze spotkaniami."
    }
  }
}

public final class SettingsStore: @unchecked Sendable {
  public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/this-is-logged", isDirectory: true)

  private struct Stored: Codable {
    var sourceURL: String
    var sourceEmail: String
    var sourceToken: String?
    var synchronizationEnabled: Bool
    var targetURL: String
    var targetEmail: String
    var targetToken: String?
    var targetIssue: String
    var commentIssueKeys: Bool
    var synchronizationTime: String
    var reminderTime: String
    var workdayHours: Double
    var claudeIntegrationEnabled: Bool?
    var calendarIntegrationEnabled: Bool?
    var calendarIdentifier: String?
    var catchAllIssue: String?
  }

  private let file: URL
  private let legacyFile: URL

  public init(
    file: URL = SettingsStore.defaultDirectory.appendingPathComponent("settings.json"),
    legacyFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".this-is-logged.env")
  ) {
    self.file = file
    self.legacyFile = legacyFile
  }

  public func load() throws -> AppSettings {
    if FileManager.default.fileExists(atPath: file.path) {
      return try loadDraft().validated()
    }
    guard FileManager.default.fileExists(atPath: legacyFile.path) else { throw SettingsError.missing }
    let settings = try Self.parseLegacy(String(contentsOf: legacyFile, encoding: .utf8)).validated()
    try save(settings)
    return settings
  }

  public func loadDraft() throws -> AppSettings {
    guard FileManager.default.fileExists(atPath: file.path) else {
      guard FileManager.default.fileExists(atPath: legacyFile.path) else { throw SettingsError.missing }
      return try Self.parseLegacy(String(contentsOf: legacyFile, encoding: .utf8))
    }
    let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
    guard let sourceURL = URL(string: stored.sourceURL) else { throw SettingsError.missing }
    let target = stored.targetURL.isEmpty ? nil : URL(string: stored.targetURL).map {
      JiraCredentials(url: $0, email: stored.targetEmail, token: stored.targetToken ?? "")
    }
    return AppSettings(
      source: JiraCredentials(url: sourceURL, email: stored.sourceEmail, token: stored.sourceToken ?? ""),
      synchronizationEnabled: stored.synchronizationEnabled,
      target: target,
      targetIssue: stored.targetIssue,
      commentIssueKeys: stored.commentIssueKeys,
      synchronizationTime: stored.synchronizationTime,
      reminderTime: stored.reminderTime,
      workdayHours: stored.workdayHours,
      claudeIntegrationEnabled: stored.claudeIntegrationEnabled ?? false,
      calendarIntegrationEnabled: stored.calendarIntegrationEnabled ?? false,
      calendarIdentifier: stored.calendarIdentifier ?? "",
      catchAllIssue: stored.catchAllIssue ?? "RPR-18"
    )
  }

  public func save(_ settings: AppSettings) throws {
    let settings = try settings.validated()
    let stored = Stored(
      sourceURL: settings.source.url.absoluteString,
      sourceEmail: settings.source.email,
      sourceToken: settings.source.token,
      synchronizationEnabled: settings.synchronizationEnabled,
      targetURL: settings.target?.url.absoluteString ?? "",
      targetEmail: settings.target?.email ?? "",
      targetToken: settings.target?.token,
      targetIssue: settings.targetIssue,
      commentIssueKeys: settings.commentIssueKeys,
      synchronizationTime: settings.synchronizationTime,
      reminderTime: settings.reminderTime,
      workdayHours: settings.workdayHours,
      claudeIntegrationEnabled: settings.claudeIntegrationEnabled,
      calendarIntegrationEnabled: settings.calendarIntegrationEnabled,
      calendarIdentifier: settings.calendarIdentifier,
      catchAllIssue: settings.catchAllIssue
    )
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".settings.\(UUID().uuidString).tmp")
    try JSONEncoder().encode(stored).write(to: temporary, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if FileManager.default.fileExists(atPath: file.path) {
      _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: file)
    }
  }

  public static func parseLegacy(_ text: String) throws -> AppSettings {
    let values = Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { part -> (String, String)? in
      let line = String(part)
      guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { return nil }
      return (String(line[..<separator]), String(line[line.index(after: separator)...]))
    })
    guard let sourceURL = AppSettings.normalizedURL(values["SRC_URL"] ?? "") else { throw SettingsError.invalidSource }
    let synchronization = values["SYNC_ENABLED"] == "1" ||
      (values["SYNC_ENABLED"] == nil && ["DST_URL", "DST_TOKEN", "DST_ISSUE"].allSatisfy { !(values[$0] ?? "").isEmpty })
    let target: JiraCredentials?
    if !(values["DST_URL"] ?? "").isEmpty, let url = AppSettings.normalizedURL(values["DST_URL"]!) {
      target = JiraCredentials(url: url, email: values["DST_EMAIL"] ?? "", token: values["DST_TOKEN"] ?? "")
    } else {
      target = nil
    }
    return AppSettings(
      source: JiraCredentials(url: sourceURL, email: values["SRC_EMAIL"] ?? "", token: values["SRC_TOKEN"] ?? ""),
      synchronizationEnabled: synchronization,
      target: target,
      targetIssue: (values["DST_ISSUE"] ?? "").uppercased(),
      commentIssueKeys: values["COMMENT_KEYS"] == "1",
      synchronizationTime: values["SYNC_TIME"] ?? "23:00",
      reminderTime: values["REMINDER_TIME"] ?? "16:00",
      workdayHours: Double((values["WORKDAY_HOURS"] ?? "8").replacingOccurrences(of: ",", with: ".")) ?? 8,
      claudeIntegrationEnabled: values["CLAUDE_ENABLED"] == "1",
      calendarIntegrationEnabled: values["CALENDAR_ENABLED"] == "1",
      calendarIdentifier: values["CALENDAR_ID"] ?? "",
      catchAllIssue: values["CATCH_ALL_ISSUE"] ?? "RPR-18"
    )
  }
}
