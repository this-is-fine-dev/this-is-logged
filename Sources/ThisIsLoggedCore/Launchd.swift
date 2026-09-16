import Darwin
import Foundation

public final class LaunchdManager: @unchecked Sendable {
  public static let labels = (
    menu: "dev.this-is-fine.this-is-logged.menu",
    reminder: "dev.this-is-fine.this-is-logged.reminder",
    status: "dev.this-is-fine.this-is-logged.status",
    sync: "dev.this-is-fine.this-is-logged.sync"
  )

  private let home: URL

  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.home = home
  }

  public static var synchronizationSchedule: [String: Any] {
    ["RunAtLoad": true, "StartCalendarInterval": stride(from: 0, to: 60, by: 5).map { ["Minute": $0] }]
  }

  public func synchronizationScheduleInstalled() -> Bool {
    let file = home.appendingPathComponent("Library/LaunchAgents/\(Self.labels.sync).plist")
    guard let data = try? Data(contentsOf: file),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
    return Self.synchronizationSchedule.allSatisfy { key, value in
      (plist[key] as? NSObject)?.isEqual(value) == true
    }
  }

  public func reconcile(settings: AppSettings, executable: URL, app: URL) throws {
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    let logs = home.appendingPathComponent("Library/Logs", isDirectory: true)
    let support = home.appendingPathComponent("Library/Application Support/this-is-logged", isDirectory: true)
    try [agents, logs, support].forEach { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }

    let log: (String) -> URL = { suffix in
      logs.appendingPathComponent("this-is-logged\(suffix.isEmpty ? "" : "-\(suffix)").log")
    }
    for url in [log(""), log("menu"), log("reminder"), log("status")] {
      if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    let labels = Self.labels
    let plists = [
      "menu": agents.appendingPathComponent("\(labels.menu).plist"),
      "reminder": agents.appendingPathComponent("\(labels.reminder).plist"),
      "status": agents.appendingPathComponent("\(labels.status).plist"),
      "sync": agents.appendingPathComponent("\(labels.sync).plist"),
    ]
    let backend: ([String], URL) -> [String: Any] = { arguments, output in
      [
        "ProgramArguments": [executable.path] + arguments,
        "WorkingDirectory": executable.deletingLastPathComponent().path,
        "StandardOutPath": output.path,
        "StandardErrorPath": output.path,
      ]
    }
    let reminder = try clock(settings.reminderTime)
    var reminderPlist: [String: Any] = [
      "Label": labels.reminder,
      "StartCalendarInterval": (1...5).map { ["Weekday": $0, "Hour": reminder.hour, "Minute": reminder.minute] },
    ]
    reminderPlist.merge(backend(["--agent-reminder"], log("reminder"))) { current, _ in current }
    var statusPlist: [String: Any] = ["Label": labels.status, "RunAtLoad": true, "StartInterval": 60]
    statusPlist.merge(backend(["--agent-status"], log("status"))) { current, _ in current }
    let menuPlist: [String: Any] = [
      "Label": labels.menu,
      "ProgramArguments": ["/usr/bin/open", "-g", app.path],
      "RunAtLoad": true,
      "StandardOutPath": log("menu").path,
      "StandardErrorPath": log("menu").path,
    ]

    try write(menuPlist, to: plists["menu"]!)
    try write(reminderPlist, to: plists["reminder"]!)
    try write(statusPlist, to: plists["status"]!)
    if settings.synchronizationEnabled {
      var syncPlist: [String: Any] = [
        "Label": labels.sync,
      ]
      syncPlist.merge(Self.synchronizationSchedule) { _, policy in policy }
      syncPlist.merge(backend(["--agent-sync"], log(""))) { current, _ in current }
      try write(syncPlist, to: plists["sync"]!)
    } else {
      try? FileManager.default.removeItem(at: plists["sync"]!)
    }

    let domain = "gui/\(getuid())"
    for label in [labels.menu, labels.reminder, labels.status, labels.sync] {
      _ = try? launchctl(["bootout", "\(domain)/\(label)"])
    }
    for key in ["reminder", "status"] + (settings.synchronizationEnabled ? ["sync"] : []) + ["menu"] {
      _ = try? launchctl(["enable", "\(domain)/\(plists[key]!.deletingPathExtension().lastPathComponent)"])
      try launchctl(["bootstrap", domain, plists[key]!.path])
    }
    try launchctl(["kickstart", "\(domain)/\(labels.status)"])
  }

  private func clock(_ value: String) throws -> (hour: Int, minute: Int) {
    let parts = value.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { throw SettingsError.invalidSchedule }
    return (parts[0], parts[1])
  }

  private func write(_ value: [String: Any], to file: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    try data.write(to: file, options: .atomic)
  }

  @discardableResult
  private func launchctl(_ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "ThisIsLogged", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "launchctl zakończył się błędem" : message])
    }
    return message
  }
}
