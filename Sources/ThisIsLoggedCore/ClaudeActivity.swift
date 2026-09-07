import Foundation
import SQLite3

public struct ActivityEvent: Sendable {
  public let id: String
  public let occurredAt: Date
  public let sessionID: String
  public let kind: String
  public let cwd: String
  public let branch: String?
  public let issueKey: String?
  public let text: String?
  public let toolName: String?
}

public struct ActivityAllocation: Codable, Equatable, Sendable {
  public let issueKey: String
  public let minutes: Int
  public let evidence: Int

  public init(issueKey: String, minutes: Int, evidence: Int) {
    self.issueKey = issueKey
    self.minutes = minutes
    self.evidence = evidence
  }
}

public struct DailyActivity: Sendable {
  public let day: String
  public let events: [ActivityEvent]
  public let allocations: [ActivityAllocation]
  public let observedMinutes: Int
  public let inferredMinutes: Int

  public init(
    day: String,
    events: [ActivityEvent],
    allocations: [ActivityAllocation],
    observedMinutes: Int? = nil,
    inferredMinutes: Int = 0
  ) {
    self.day = day
    self.events = events
    self.allocations = allocations
    self.observedMinutes = observedMinutes ?? allocations.reduce(0) { $0 + $1.minutes }
    self.inferredMinutes = inferredMinutes
  }
}

public struct HookCapture: Sendable {
  public let eventID: String
  public let eventName: String
  public let issueKey: String?
}

public enum ClaudeActivityError: LocalizedError {
  case invalidHook
  case database(String)
  case claudeMissing
  case claudeCommand(String)
  case invalidClaudeSettings

  public var errorDescription: String? {
    switch self {
    case .invalidHook: "Claude Code wysłał niepoprawne zdarzenie."
    case .database(let message): "Rejestr aktywności: \(message)"
    case .claudeMissing: "Nie znaleziono programu Claude Code."
    case .claudeCommand(let message): "Claude Code: \(message)"
    case .invalidClaudeSettings: "Plik ~/.claude/settings.json ma niepoprawny format; nie został zmieniony."
    }
  }
}

public final class ActivityStore: @unchecked Sendable {
  public static let defaultFile = SettingsStore.defaultDirectory.appendingPathComponent("activity.sqlite")
  fileprivate static let capturedEventNames: Set<String> = ["UserPromptSubmit", "Stop"]
  private static let discardedIssue = "__IGNORED__"

  private let file: URL

  public init(file: URL = ActivityStore.defaultFile) { self.file = file }

  @discardableResult
  public func recordClaudeHook(_ data: Data, now: Date = Date()) throws -> HookCapture {
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let eventName = payload["hook_event_name"] as? String,
          let sessionID = payload["session_id"] as? String else { throw ClaudeActivityError.invalidHook }
    guard Self.capturedEventNames.contains(eventName) else {
      return HookCapture(eventID: "", eventName: eventName, issueKey: nil)
    }
    let cwd = payload["cwd"] as? String ?? ""
    let text = (payload["prompt"] as? String).map { String($0.prefix(1_000)) }
    let branch = eventName == "UserPromptSubmit" ? Self.gitBranch(at: cwd) : nil
    let issue = Self.issueKey(in: branch) ?? (eventName == "UserPromptSubmit" ? Self.issueKey(in: text) : nil)
    let id = UUID().uuidString

    try withDatabase { database in
      let sql = """
        INSERT INTO activity_events
          (id, occurred_at, session_id, kind, cwd, branch, issue_key, text, payload)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, '{}')
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError(database) }
      defer { sqlite3_finalize(statement) }
      bind(id, to: statement, at: 1)
      sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
      bind(sessionID, to: statement, at: 3)
      bind(eventName, to: statement, at: 4)
      bind(cwd, to: statement, at: 5)
      bind(branch, to: statement, at: 6)
      bind(issue, to: statement, at: 7)
      bind(text, to: statement, at: 8)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
      guard sqlite3_exec(database, "DELETE FROM activity_events WHERE occurred_at < strftime('%s','now','-31 days')", nil, nil, nil) == SQLITE_OK else {
        throw databaseError(database)
      }
    }
    return HookCapture(eventID: id, eventName: eventName, issueKey: issue)
  }

  public func discard(eventID: String) throws -> Bool {
    guard UUID(uuidString: eventID) != nil else { throw ClaudeActivityError.invalidHook }
    return try withDatabase { database in
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, "UPDATE activity_events SET issue_key = ?, text = NULL WHERE id = ? AND kind = 'UserPromptSubmit'", -1, &statement, nil) == SQLITE_OK else {
        throw databaseError(database)
      }
      defer { sqlite3_finalize(statement) }
      bind(Self.discardedIssue, to: statement, at: 1)
      bind(eventID, to: statement, at: 2)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError(database) }
      return sqlite3_changes(database) == 1
    }
  }

  public func suggest(eventIDs: [String], issueKey: String, summary: String = "", confidence: Double = 1) throws {
    let issue = issueKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !eventIDs.isEmpty,
          issue.range(of: #"^[A-Z][A-Z0-9]*-\d+$"#, options: .regularExpression) != nil else {
      throw ClaudeActivityError.invalidHook
    }
    try withDatabase { database in
      let sql = "INSERT INTO activity_attributions (id, event_id, occurred_at, issue_key, summary, confidence) VALUES (?, ?, ?, ?, ?, ?)"
      for eventID in eventIDs {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError(database) }
        bind(UUID().uuidString, to: statement, at: 1)
        bind(eventID, to: statement, at: 2)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        bind(issue, to: statement, at: 4)
        bind(summary, to: statement, at: 5)
        sqlite3_bind_double(statement, 6, max(0, min(1, confidence)))
        let result = sqlite3_step(statement)
        sqlite3_finalize(statement)
        guard result == SQLITE_DONE else { throw databaseError(database) }
      }
    }
  }

  public func activity(on date: Date = Date(), now: Date = Date(), targetMinutes: Int? = nil) throws -> DailyActivity {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: date)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: start)!
    let end = min(dayEnd, max(start, now))
    let events = try events(from: start, to: end)
    let prompts = events.filter { $0.kind == "UserPromptSubmit" }
    var seconds: [String: Double] = [:]

    for (index, prompt) in prompts.enumerated() {
      let nextPrompt = prompts.indices.contains(index + 1) ? prompts[index + 1].occurredAt : end
      let finish = min(nextPrompt, prompt.occurredAt.addingTimeInterval(30 * 60))
      let duration = max(0, finish.timeIntervalSince(prompt.occurredAt))
      let issue = prompt.issueKey ?? "Nieprzypisane"
      if issue != Self.discardedIssue { seconds[issue, default: 0] += duration }
    }

    let trackedSeconds = seconds.values.reduce(0, +)
    let observedUnits = trackedSeconds > 0 ? max(1, Int((trackedSeconds / 300).rounded())) : 0
    let requestedUnits = targetMinutes.map { Int((Double(max(0, $0)) / 5).rounded()) } ?? observedUnits
    let canInfer = seconds.keys.contains { $0 != "Nieprzypisane" }
    let trackedUnits = canInfer ? max(observedUnits, requestedUnits) : observedUnits
    var units: [String: Int] = [:]
    if trackedUnits > 0, trackedSeconds > 0 {
      let shares = seconds.map { (key: $0.key, exact: $0.value / trackedSeconds * Double(trackedUnits)) }
      for share in shares { units[share.key] = Int(floor(share.exact)) }
      var left = trackedUnits - units.values.reduce(0, +)
      for share in shares.sorted(by: { ($0.exact - floor($0.exact)) > ($1.exact - floor($1.exact)) }) where left > 0 {
        units[share.key, default: 0] += 1
        left -= 1
      }
    }
    let allocations = units.filter { $0.value > 0 }.map { key, value in
      ActivityAllocation(issueKey: key, minutes: value * 5, evidence: prompts.filter { ($0.issueKey ?? "Nieprzypisane") == key }.count)
    }.sorted { left, right in
      if left.issueKey == "Nieprzypisane" { return false }
      if right.issueKey == "Nieprzypisane" { return true }
      return left.minutes == right.minutes ? left.issueKey < right.issueKey : left.minutes > right.minutes
    }
    return DailyActivity(
      day: Self.dayFormatter.string(from: start),
      events: events.filter { $0.issueKey != Self.discardedIssue },
      allocations: allocations,
      observedMinutes: observedUnits * 5,
      inferredMinutes: (trackedUnits - observedUnits) * 5
    )
  }

  private func events(from start: Date, to end: Date) throws -> [ActivityEvent] {
    try withDatabase { database in
      let sql = """
        SELECT e.id, e.occurred_at, e.session_id, e.kind, e.cwd, e.branch,
          COALESCE((SELECT a.issue_key FROM activity_attributions a WHERE a.event_id = e.id ORDER BY a.occurred_at DESC LIMIT 1), e.issue_key),
          e.text, e.tool_name
        FROM activity_events e
        WHERE e.occurred_at >= ? AND e.occurred_at < ? AND e.kind IN ('UserPromptSubmit', 'Stop')
        ORDER BY e.occurred_at
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError(database) }
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
      sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
      var result: [ActivityEvent] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(ActivityEvent(
          id: string(statement, 0) ?? "",
          occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
          sessionID: string(statement, 2) ?? "",
          kind: string(statement, 3) ?? "",
          cwd: string(statement, 4) ?? "",
          branch: string(statement, 5),
          issueKey: string(statement, 6),
          text: string(statement, 7),
          toolName: string(statement, 8)
        ))
      }
      return result
    }
  }

  private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
          let database else { throw ClaudeActivityError.database("nie można otworzyć bazy") }
    defer {
      sqlite3_close(database)
      for suffix in ["", "-wal", "-shm"] {
        let path = file.path + suffix
        if FileManager.default.fileExists(atPath: path) {
          try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
      }
    }
    sqlite3_busy_timeout(database, 5_000)
    guard sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;", nil, nil, nil) == SQLITE_OK,
          sqlite3_exec(database, Self.schema, nil, nil, nil) == SQLITE_OK else { throw databaseError(database) }
    try migrate(database)
    return try body(database)
  }

  private func migrate(_ database: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { throw databaseError(database) }
    guard sqlite3_step(statement) == SQLITE_ROW else { sqlite3_finalize(statement); throw databaseError(database) }
    let version = sqlite3_column_int(statement, 0)
    sqlite3_finalize(statement)
    guard version < 1 else { return }
    let cleanup = """
      DELETE FROM activity_events WHERE kind NOT IN ('UserPromptSubmit', 'Stop');
      UPDATE activity_events SET payload = '{}', text = substr(text, 1, 1000);
      VACUUM;
      PRAGMA user_version = 1;
      """
    guard sqlite3_exec(database, cleanup, nil, nil, nil) == SQLITE_OK else { throw databaseError(database) }
  }

  private static let schema = """
    CREATE TABLE IF NOT EXISTS activity_events (
      id TEXT PRIMARY KEY, occurred_at REAL NOT NULL, session_id TEXT NOT NULL, kind TEXT NOT NULL,
      cwd TEXT NOT NULL, branch TEXT, issue_key TEXT, text TEXT, tool_name TEXT, payload TEXT NOT NULL,
      message_key TEXT UNIQUE
    );
    CREATE INDEX IF NOT EXISTS activity_events_time ON activity_events(occurred_at);
    CREATE TABLE IF NOT EXISTS activity_attributions (
      id TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES activity_events(id) ON DELETE CASCADE,
      occurred_at REAL NOT NULL, issue_key TEXT NOT NULL, summary TEXT NOT NULL, confidence REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS activity_attributions_event ON activity_attributions(event_id, occurred_at);
    """

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  public static func issueKey(in value: String?) -> String? {
    guard let value,
          let range = value.range(of: #"(?<![A-Z0-9])[A-Z][A-Z0-9]+-\d+(?!\d)"#, options: .regularExpression) else { return nil }
    return String(value[range]).uppercased()
  }

  private static func gitBranch(at cwd: String) -> String? {
    guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd, "branch", "--show-current"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let branch = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return branch?.isEmpty == false ? branch : nil
  }

  private func databaseError(_ database: OpaquePointer) -> ClaudeActivityError {
    .database(String(cString: sqlite3_errmsg(database)))
  }

  private func bind(_ value: String?, to statement: OpaquePointer?, at index: Int32) {
    guard let value else { sqlite3_bind_null(statement, index); return }
    sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  }

  private func string(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: value)
  }
}

public struct ClaudeMCPServer: Sendable {
  private let store: ActivityStore

  public init(store: ActivityStore = ActivityStore()) { self.store = store }

  public func run() -> Never {
    while let line = readLine() {
      guard let data = line.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let response = response(to: request),
            let output = try? JSONSerialization.data(withJSONObject: response),
            let text = String(data: output, encoding: .utf8) else { continue }
      print(text)
      fflush(stdout)
    }
    exit(0)
  }

  public func response(to request: [String: Any]) -> [String: Any]? {
    let id = request["id"]
    guard let method = request["method"] as? String else { return error(id: id, code: -32600, message: "Invalid request") }
    if id == nil { return nil }
    do {
      let result: Any
      switch method {
      case "initialize":
        let params = request["params"] as? [String: Any]
        result = [
          "protocolVersion": params?["protocolVersion"] as? String ?? "2024-11-05",
          "capabilities": ["tools": [:]],
          "serverInfo": ["name": "this-is-logged", "version": "1.0"],
          "instructions": "Classify only the current event when the hook asks. Discard noise, save confident Jira attribution, never fetch a whole day unless the user asks, and never write Jira worklogs.",
        ]
      case "ping": result = [:]
      case "tools/list": result = ["tools": Self.tools]
      case "tools/call": result = try callTool(request["params"] as? [String: Any] ?? [:])
      default: return error(id: id, code: -32601, message: "Method not found")
      }
      return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    } catch let failure {
      return error(id: id, code: -32603, message: failure.localizedDescription)
    }
  }

  private func callTool(_ params: [String: Any]) throws -> [String: Any] {
    guard let name = params["name"] as? String else { throw ClaudeActivityError.invalidHook }
    let arguments = params["arguments"] as? [String: Any] ?? [:]
    switch name {
    case "get_activity":
      let day = try parseDay(arguments["date"] as? String)
      let activity = try store.activity(on: day)
      let limit = min(max(arguments["limit"] as? Int ?? 20, 1), 50)
      let entries = activity.events.suffix(limit).map { event in
        [
          "id": event.id, "at": ISO8601DateFormatter().string(from: event.occurredAt), "kind": event.kind,
          "cwd": event.cwd, "branch": event.branch ?? NSNull(), "issue_key": event.issueKey ?? NSNull(),
          "text": event.text.map { String($0.prefix(500)) } ?? NSNull(),
        ] as [String: Any]
      }
      return toolResult(["date": activity.day, "events": entries])
    case "discard_event":
      guard let eventID = arguments["event_id"] as? String else { throw ClaudeActivityError.invalidHook }
      return toolResult(["discarded": try store.discard(eventID: eventID)])
    case "suggest_attribution":
      guard let ids = arguments["event_ids"] as? [String], let issue = arguments["issue_key"] as? String else {
        throw ClaudeActivityError.invalidHook
      }
      try store.suggest(
        eventIDs: ids,
        issueKey: issue,
        summary: arguments["summary"] as? String ?? "",
        confidence: arguments["confidence"] as? Double ?? 1
      )
      return toolResult(["saved": ids.count, "issue_key": issue.uppercased()])
    case "review_day":
      let day = try parseDay(arguments["date"] as? String)
      let activity = try store.activity(on: day, targetMinutes: arguments["target_minutes"] as? Int)
      let allocations = activity.allocations.map {
        ["issue_key": $0.issueKey, "minutes": $0.minutes, "evidence": $0.evidence]
      }
      return toolResult([
        "date": activity.day, "allocations": allocations,
        "observed_minutes": activity.observedMinutes, "inferred_minutes": activity.inferredMinutes,
        "total_minutes": activity.allocations.reduce(0) { $0 + $1.minutes },
      ])
    default:
      return ["isError": true, "content": [["type": "text", "text": "Unknown tool: \(name)"]]]
    }
  }

  private func parseDay(_ value: String?) throws -> Date {
    guard let value else { return Date() }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value) else { throw ClaudeActivityError.invalidHook }
    return date
  }

  private func toolResult(_ value: Any) -> [String: Any] {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    return ["content": [["type": "text", "text": String(data: data, encoding: .utf8)!]], "structuredContent": value]
  }

  private func error(id: Any?, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
  }

  private static var tools: [[String: Any]] { [
    [
      "name": "get_activity", "description": "Read a small recent slice of locally captured Claude Code prompts and stop markers.",
      "inputSchema": ["type": "object", "properties": [
        "date": ["type": "string", "description": "Local date YYYY-MM-DD"],
        "limit": ["type": "integer", "minimum": 1, "maximum": 50],
      ]],
    ],
    [
      "name": "discard_event", "description": "Remove the current prompt content from analysis while retaining only its timestamp as a time boundary.",
      "inputSchema": ["type": "object", "properties": [
        "event_id": ["type": "string"],
      ], "required": ["event_id"]],
    ],
    [
      "name": "suggest_attribution", "description": "Attribute captured activity events to a Jira issue. UserPromptSubmit event IDs affect the time proposal; this only saves a local suggestion.",
      "inputSchema": ["type": "object", "properties": [
        "event_ids": ["type": "array", "items": ["type": "string"]],
        "issue_key": ["type": "string"], "summary": ["type": "string"],
        "confidence": ["type": "number", "minimum": 0, "maximum": 1],
      ], "required": ["event_ids", "issue_key"]],
    ],
    [
      "name": "review_day", "description": "Build a central 5-minute estimate from observed activity across all Claude Code worktrees.",
      "inputSchema": ["type": "object", "properties": [
        "date": ["type": "string", "description": "Local date YYYY-MM-DD"],
        "target_minutes": ["type": "integer", "minimum": 0],
      ]],
    ],
  ] }
}

public struct ClaudeCodeIntegration: Sendable {
  public static let serverName = "this-is-logged"
  private let home: URL

  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

  public func reconcile(enabled: Bool, executable: URL) throws {
    if enabled { try install(executable: executable) } else { try uninstall() }
  }

  public func install(executable: URL) throws {
    guard let claude = claudeExecutable() else { throw ClaudeActivityError.claudeMissing }
    _ = try? run(claude, ["mcp", "remove", "--scope", "user", Self.serverName])
    try run(claude, ["mcp", "add", "--scope", "user", "--transport", "stdio", Self.serverName, "--", executable.path, "--mcp"])
    do {
      try updateHooks(command: "\(Self.shellQuote(executable.path)) --ingest-claude-hook", enabled: true)
    } catch {
      _ = try? run(claude, ["mcp", "remove", "--scope", "user", Self.serverName])
      throw error
    }
  }

  public func uninstall() throws {
    try updateHooks(command: "", enabled: false)
    if let claude = claudeExecutable() { _ = try? run(claude, ["mcp", "remove", "--scope", "user", Self.serverName]) }
  }

  public func hooksSettings(from existing: [String: Any], command: String, enabled: Bool) -> [String: Any] {
    var settings = existing
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for event in Self.managedEvents {
      let groups = hooks[event] as? [[String: Any]] ?? []
      let cleaned = groups.compactMap { group -> [String: Any]? in
        var group = group
        let commands = (group["hooks"] as? [[String: Any]] ?? []).filter {
          !(($0["command"] as? String)?.contains("--ingest-claude-hook") ?? false)
        }
        guard !commands.isEmpty else { return nil }
        group["hooks"] = commands
        return group
      }
      let updated = enabled && ActivityStore.capturedEventNames.contains(event) ? cleaned + [[
        "matcher": "",
        "hooks": [["type": "command", "command": command, "timeout": 10, "async": event != "UserPromptSubmit"]],
      ]] : cleaned
      if updated.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = updated }
    }
    if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
    var permissions = settings["permissions"] as? [String: Any] ?? [:]
    var allow = (permissions["allow"] as? [String] ?? []).filter { !Self.permissionRules.contains($0) }
    if enabled { allow += Self.permissionRules }
    if allow.isEmpty { permissions.removeValue(forKey: "allow") } else { permissions["allow"] = allow }
    if permissions.isEmpty { settings.removeValue(forKey: "permissions") } else { settings["permissions"] = permissions }
    return settings
  }

  private func updateHooks(command: String, enabled: Bool) throws {
    let file = home.appendingPathComponent(".claude/settings.json")
    if !enabled, !FileManager.default.fileExists(atPath: file.path) { return }
    if !enabled, let text = try? String(contentsOf: file, encoding: .utf8),
       !text.contains("--ingest-claude-hook"), !Self.permissionRules.contains(where: text.contains) { return }
    let existing: [String: Any]
    if FileManager.default.fileExists(atPath: file.path) {
      let data = try Data(contentsOf: file)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["hooks"] == nil || object["hooks"] is [String: Any],
            object["permissions"] == nil || object["permissions"] is [String: Any]
      else { throw ClaudeActivityError.invalidClaudeSettings }
      let hooks = object["hooks"] as? [String: Any] ?? [:]
      guard Self.managedEvents.allSatisfy({ hooks[$0] == nil || hooks[$0] is [[String: Any]] }) else {
        throw ClaudeActivityError.invalidClaudeSettings
      }
      let permissions = object["permissions"] as? [String: Any] ?? [:]
      guard permissions["allow"] == nil || permissions["allow"] is [String] else {
        throw ClaudeActivityError.invalidClaudeSettings
      }
      existing = object
    } else {
      existing = [:]
    }
    let updated = hooksSettings(from: existing, command: command, enabled: enabled)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: file, options: .atomic)
  }

  private func claudeExecutable() -> URL? {
    let candidates = [
      home.appendingPathComponent(".local/bin/claude"),
      home.appendingPathComponent(".claude/local/claude"),
      URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
      URL(fileURLWithPath: "/usr/local/bin/claude"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  @discardableResult
  private func run(_ executable: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw ClaudeActivityError.claudeCommand(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return text
  }

  private static let managedEvents = [
    "SessionStart", "UserPromptSubmit", "MessageDisplay", "PostToolUse", "Stop",
    "SubagentStart", "SubagentStop", "SessionEnd", "CwdChanged", "WorktreeCreate", "WorktreeRemove",
  ]
  private static let permissionRules = [
    "mcp__this-is-logged__get_activity",
    "mcp__this-is-logged__discard_event",
    "mcp__this-is-logged__suggest_attribution",
    "mcp__this-is-logged__review_day",
  ]

  private static func shellQuote(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }
}
