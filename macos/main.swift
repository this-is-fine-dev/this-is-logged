import AppKit
import Darwin
import Foundation
import Sparkle
import ThisIsLoggedCore
@preconcurrency import UserNotifications

private let collisionCategory = "THIS_IS_LOGGED_COLLISION"
private let resolveCollisionsAction = "RESOLVE_COLLISIONS"
private let activityCategory = "THIS_IS_LOGGED_ACTIVITY"
private let openActivityAction = "OPEN_ACTIVITY"
private let logURL = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Logs/this-is-logged.log")
private let statusLogURL = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Logs/this-is-logged-status.log")
private let environment = ProcessInfo.processInfo.environment
private let reportStatusURL = URL(fileURLWithPath: environment["THIS_IS_LOGGED_STATUS"]
  ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/this-is-logged/status.json").path)
private let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
private let syncLabel = "dev.this-is-fine.this-is-logged.sync"
private let reminderLabel = "dev.this-is-fine.this-is-logged.reminder"
private let statusLabel = "dev.this-is-fine.this-is-logged.status"
private let configURL: URL = {
  if let configured = environment["THIS_IS_LOGGED_ENV"] { return URL(fileURLWithPath: configured) }
  let home = FileManager.default.homeDirectoryForCurrentUser
  let current = home.appendingPathComponent(".this-is-logged.env")
  let legacy = home.appendingPathComponent(".jira-time-copy.env")
  if !FileManager.default.fileExists(atPath: current.path), FileManager.default.fileExists(atPath: legacy.path) {
    try? FileManager.default.moveItem(at: legacy, to: current)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
  }
  return current
}()
private final class BoolBox: @unchecked Sendable { var value = false }

private let textEditingCommands: [(title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags)] = [
  ("Cofnij", Selector(("undo:")), "z", .command),
  ("Ponów", Selector(("redo:")), "z", [.command, .shift]),
  ("Wytnij", #selector(NSText.cut(_:)), "x", .command),
  ("Kopiuj", #selector(NSText.copy(_:)), "c", .command),
  ("Wklej", #selector(NSText.paste(_:)), "v", .command),
  ("Zaznacz wszystko", #selector(NSText.selectAll(_:)), "a", .command),
]

@MainActor private func makeTextEditingMenu() -> NSMenu {
  let menu = NSMenu(title: "Edycja")
  for (index, command) in textEditingCommands.enumerated() {
    if index == 2 { menu.addItem(.separator()) }
    let item = menu.addItem(withTitle: command.title, action: command.action, keyEquivalent: command.key)
    item.keyEquivalentModifierMask = command.modifiers
  }
  return menu
}

@MainActor private func makeMainMenu() -> NSMenu {
  let main = NSMenu()
  let applicationItem = NSMenuItem()
  let applicationMenu = NSMenu()
  applicationMenu.addItem(withTitle: "Zakończ This Is Logged", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  applicationItem.submenu = applicationMenu
  main.addItem(applicationItem)
  let editItem = NSMenuItem()
  editItem.submenu = makeTextEditingMenu()
  main.addItem(editItem)
  return main
}

private func registerNotificationCategories(_ center: UNUserNotificationCenter) {
  center.setNotificationCategories([
    UNNotificationCategory(
      identifier: collisionCategory,
      actions: [
        UNNotificationAction(identifier: resolveCollisionsAction, title: "Rozwiąż…", options: [.foreground]),
        UNNotificationAction(identifier: "IGNORE_COLLISIONS", title: "Pomiń", options: []),
      ],
      intentIdentifiers: []
    ),
    UNNotificationCategory(
      identifier: activityCategory,
      actions: [UNNotificationAction(identifier: openActivityAction, title: "Otwórz analizę", options: [.foreground])],
      intentIdentifiers: []
    ),
  ])
}

private func deliverNotification(_ body: String, category: String? = nil) -> Bool {
  let center = UNUserNotificationCenter.current()
  registerNotificationCategories(center)
  let done = DispatchSemaphore(value: 0)
  let delivered = BoolBox()
  center.requestAuthorization(options: [.alert, .sound]) { granted, error in
    if let error { fputs("notification authorization: \(error)\n", stderr) }
    guard granted else {
      fputs("notification authorization: denied\n", stderr)
      done.signal()
      return
    }
    let content = UNMutableNotificationContent()
    content.title = "This Is Logged"
    content.body = body
    content.sound = .default
    if let category { content.categoryIdentifier = category }
    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
      if let error { fputs("notification delivery: \(error)\n", stderr) }
      delivered.value = error == nil
      done.signal()
    }
  }
  return done.wait(timeout: .now() + 15) == .success && delivered.value
}

private func persistentNotificationsEnabled() -> Bool {
  let done = DispatchSemaphore(value: 0)
  let enabled = BoolBox()
  UNUserNotificationCenter.current().getNotificationSettings { settings in
    enabled.value = settings.authorizationStatus == .authorized && settings.alertStyle == .alert
    fputs("notification settings: authorization=\(settings.authorizationStatus.rawValue), alertStyle=\(settings.alertStyle.rawValue)\n", stderr)
    done.signal()
  }
  return done.wait(timeout: .now() + 15) == .success && enabled.value
}

private struct Run {
  let date: Date
  var hours: Double?
  var collisions = 0
  var error: String?
}

private struct ReportStatus: Decodable {
  let backend: String?
  let checkedAt: String
  let lastSuccessfulAt: String?
  let syncEnabled: Bool?
  let seconds: Int?
  let expectedSeconds: Int?
  let error: String?
  let targetError: String?
  let today: PeriodStatus?
  let yesterday: PeriodStatus?
  let week: PeriodStatus?
  let month: PeriodStatus?
  let monthCapacity: MonthCapacity?
}

private struct PeriodStatus: Decodable {
  let from: String
  let to: String
  let workingDays: Int
  let sourceSeconds: Int
  let targetSeconds: Int?
  let missing: [MissingDay]
  let differences: [Difference]?
}

private struct MissingDay: Decodable {
  let date: String
  let sourceSeconds: Int
}

private struct Difference: Decodable {
  let date: String
  let sourceSeconds: Int
  let targetSeconds: Int
}

private struct MonthCapacity: Decodable {
  let workingDays: Int
  let daysOff: Int
  let expectedSeconds: Int
  let reportedSeconds: Int?
}

private func currentToday(_ status: ReportStatus?, on day: LocalDay) -> PeriodStatus? {
  guard let today = status?.today, today.from == day.description, today.to == day.description else { return nil }
  return today
}

private func dayLabel(_ day: LocalDay) -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "pl_PL")
  formatter.dateFormat = "EEEE, d MMMM"
  let value = formatter.string(from: day.date)
  return value.prefix(1).uppercased(with: formatter.locale) + value.dropFirst()
}

private func parseLog(_ text: String) -> [Run] {
  let iso = ISO8601DateFormatter()
  iso.formatOptions.insert(.withFractionalSeconds)
  var runs: [Run] = []
  var current: Run?

  for part in text.split(separator: "\n", omittingEmptySubsequences: false) {
    let line = String(part)
    if line.hasPrefix("--- "), line.hasSuffix(" ---"),
       let date = iso.date(from: String(line.dropFirst(4).dropLast(4))) {
      if let current { runs.append(current) }
      current = Run(date: date)
    } else if line.contains("KOLIZJA:") {
      current?.collisions += 1
    } else if line.hasPrefix("niepowodzenie: ") {
      current?.error = String(line.dropFirst("niepowodzenie: ".count))
    } else if line.hasPrefix("zapisano: ") {
      current?.hours = Double(line.dropFirst(10).prefix { $0.isNumber || $0 == "." })
    }
  }
  if let current { runs.append(current) }
  return runs
}

private func clockParts(_ value: String) -> (hour: Int, minute: Int)? {
  let parts = value.split(separator: ":", omittingEmptySubsequences: false)
  guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
        let hour = Int(parts[0]), let minute = Int(parts[1]),
        (0...23).contains(hour), (0...59).contains(minute) else { return nil }
  return (hour, minute)
}

private func menuIcon() -> NSImage? {
  guard let iconURL, let image = NSImage(contentsOf: iconURL) else { return nil }
  image.size = NSSize(width: 22, height: 22)
  image.isTemplate = false
  return image
}

private let weekendMessages = ["nadgodzinki?", "nie tyraj tyle", "jebać biedę?", "samo się nie zrobi"]
private let morningMessages = ["daj pospać", "Jira też śpi", "najpierw kawusia", "od ósmej, szefie"]
private let noDataMessages = ["Jira śpi?", "cisza w eterze", "brak meldunku", "gdzie VPN?"]

private func weekendMessage(day: Int) -> String { weekendMessages[day % weekendMessages.count] }
private func noDataMessage(day: Int, hour: Int, missingDays: Int) -> String {
  let messages = hour < 8 ? morningMessages : noDataMessages
  return missingDays == 0 ? " \(messages[day % messages.count])" : " braki: \(missingDays)"
}

private func statusBarTitle(seconds: Int, weekendText: String?, missingDays: Int, day: Int, hour: Int) -> String {
  if let weekendText { return missingDays == 0 ? " \(weekendText)" : " braki: \(missingDays)" }
  if seconds == 0, hour < 8 { return noDataMessage(day: day, hour: hour, missingDays: missingDays) }
  return " \(nativeHours(seconds)) h"
}

private func completedPeriod(_ period: PeriodStatus?, including day: PeriodStatus?, includeDay: Bool) -> PeriodStatus? {
  guard includeDay, let period, let day, day.workingDays > 0, day.from > period.to else { return period }
  return PeriodStatus(
    from: period.from,
    to: day.to,
    workingDays: period.workingDays + day.workingDays,
    sourceSeconds: period.sourceSeconds + day.sourceSeconds,
    targetSeconds: period.targetSeconds.flatMap { left in day.targetSeconds.map { left + $0 } },
    missing: period.missing + day.missing,
    differences: period.differences.flatMap { left in day.differences.map { left + $0 } }
  )
}

private func weekdayLabel(_ value: String) -> String {
  guard let day = LocalDay(value) else { return "Ostatni dzień pracy" }
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "pl_PL")
  formatter.dateFormat = "EEEE"
  return formatter.string(from: day.date).capitalized(with: formatter.locale)
}

private func previousDayLabel(_ value: String, now: Date) -> String {
  guard let day = LocalDay(value) else { return "Ostatni dzień pracy" }
  return day == LocalDay(now).adding(days: -1) ? "Wczoraj" : weekdayLabel(value)
}

private func savedSetting(_ key: String, fallback: String) -> String {
  if arguments.contains(where: { $0.contains("selfcheck") }) { return fallback }
  return readSettings()[key] ?? fallback
}

private func readSettings() -> [String: String] {
  if let settings = try? SettingsStore().loadDraft() {
    return [
      "SRC_URL": settings.source.url.absoluteString,
      "SRC_EMAIL": settings.source.email,
      "SRC_TOKEN": settings.source.token,
      "SYNC_ENABLED": settings.synchronizationEnabled ? "1" : "0",
      "DST_URL": settings.target?.url.absoluteString ?? "",
      "DST_EMAIL": settings.target?.email ?? "",
      "DST_TOKEN": settings.target?.token ?? "",
      "DST_ISSUE": settings.targetIssue,
      "COMMENT_KEYS": settings.commentIssueKeys ? "1" : "0",
      "SYNC_TIME": settings.synchronizationTime,
      "REMINDER_TIME": settings.reminderTime,
      "WORKDAY_HOURS": String(settings.workdayHours),
      "CLAUDE_ENABLED": settings.claudeIntegrationEnabled ? "1" : "0",
      "CALENDAR_ENABLED": settings.calendarIntegrationEnabled ? "1" : "0",
      "CALENDAR_ID": settings.calendarIdentifier,
      "CATCH_ALL_ISSUE": settings.catchAllIssue,
    ]
  }
  guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [:] }
  var values: [String: String] = [:]
  for part in text.split(separator: "\n") {
    let line = String(part)
    guard !line.hasPrefix("#"), let split = line.firstIndex(of: "=") else { continue }
    values[String(line[..<split])] = String(line[line.index(after: split)...])
  }
  return values
}

private func normalizedURL(_ value: String) -> String {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return (trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
    ? trimmed : "https://" + trimmed).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
}

private func configurationComplete(_ values: [String: String]) -> Bool {
  guard !values["SRC_URL", default: ""].isEmpty, !values["SRC_TOKEN", default: ""].isEmpty else { return false }
  return values["SYNC_ENABLED"] != "1" || ["DST_URL", "DST_TOKEN", "DST_ISSUE"].allSatisfy { !values[$0, default: ""].isEmpty }
}

private func period(monthOffset: Int = 0) -> String {
  let date = Calendar.current.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM"
  return formatter.string(from: date)
}

private func todayPeriod() -> String {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter.string(from: Date())
}

@MainActor private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @preconcurrency UNUserNotificationCenterDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )
  private var updaterReadinessObservation: NSKeyValueObservation?
  private let headerMonthLabel = NSTextField(labelWithString: "")
  private let headerMonthValue = NSTextField(labelWithString: "—")
  private let headerMonthDetail = NSTextField(labelWithString: "Czekam na dane")
  private let headerTodayLabel = NSTextField(labelWithString: "DZISIAJ")
  private let headerTodayValue = NSTextField(labelWithString: "—")
  private let lastSyncStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let todayStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let yesterdayStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let weekStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let monthStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let reminderSchedule = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let syncSchedule = NSMenuItem(title: "", action: nil, keyEquivalent: "")
  private let historyMenu = NSMenu()
  private let sourceURLField = NSTextField(frame: .zero)
  private let sourceEmailField = NSTextField(frame: .zero)
  private let sourceTokenField = NSSecureTextField(frame: .zero)
  private let syncToggle = NSButton(checkboxWithTitle: "Synchronizuj raporty z drugą Jirą", target: nil, action: nil)
  private let targetURLField = NSTextField(frame: .zero)
  private let targetEmailField = NSTextField(frame: .zero)
  private let targetTokenField = NSSecureTextField(frame: .zero)
  private let targetIssueField = NSTextField(frame: .zero)
  private let commentKeysToggle = NSButton(checkboxWithTitle: "Dodawaj klucze zadań do komentarza", target: nil, action: nil)
  private let syncTimeField = NSTextField(frame: .zero)
  private let reminderTimeField = NSTextField(frame: .zero)
  private let workdayHoursField = NSTextField(frame: .zero)
  private let claudeToggle = NSButton(checkboxWithTitle: "Zbieraj aktywność z Claude Code", target: nil, action: nil)
  private let calendarToggle = NSButton(checkboxWithTitle: "Uwzględniaj spotkania z Kalendarza", target: nil, action: nil)
  private let calendarPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let catchAllIssueField = NSTextField(frame: .zero)
  private let settingsFeedback = NSTextField(labelWithString: " ")
  private let settingsProgress = NSProgressIndicator(frame: .zero)
  private var targetBox: NSBox!
  private var saveButton: NSButton!
  private var panel: NSPanel!
  private var syncWindow: SyncWindowController?
  private var activityWindow: ClaudeActivityWindowController?
  private var timer: Timer?
  private var lastStatusKick = Date.distantPast
  private lazy var normalMenuIcon = menuIcon()
  private var configuredSyncEnabled = savedSetting("SYNC_ENABLED", fallback: environment["THIS_IS_LOGGED_SYNC_ENABLED"] ?? "0") == "1"
  private var configuredSyncTime = savedSetting("SYNC_TIME", fallback: environment["THIS_IS_LOGGED_SCHEDULE"] ?? "23:00")
  private var configuredReminderTime = savedSetting("REMINDER_TIME", fallback: environment["THIS_IS_LOGGED_REMINDER"] ?? "16:00")
  private var configuredWorkdayHours = savedSetting("WORKDAY_HOURS", fallback: environment["THIS_IS_LOGGED_WORKDAY_HOURS"] ?? "8")
  private var configuredClaudeEnabled = savedSetting("CLAUDE_ENABLED", fallback: "0") == "1"
  private var configuredCalendarEnabled = savedSetting("CALENDAR_ENABLED", fallback: "0") == "1"

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMainMenu()
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    registerNotificationCategories(center)
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    setupMenu()
    setupSettingsPanel()
    refresh()
    installAgentsIfNeeded()
    refreshClaudeIntegrationIfNeeded()
    if arguments.contains("--show-panel") || !configurationComplete(readSettings()) { showSettings() }
    timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  private func setupMenu() {
    let menu = NSMenu()
    menu.delegate = self
    menu.minimumWidth = 410
    menu.addItem(makeHeader())
    menu.addItem(.separator())
    menu.addItem(sectionItem("RAPORTY"))
    for line in [todayStatus, yesterdayStatus, weekStatus, monthStatus] {
      line.submenu = NSMenu()
      menu.addItem(line)
    }
    menu.addItem(.separator())
    menu.addItem(sectionItem("MONITORING"))
    reminderSchedule.isEnabled = false
    menu.addItem(reminderSchedule)
    menu.addItem(actionItem("Odśwież dane", #selector(refreshReports), ""))

    if configuredSyncEnabled {
      menu.addItem(.separator())
      menu.addItem(sectionItem("SYNCHRONIZACJA"))
      lastSyncStatus.isEnabled = false
      menu.addItem(lastSyncStatus)
      syncSchedule.isEnabled = false
      menu.addItem(syncSchedule)
      menu.addItem(actionItem("Synchronizuj teraz", #selector(runNow), "r"))

      let interactive = NSMenu()
      for (title, value) in [
        (Calendar.current.isDateInWeekend(Date()) ? "Dzisiaj (dzień wolny)…" : "Dzisiaj…", todayPeriod()),
        ("Bieżący miesiąc…", period()),
        ("Poprzedni miesiąc…", period(monthOffset: -1)),
      ] {
        let option = actionItem(title, #selector(runInteractive(_:)), "")
        option.representedObject = value
        interactive.addItem(option)
      }
      let interactiveItem = NSMenuItem(title: "Synchronizacja interaktywna", action: nil, keyEquivalent: "")
      interactiveItem.submenu = interactive
      menu.addItem(interactiveItem)
      let historyItem = NSMenuItem(title: "Ostatnie synchronizacje", action: nil, keyEquivalent: "")
      historyItem.submenu = historyMenu
      menu.addItem(historyItem)
    }

    menu.addItem(.separator())
    menu.addItem(sectionItem("APLIKACJA"))
    if configuredClaudeEnabled || configuredCalendarEnabled {
      menu.addItem(actionItem("Analiza czasu…", #selector(showClaudeActivity), ""))
    }
    menu.addItem(actionItem("Ustawienia i połączenia…", #selector(showSettings), ","))
    let updateItem = NSMenuItem(
      title: "Sprawdź aktualizacje…",
      action: #selector(checkForUpdates(_:)),
      keyEquivalent: ""
    )
    updateItem.target = self
    menu.addItem(updateItem)
    menu.addItem(actionItem(configuredSyncEnabled ? "Otwórz log synchronizacji" : "Otwórz log monitoringu", #selector(openLog), "l"))
    menu.addItem(.separator())
    menu.addItem(actionItem("Zakończ", #selector(quit), "q"))
    item.menu = menu
    item.button?.imagePosition = .imageLeading
    item.button?.toolTip = "This Is Logged"
  }

  private func makeHeader() -> NSMenuItem {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 96))
    headerMonthLabel.font = .systemFont(ofSize: 10, weight: .semibold)
    headerMonthLabel.textColor = .secondaryLabelColor
    headerMonthValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    headerMonthValue.alignment = .right
    headerMonthDetail.font = .systemFont(ofSize: 11)
    headerMonthDetail.textColor = .secondaryLabelColor
    headerTodayLabel.font = .systemFont(ofSize: 10, weight: .semibold)
    headerTodayLabel.textColor = .secondaryLabelColor
    headerTodayValue.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)

    let monthRow = NSStackView(views: [headerMonthLabel, NSView(), headerMonthValue])
    monthRow.orientation = .horizontal
    monthRow.alignment = .centerY
    let content = NSStackView(views: [headerTodayLabel, headerTodayValue, monthRow, headerMonthDetail])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 3
    content.setCustomSpacing(9, after: headerTodayValue)
    content.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      content.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
      monthRow.widthAnchor.constraint(equalTo: content.widthAnchor),
    ])
    let menuItem = NSMenuItem()
    menuItem.view = view
    return menuItem
  }

  private func sectionItem(_ title: String) -> NSMenuItem {
    let menuItem = NSMenuItem()
    menuItem.attributedTitle = NSAttributedString(string: title, attributes: [
      .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
      .foregroundColor: NSColor.secondaryLabelColor,
    ])
    menuItem.isEnabled = false
    return menuItem
  }

  private func actionItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
    let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
    menuItem.target = self
    return menuItem
  }

  private func setupSettingsPanel() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 590, height: 850),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "This Is Logged"
    panel.toolbarStyle = .unifiedCompact
    panel.toolbar = NSToolbar(identifier: "settings")
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.center()

    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 12
    root.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView?.addSubview(root)
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 22),
      root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -22),
      root.topAnchor.constraint(equalTo: panel.contentView!.safeAreaLayoutGuide.topAnchor, constant: 18),
      root.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -18),
    ])

    let header = NSStackView()
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 10
    if let iconURL, let image = NSImage(contentsOf: iconURL) {
      let icon = NSImageView(image: image)
      icon.imageScaling = .scaleProportionallyUpOrDown
      icon.widthAnchor.constraint(equalToConstant: 38).isActive = true
      icon.heightAnchor.constraint(equalToConstant: 38).isActive = true
      header.addArrangedSubview(icon)
    }
    let heading = NSStackView()
    heading.orientation = .vertical
    heading.alignment = .leading
    heading.spacing = 1
    let title = NSTextField(labelWithString: "Konfiguracja")
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    let subtitle = NSTextField(labelWithString: "Monitoring jest zawsze aktywny. Druga Jira jest opcjonalna.")
    subtitle.textColor = .secondaryLabelColor
    heading.addArrangedSubview(title)
    heading.addArrangedSubview(subtitle)
    header.addArrangedSubview(heading)
    root.addArrangedSubview(header)

    for field in [sourceURLField, sourceEmailField, sourceTokenField, targetURLField, targetEmailField, targetTokenField, targetIssueField, catchAllIssueField] {
      field.widthAnchor.constraint(equalToConstant: 365).isActive = true
    }
    for field in [sourceURLField, sourceEmailField, sourceTokenField, targetURLField, targetEmailField, targetTokenField,
                  targetIssueField, syncTimeField, reminderTimeField, workdayHoursField, catchAllIssueField] {
      field.menu = makeTextEditingMenu()
    }
    sourceURLField.placeholderString = "https://firma.atlassian.net"
    sourceEmailField.placeholderString = "Wymagany dla Jira Cloud; pusty dla Server/DC"
    sourceTokenField.placeholderString = "API token lub Personal Access Token"
    targetURLField.placeholderString = "https://druga-firma.atlassian.net"
    targetEmailField.placeholderString = "Wymagany dla Jira Cloud; pusty dla Server/DC"
    targetTokenField.placeholderString = "API token lub Personal Access Token"
    targetIssueField.placeholderString = "AUT-123"
    catchAllIssueField.placeholderString = "RPR-18"
    root.addArrangedSubview(settingsBox("Jira główna", [
      ("URL", sourceURLField), ("Email", sourceEmailField), ("Token", sourceTokenField),
    ]))

    syncToggle.target = self
    syncToggle.action = #selector(toggleSynchronization)
    root.addArrangedSubview(syncToggle)
    syncTimeField.alignment = .center
    syncTimeField.widthAnchor.constraint(equalToConstant: 90).isActive = true
    targetBox = settingsBox("Jira docelowa", [
      ("URL", targetURLField), ("Email", targetEmailField), ("Token", targetTokenField),
      ("Zadanie", targetIssueField), ("Automatyczny zapis", syncTimeField), ("", commentKeysToggle),
    ])
    root.addArrangedSubview(targetBox)

    for field in [reminderTimeField, workdayHoursField] {
      field.alignment = .center
      field.widthAnchor.constraint(equalToConstant: 90).isActive = true
    }
    let hoursControl = NSStackView(views: [workdayHoursField, NSTextField(labelWithString: "h")])
    hoursControl.orientation = .horizontal
    hoursControl.spacing = 6
    root.addArrangedSubview(settingsBox("Monitoring", [
      ("Przypomnienie", reminderTimeField), ("Pełny dzień", hoursControl),
    ]))

    let claudeDescription = NSTextField(labelWithString: "Spotkania i rozmowy bez własnego zadania trafiają do zadania zbiorczego.")
    claudeDescription.textColor = .secondaryLabelColor
    claudeDescription.lineBreakMode = .byWordWrapping
    claudeDescription.maximumNumberOfLines = 2
    claudeDescription.widthAnchor.constraint(equalToConstant: 365).isActive = true
    calendarToggle.target = self
    calendarToggle.action = #selector(toggleCalendar)
    calendarPopup.widthAnchor.constraint(equalToConstant: 365).isActive = true
    root.addArrangedSubview(settingsBox("Analiza czasu", [
      ("", claudeToggle), ("", calendarToggle), ("Kalendarz", calendarPopup),
      ("Zadanie zbiorcze", catchAllIssueField), ("", claudeDescription),
    ]))

    settingsFeedback.textColor = .secondaryLabelColor
    settingsFeedback.lineBreakMode = .byWordWrapping
    settingsFeedback.maximumNumberOfLines = 2
    root.addArrangedSubview(settingsFeedback)
    settingsProgress.style = .spinning
    settingsProgress.controlSize = .small
    settingsProgress.isDisplayedWhenStopped = false
    saveButton = NSButton(title: "Sprawdź i zapisz", target: self, action: #selector(saveSettings))
    saveButton.keyEquivalent = "\r"
    let footer = NSStackView(views: [settingsProgress, NSView(), saveButton])
    footer.orientation = .horizontal
    root.addArrangedSubview(footer)
    footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    syncToggle.state = configuredSyncEnabled ? .on : .off
    claudeToggle.state = configuredClaudeEnabled ? .on : .off
    calendarToggle.state = configuredCalendarEnabled ? .on : .off
    populateCalendars(selected: savedSetting("CALENDAR_ID", fallback: ""))
    toggleSynchronization()
  }

  private func settingsBox(_ title: String, _ rows: [(String, NSView)]) -> NSBox {
    let box = NSBox()
    box.title = title
    box.titlePosition = .atTop
    box.boxType = .primary
    let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).xPlacement = .leading
    grid.rowSpacing = 8
    grid.columnSpacing = 12
    grid.translatesAutoresizingMaskIntoConstraints = false
    box.contentView?.addSubview(grid)
    NSLayoutConstraint.activate([
      grid.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 12),
      grid.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -12),
      grid.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 8),
      grid.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -10),
    ])
    box.widthAnchor.constraint(equalToConstant: 546).isActive = true
    return box
  }

  @objc private func toggleSynchronization() {
    targetBox.isHidden = syncToggle.state != .on
  }

  @objc private func toggleCalendar() {
    guard calendarToggle.state == .on else {
      calendarPopup.isEnabled = false
      return
    }
    Task {
      do {
        guard try await CalendarIntegration.requestAccess() else { throw CalendarIntegrationError.accessDenied }
        populateCalendars(selected: calendarPopup.selectedItem?.representedObject as? String ?? "")
        settingsFeedback.textColor = .secondaryLabelColor
        settingsFeedback.stringValue = "Wybierz służbowy kalendarz i zapisz ustawienia."
      } catch {
        calendarToggle.state = .off
        calendarPopup.isEnabled = false
        settingsFeedback.textColor = .systemRed
        settingsFeedback.stringValue = error.localizedDescription
      }
    }
  }

  private func populateCalendars(selected identifier: String) {
    calendarPopup.removeAllItems()
    let calendars = CalendarIntegration.calendars()
    for calendar in calendars {
      calendarPopup.addItem(withTitle: calendar.title)
      calendarPopup.lastItem?.representedObject = calendar.identifier
    }
    if let index = calendarPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == identifier }) {
      calendarPopup.selectItem(at: index)
    }
    if calendarPopup.numberOfItems == 0 { calendarPopup.addItem(withTitle: "Brak dostępu do kalendarzy") }
    calendarPopup.isEnabled = calendarToggle.state == .on && !calendars.isEmpty
  }

  func menuWillOpen(_ menu: NSMenu) { refresh() }

  @objc private func checkForUpdates(_ sender: Any?) {
    let updater = updaterController.updater
    guard !updater.canCheckForUpdates else {
      presentUpdater(sender)
      return
    }

    updaterReadinessObservation?.invalidate()
    updaterReadinessObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
      guard change.newValue == true else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.updaterReadinessObservation?.invalidate()
        self.updaterReadinessObservation = nil
        self.presentUpdater(nil)
      }
    }
  }

  private func presentUpdater(_ sender: Any?) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    updaterController.checkForUpdates(sender)
  }

  private func refresh() {
    let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    let runs = configuredSyncEnabled ? parseLog(text) : []
    var icon = "clock"

    if configuredSyncEnabled, let last = runs.last {
      let formatter = DateFormatter()
      formatter.dateFormat = "dd.MM, HH:mm"
      if last.error != nil {
        lastSyncStatus.title = "Ostatnia synchronizacja nie powiodła się"
        icon = "exclamationmark.triangle"
      } else if let hours = last.hours {
        lastSyncStatus.title = "Ostatni zapis \(formatter.string(from: last.date)) · \(format(hours))"
        icon = "clock.badge.checkmark"
      } else if Date().timeIntervalSince(last.date) < 600 {
        lastSyncStatus.title = "Synchronizacja trwa…"
        icon = "arrow.triangle.2.circlepath"
      } else {
        lastSyncStatus.title = "Ostatnia synchronizacja nie powiodła się"
        icon = "exclamationmark.triangle"
      }
    } else if configuredSyncEnabled {
      lastSyncStatus.title = "Synchronizacja nie była jeszcze uruchamiana"
    }

    let status = try? JSONDecoder().decode(ReportStatus.self, from: Data(contentsOf: reportStatusURL))
    let now = Date()
    let statusIsStale = status.flatMap { isoDate($0.checkedAt) }.map { now.timeIntervalSince($0) >= 55 } ?? true
    if statusIsStale, now.timeIntervalSince(lastStatusKick) >= 55 {
      lastStatusKick = now
      runAgent(statusLabel)
    }
    let showTarget = status?.syncEnabled ?? configuredSyncEnabled
    let isWeekend = Calendar.current.isDateInWeekend(now)
    let currentDay = LocalDay(now)
    let currentHour = Calendar.current.component(.hour, from: now)
    let today = currentToday(status, on: currentDay)
    let cachedDayIsClosed = status?.today.map { $0.to < currentDay.description } ?? false
    let weekendText = isWeekend ? weekendMessage(day: Calendar.current.component(.day, from: now)) : nil
    let completedWeek = completedPeriod(status?.week, including: status?.today, includeDay: isWeekend || cachedDayIsClosed)
    let month = status?.month.flatMap { $0.from.hasPrefix(currentDay.monthID) ? $0 : nil }
    let monthDay = status?.today.flatMap { $0.from.hasPrefix(currentDay.monthID) ? $0 : nil }
    let completedMonth = completedPeriod(month, including: monthDay, includeDay: isWeekend || cachedDayIsClosed)
    let missingDays = completedMonth?.missing.count ?? 0
    renderHeader(status, today: today, month: completedMonth, weekendText: weekendText, missingDays: missingDays)
    if let status, let today, let checked = isoDate(status.lastSuccessfulAt ?? status.checkedAt) {
      let formatter = DateFormatter()
      formatter.dateFormat = "HH:mm"
      let expected = status.expectedSeconds ?? Int((Double(configuredWorkdayHours) ?? 8) * 3600)
      if isWeekend, let period = completedMonth {
        renderPeriod(todayStatus, label: "Weekend", value: period, expected: expected, showTarget: showTarget)
        todayStatus.title = missingDays == 0 ? "Weekend · raporty kompletne" : "Weekend · braki: \(missingDays)"
        if status.error != nil { todayStatus.title += " · offline · dane \(formatter.string(from: checked))" }
        let lastWorkday = [status.today, status.yesterday].compactMap { $0 }.filter { $0.workingDays > 0 }.max { $0.to < $1.to }
        if let lastWorkday {
          renderPeriod(yesterdayStatus, label: weekdayLabel(lastWorkday.to), value: lastWorkday, expected: expected, showTarget: showTarget)
        } else {
          setWaiting(yesterdayStatus, label: "Ostatni dzień pracy")
        }
      } else {
        renderPeriod(todayStatus, label: dayLabel(currentDay), value: today, expected: expected, showTarget: showTarget)
        todayStatus.title += status.error == nil
          ? " · \(formatter.string(from: checked))"
          : " · offline · dane \(formatter.string(from: checked))"
        if let yesterday = status.yesterday {
          renderPeriod(yesterdayStatus, label: previousDayLabel(yesterday.to, now: now), value: yesterday, expected: expected, showTarget: showTarget)
        } else {
          setWaiting(yesterdayStatus, label: "Poprzedni dzień pracy")
        }
      }
      item.button?.title = statusBarTitle(
        seconds: today.sourceSeconds,
        weekendText: weekendText,
        missingDays: missingDays,
        day: currentDay.day,
        hour: currentHour
      )
      if let week = completedWeek {
        renderPeriod(weekStatus, label: "Tydzień", value: week, expected: expected, showTarget: showTarget)
      } else {
        setWaiting(weekStatus, label: "Tydzień")
      }
      if let month = completedMonth {
        renderPeriod(monthStatus, label: "Miesiąc", value: month, expected: expected, showTarget: showTarget)
      } else {
        setWaiting(monthStatus, label: "Miesiąc")
      }
    } else if let status, let checked = isoDate(status.lastSuccessfulAt ?? status.checkedAt) {
      let formatter = DateFormatter()
      formatter.dateFormat = "dd.MM, HH:mm"
      let expected = status.expectedSeconds ?? Int((Double(configuredWorkdayHours) ?? 8) * 3600)
      todayStatus.title = "\(dayLabel(currentDay)) · brak dzisiejszych danych"
      let staleDetail = status.error == nil ? "Ostatni odczyt: " : "Offline · ostatni udany odczyt: "
      setDetails(todayStatus, [staleDetail + formatter.string(from: checked)])
      if let lastWorkday = [status.today, status.yesterday].compactMap({ $0 }).filter({ $0.workingDays > 0 && $0.to < currentDay.description }).max(by: { $0.to < $1.to }) {
        renderPeriod(yesterdayStatus, label: weekdayLabel(lastWorkday.to), value: lastWorkday, expected: expected, showTarget: showTarget)
      } else {
        setWaiting(yesterdayStatus, label: "Poprzedni dzień pracy")
      }
      if let week = completedWeek {
        renderPeriod(weekStatus, label: "Tydzień do \(shortDate(week.to))", value: week, expected: expected, showTarget: showTarget)
      } else {
        setWaiting(weekStatus, label: "Tydzień")
      }
      if let month = completedMonth {
        renderPeriod(monthStatus, label: "Miesiąc do \(shortDate(month.to))", value: month, expected: expected, showTarget: showTarget)
      } else {
        setWaiting(monthStatus, label: "Miesiąc")
      }
      item.button?.title = noDataMessage(day: currentDay.day, hour: currentHour, missingDays: missingDays)
    } else {
      todayStatus.title = "\(dayLabel(currentDay)) · czekam na dane"
      setDetails(todayStatus, ["Czekam na pierwszy odczyt z Jiry."])
      for (line, label) in [(yesterdayStatus, "Poprzedni dzień pracy"), (weekStatus, "Tydzień"), (monthStatus, "Miesiąc")] {
        setWaiting(line, label: label)
      }
      item.button?.title = noDataMessage(day: currentDay.day, hour: currentHour, missingDays: missingDays)
    }
    reminderSchedule.title = isWeekend ? "Przypomnienia wrócą w poniedziałek" : "Przypomnienie \(configuredReminderTime)"
    if configuredSyncEnabled {
      syncSchedule.title = "Automatyczny zapis \(configuredSyncTime)"
      renderHistory(runs)
    }
    if let image = normalMenuIcon {
      item.button?.image = image
    } else {
      item.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "This Is Logged")
    }
  }

  private func renderHeader(_ status: ReportStatus?, today: PeriodStatus?, month: PeriodStatus?, weekendText: String?, missingDays: Int) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pl_PL")
    formatter.dateFormat = "LLLL"
    headerMonthLabel.stringValue = formatter.string(from: Date()).uppercased(with: formatter.locale)
    headerTodayLabel.stringValue = dayLabel(LocalDay(Date())).uppercased(with: formatter.locale)
    guard let status else {
      headerMonthValue.stringValue = "—"
      headerMonthDetail.stringValue = "Brak danych z Jiry"
      headerTodayValue.stringValue = "Brak danych"
      return
    }
    let expected = status.expectedSeconds ?? Int((Double(configuredWorkdayHours) ?? 8) * 3600)
    if month != nil, let capacity = status.monthCapacity {
      headerMonthValue.stringValue = "\(formatSeconds(capacity.reportedSeconds ?? 0)) / \(formatSeconds(capacity.expectedSeconds)) h"
    } else {
      headerMonthValue.stringValue = "—"
    }
    let summary = periodSummary(month)
    if status.error != nil, let checked = isoDate(status.lastSuccessfulAt ?? status.checkedAt) {
      let time = DateFormatter()
      time.dateFormat = "HH:mm"
      headerMonthDetail.stringValue = "\(summary) · offline, dane z \(time.string(from: checked))"
    } else {
      headerMonthDetail.stringValue = summary
    }

    if let weekendText {
      headerTodayValue.stringValue = missingDays == 0 ? weekendText : "Braki w raportach: \(missingDays)"
      return
    }
    guard let today else {
      headerTodayValue.stringValue = "Brak dzisiejszych danych"
      return
    }
    let todaySeconds = today.sourceSeconds
    if today.workingDays == 0 {
      headerTodayValue.stringValue = "\(formatSeconds(todaySeconds)) h · dzień wolny"
      return
    }
    headerTodayValue.stringValue = "\(formatSeconds(todaySeconds)) / \(formatSeconds(expected)) h"
  }

  private func periodSummary(_ value: PeriodStatus?) -> String {
    guard let value else { return "Czekam na kontrolę raportów" }
    guard value.from <= value.to else { return "Brak zakończonych dni do kontroli" }
    return value.missing.isEmpty ? "Zamknięte dni kompletne" : "Braki w zamkniętych dniach: \(value.missing.count)"
  }

  private func renderPeriod(_ item: NSMenuItem, label: String, value: PeriodStatus, expected: Int, showTarget: Bool) {
    if value.from > value.to {
      item.title = "\(label) · brak zakończonych dni"
      setDetails(item, ["Kontrola rozpocznie się po zakończeniu pierwszego dnia miesiąca."])
      return
    }
    let expectedTotal = value.workingDays * expected
    let report = value.missing.isEmpty ? "raport: OK" : "raport: braki"
    let target = showTarget
      ? " · " + (value.differences.map { $0.isEmpty ? "cel: OK" : "cel: różnice \($0.count)" } ?? "cel: brak danych")
      : ""
    item.title = value.workingDays == 0
      ? "\(label) · dzień wolny\(target)"
      : "\(label) · \(formatSeconds(value.sourceSeconds))/\(formatSeconds(expectedTotal)) h · \(report)\(target)"

    var details = ["Zakres: \(shortDate(value.from))–\(shortDate(value.to))"]
    if value.workingDays == 0 {
      details.append(value.sourceSeconds == 0
        ? "Raport: dzień wolny, bez wpisów"
        : "Raport: dzień wolny, zaraportowano \(formatSeconds(value.sourceSeconds)) h")
    } else if value.missing.isEmpty {
      details.append("Raport: wszystkie dni uzupełnione")
    } else {
      details += value.missing.map {
        "Raport \(shortDate($0.date)): \(formatSeconds($0.sourceSeconds))/\(formatSeconds(expected)) h · brakuje \(formatSeconds(max(0, expected - $0.sourceSeconds))) h"
      }
    }
    if showTarget {
      if let differences = value.differences {
        details.append(contentsOf: differences.isEmpty
          ? ["Cel: zgodny z Jirą główną"]
          : differences.map {
              "Cel \(shortDate($0.date)): Jira główna \(formatSeconds($0.sourceSeconds)) h · cel \(formatSeconds($0.targetSeconds)) h"
            })
      } else {
        details.append("Cel: nie udało się sprawdzić połączenia")
      }
    }
    setDetails(item, details)
  }

  private func setWaiting(_ item: NSMenuItem, label: String) {
    item.title = "\(label) · odświeżam dane…"
    setDetails(item, [configuredSyncEnabled ? "Czekam na odczyt obu instancji Jiry." : "Czekam na odczyt Jiry."])
  }

  private func setDetails(_ item: NSMenuItem, _ titles: [String]) {
    item.submenu?.removeAllItems()
    for title in titles {
      let detail = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      detail.isEnabled = false
      item.submenu?.addItem(detail)
    }
  }

  private func formatSeconds(_ seconds: Int) -> String { String(format: "%.2f", Double(seconds) / 3600) }

  private func shortDate(_ value: String) -> String {
    let parts = value.split(separator: "-")
    return parts.count == 3 ? "\(parts[2]).\(parts[1])" : value
  }

  private func renderHistory(_ runs: [Run]) {
    let formatter = DateFormatter()
    formatter.dateFormat = "dd.MM HH:mm"
    historyMenu.removeAllItems()
    for run in runs.suffix(5).reversed() {
      let result = run.error != nil ? "BŁĄD" : run.hours.map { format($0) } ?? "nieukończona"
      let collision = run.collisions > 0 ? " · różnice: \(run.collisions)" : ""
      let entry = NSMenuItem(title: "\(formatter.string(from: run.date)) · \(result)\(collision)", action: nil, keyEquivalent: "")
      entry.isEnabled = false
      historyMenu.addItem(entry)
    }
    if runs.isEmpty {
      let empty = NSMenuItem(title: "Brak zapisanych uruchomień", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      historyMenu.addItem(empty)
    }
  }

  private func format(_ hours: Double) -> String { String(format: "%.2f h", hours) }

  private func isoDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: value)
  }

  @objc private func showSettings() {
    if panel.isVisible {
      NSApplication.shared.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
      return
    }
    let values = readSettings()
    sourceURLField.stringValue = values["SRC_URL"] ?? ""
    sourceEmailField.stringValue = values["SRC_EMAIL"] ?? ""
    sourceTokenField.stringValue = values["SRC_TOKEN"] ?? ""
    targetURLField.stringValue = values["DST_URL"] ?? ""
    targetEmailField.stringValue = values["DST_EMAIL"] ?? ""
    targetTokenField.stringValue = values["DST_TOKEN"] ?? ""
    targetIssueField.stringValue = values["DST_ISSUE"] ?? ""
    syncToggle.state = (values["SYNC_ENABLED"] == "1" || configuredSyncEnabled) ? .on : .off
    commentKeysToggle.state = values["COMMENT_KEYS"] == "1" ? .on : .off
    syncTimeField.stringValue = values["SYNC_TIME"] ?? configuredSyncTime
    reminderTimeField.stringValue = values["REMINDER_TIME"] ?? configuredReminderTime
    workdayHoursField.stringValue = values["WORKDAY_HOURS"] ?? configuredWorkdayHours
    claudeToggle.state = values["CLAUDE_ENABLED"] == "1" ? .on : .off
    catchAllIssueField.stringValue = values["CATCH_ALL_ISSUE"] ?? "RPR-18"
    calendarToggle.state = values["CALENDAR_ENABLED"] == "1" ? .on : .off
    populateCalendars(selected: values["CALENDAR_ID"] ?? "")
    toggleSynchronization()
    settingsFeedback.textColor = .secondaryLabelColor
    settingsFeedback.stringValue = configurationComplete(values) ? "Zmiany zostaną sprawdzone w Jirze przed zapisem." : "Uzupełnij Jirę główną, aby uruchomić monitoring."
    NSApplication.shared.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showSettings()
    return true
  }

  @objc private func runNow() {
    lastSyncStatus.title = "Uruchamiam synchronizację…"
    runAgent(syncLabel)
  }

  @objc private func refreshReports() {
    todayStatus.title = Calendar.current.isDateInWeekend(Date()) ? "Weekend · odświeżam…" : "Dzisiaj · odświeżam…"
    runAgent(statusLabel, restart: true)
  }

  @objc private func openLog() { NSWorkspace.shared.open(configuredSyncEnabled ? logURL : statusLogURL) }

  private func runAgent(_ label: String, restart: Bool = false) {
    do {
      try command(["kickstart"] + (restart ? ["-k"] : []) + ["gui/\(getuid())/\(label)"])
    } catch {
      lastSyncStatus.title = "Nie udało się uruchomić zadania launchd"
    }
  }

  @objc private func runInteractive(_ sender: NSMenuItem) {
    openInteractive(sender.representedObject as? String ?? period())
  }

  private func openInteractive(_ selectedPeriod: String) {
    syncWindow = SyncWindowController(period: selectedPeriod) { [weak self] in self?.refreshReports() }
    syncWindow?.showWindow(nil)
  }

  @objc private func showClaudeActivity() {
    guard let settings = try? SettingsStore().load() else { return }
    activityWindow = activityWindow ?? ClaudeActivityWindowController(settings: settings)
    activityWindow?.showWindow(nil)
  }

  @objc private func saveSettings() {
    let synchronization = syncToggle.state == .on
    let claudeIntegration = claudeToggle.state == .on
    let calendarIntegration = calendarToggle.state == .on
    let sourceURL = normalizedURL(sourceURLField.stringValue)
    let targetURL = normalizedURL(targetURLField.stringValue)
    let sourceEmail = sourceEmailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetEmail = targetEmailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceToken = sourceTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetToken = targetTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetIssue = targetIssueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let catchAllIssue = catchAllIssueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let calendarIdentifier = calendarPopup.selectedItem?.representedObject as? String ?? ""
    let sync = syncTimeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let reminder = reminderTimeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let hoursText = workdayHoursField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
    let validURL: (String) -> Bool = { value in
      guard let url = URL(string: value) else { return false }
      return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
    guard validURL(sourceURL), !sourceToken.isEmpty else {
      settingsFeedback.textColor = .systemRed
      settingsFeedback.stringValue = "Podaj poprawny URL i token Jiry głównej."
      return
    }
    if sourceURL.lowercased().contains(".atlassian.net"), !sourceEmail.contains("@") {
      settingsFeedback.textColor = .systemRed
      settingsFeedback.stringValue = "Jira Cloud wymaga emaila konta Atlassian."
      return
    }
    if synchronization && (!validURL(targetURL) || targetToken.isEmpty ||
      targetIssue.range(of: #"^[A-Z][A-Z0-9]*-\d+$"#, options: .regularExpression) == nil) {
      settingsFeedback.textColor = .systemRed
      settingsFeedback.stringValue = "Uzupełnij URL, token i zadanie (np. AUT-123) Jiry docelowej."
      return
    }
    if synchronization && targetURL.lowercased().contains(".atlassian.net") && !targetEmail.contains("@") {
      settingsFeedback.textColor = .systemRed
      settingsFeedback.stringValue = "Docelowa Jira Cloud wymaga emaila konta Atlassian."
      return
    }
    if (claudeIntegration || calendarIntegration) &&
      catchAllIssue.range(of: #"^[A-Z][A-Z0-9]*-\d+$"#, options: .regularExpression) == nil {
      settingsFeedback.textColor = .systemRed
      settingsFeedback.stringValue = "Podaj poprawne zadanie zbiorcze, np. RPR-18."
      return
    }
    if calendarIntegration && calendarIdentifier.isEmpty {
      settingsFeedback.textColor = .systemRed
      settingsFeedback.stringValue = "Nadaj dostęp i wybierz służbowy kalendarz."
      return
    }
    guard (!synchronization || clockParts(sync) != nil), clockParts(reminder) != nil,
          let hours = Double(hoursText), hours > 0, hours <= 24 else {
      settingsFeedback.textColor = .systemRed
      settingsFeedback.stringValue = "Podaj godziny w formacie GG:MM i pełny dzień od 0 do 24 h."
      return
    }

    guard let sourceAddress = URL(string: sourceURL), let executable = Bundle.main.executableURL else { return }
    let targetAddress = synchronization ? URL(string: targetURL) : nil
    let settings = AppSettings(
      source: JiraCredentials(url: sourceAddress, email: sourceEmail, token: sourceToken),
      synchronizationEnabled: synchronization,
      target: targetAddress.map { JiraCredentials(url: $0, email: targetEmail, token: targetToken) },
      targetIssue: targetIssue,
      commentIssueKeys: commentKeysToggle.state == .on,
      synchronizationTime: sync,
      reminderTime: reminder,
      workdayHours: hours,
      claudeIntegrationEnabled: claudeIntegration,
      calendarIntegrationEnabled: calendarIntegration,
      calendarIdentifier: calendarIdentifier,
      catchAllIssue: catchAllIssue
    )
    let appURL = Bundle.main.bundleURL
    let settingsStore = SettingsStore()
    let verification = settings.jiraVerification(comparedTo: try? settingsStore.loadDraft())

    saveButton.isEnabled = false
    settingsProgress.startAnimation(nil)
    settingsFeedback.textColor = .secondaryLabelColor
    settingsFeedback.stringValue = switch verification {
    case (true, true): "Sprawdzam obie Jiry…"
    case (true, false): "Sprawdzam Jirę główną…"
    case (false, true): "Sprawdzam Jirę docelową…"
    case (false, false): "Zapisuję ustawienia…"
    }
    Task.detached {
      do {
        if verification.source {
          _ = try await JiraClient(credentials: settings.source).currentUser()
        }
        if verification.target, let target = settings.target {
          let client = JiraClient(credentials: target)
          _ = try await client.currentUser()
          _ = try await client.issueSummary(settings.targetIssue)
        }
        try ClaudeCodeIntegration().reconcile(enabled: settings.claudeIntegrationEnabled, executable: executable)
        try settingsStore.save(settings)
        try LaunchdManager().reconcile(settings: settings, executable: executable, app: appURL)
        let persistent = deliverNotification("Konfiguracja działa. Monitoring raportów jest aktywny.") && persistentNotificationsEnabled()
        await MainActor.run {
          self.configuredSyncEnabled = synchronization
          self.configuredSyncTime = sync
          self.configuredReminderTime = reminder
          self.configuredWorkdayHours = String(hours)
          self.configuredClaudeEnabled = claudeIntegration
          self.configuredCalendarEnabled = calendarIntegration
          self.activityWindow = nil
          self.setupMenu()
          self.saveButton.isEnabled = true
          self.settingsProgress.stopAnimation(nil)
          self.settingsFeedback.textColor = persistent ? .systemGreen : .systemOrange
          let successMessage = switch (claudeIntegration, calendarIntegration) {
          case (true, true): "Gotowe. Monitoring, Claude Code i Kalendarz są aktywne."
          case (true, false): "Gotowe. Monitoring i Claude Code są aktywne."
          case (false, true): "Gotowe. Monitoring i Kalendarz są aktywne."
          case (false, false): "Gotowe. Monitoring uruchomiony."
          }
          self.settingsFeedback.stringValue = persistent ? successMessage : "Gotowe. W powiadomieniach wybierz styl „Stałe”."
          if !persistent, let settings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(settings)
          }
          self.refreshReports()
        }
      } catch {
        await MainActor.run {
          self.saveButton.isEnabled = true
          self.settingsProgress.stopAnimation(nil)
          self.settingsFeedback.textColor = .systemRed
          self.settingsFeedback.stringValue = "Nie udało się zapisać: \(error.localizedDescription)"
        }
      }
    }
  }

  private func installAgentsIfNeeded() {
    let agent = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(statusLabel).plist")
    guard configurationComplete(readSettings()), let executable = Bundle.main.executableURL else { return }
    let installed = (try? String(contentsOf: agent, encoding: .utf8))?.contains(executable.path) == true
    guard !installed else { return }
    let appURL = Bundle.main.bundleURL
    Task.detached {
      do {
        let settings = try SettingsStore().load()
        try LaunchdManager().reconcile(settings: settings, executable: executable, app: appURL)
      } catch {
        fputs("migration: \(error.localizedDescription)\n", stderr)
      }
    }
  }

  private func refreshClaudeIntegrationIfNeeded() {
    guard configuredClaudeEnabled, let executable = Bundle.main.executableURL,
          let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          UserDefaults.standard.string(forKey: "claudeIntegrationVersion") != version else { return }
    Task.detached {
      do {
        try ClaudeCodeIntegration().reconcile(enabled: true, executable: executable)
        UserDefaults.standard.set(version, forKey: "claudeIntegrationVersion")
      } catch {
        fputs("claude migration: \(error.localizedDescription)\n", stderr)
      }
    }
  }

  private func command(_ arguments: [String]) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = arguments
    try task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 {
      throw NSError(domain: "ThisIsLogged", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "launchctl zakończył się błędem"])
    }
  }

  func layoutSelfcheck(syncEnabled: Bool) {
    configuredSyncEnabled = syncEnabled
    configuredCalendarEnabled = true
    setupMenu()
    setupSettingsPanel()
    let header = item.menu?.items.first?.view
    header?.layoutSubtreeIfNeeded()
    panel.contentView?.layoutSubtreeIfNeeded()
    let bounds = panel.contentView!.bounds
    let sourceFrame = panel.contentView!.convert(sourceURLField.bounds, from: sourceURLField)
    let syncFrame = panel.contentView!.convert(syncTimeField.bounds, from: syncTimeField)
    let calendarFrame = panel.contentView!.convert(calendarPopup.bounds, from: calendarPopup)
    let catchAllFrame = panel.contentView!.convert(catchAllIssueField.bounds, from: catchAllIssueField)
    let saveFrame = panel.contentView!.convert(saveButton.bounds, from: saveButton)
    precondition(
      item.menu?.minimumWidth == 410 && item.menu?.autoenablesItems == true && header?.frame.height == 96 &&
        headerMonthValue.frame.height > 0 && headerTodayValue.frame.height > 0 &&
        item.menu?.items.contains(where: { $0.attributedTitle?.string == "RAPORTY" }) == true &&
        item.menu?.items.contains(where: { $0.attributedTitle?.string == "SYNCHRONIZACJA" }) == syncEnabled &&
        item.menu?.items.contains(where: { $0.title == "Analiza czasu…" }) == true &&
        bounds.contains(sourceFrame) && sourceFrame.height > 0 &&
        (!syncEnabled || bounds.contains(syncFrame) && syncFrame.height > 0) &&
        bounds.contains(calendarFrame) && calendarFrame.height > 0 &&
        bounds.contains(catchAllFrame) && catchAllFrame.height > 0 &&
        bounds.contains(saveFrame) && saveFrame.height > 0 && !panel.hidesOnDeactivate,
      "Opcje są poza widocznym obszarem"
    )
    print("ok")
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let content = response.notification.request.content
    if content.categoryIdentifier == collisionCategory &&
      (response.actionIdentifier == resolveCollisionsAction ||
        response.actionIdentifier == UNNotificationDefaultActionIdentifier) {
      DispatchQueue.main.async {
        self.openInteractive(period())
      }
    } else if content.categoryIdentifier == activityCategory &&
      (response.actionIdentifier == openActivityAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier) {
      DispatchQueue.main.async { self.showClaudeActivity() }
    }
    completionHandler()
  }

  @objc private func quit() { NSApplication.shared.terminate(nil) }
}

private extension NSView {
  var subviewsRecursive: [NSView] { subviews + subviews.flatMap(\.subviewsRecursive) }
}

private final class AsyncFailure: @unchecked Sendable { var error: Error? }

private func runAgentMode(_ operation: @escaping @Sendable () async throws -> Void) -> Never {
  let finished = DispatchSemaphore(value: 0)
  let result = AsyncFailure()
  Task.detached {
    defer { finished.signal() }
    do { try await operation() } catch { result.error = error }
  }
  finished.wait()
  if let error = result.error {
    fputs("niepowodzenie: \(error.localizedDescription)\n", stderr)
    exit(1)
  }
  exit(0)
}

private func syncMonth(_ now: LocalDay) -> (LocalDay, LocalDay) {
  let first = LocalDay("\(now.monthID)-01")!
  return (first, first.adding(months: 1).adding(days: -1))
}

private func nativeHours(_ seconds: Int) -> String { String(format: "%.2f", Double(seconds) / 3600) }

private let arguments = ProcessInfo.processInfo.arguments

if let notify = arguments.firstIndex(of: "--notify"), arguments.indices.contains(notify + 1) {
  exit(deliverNotification(arguments[notify + 1]) ? 0 : 1)
} else if let notify = arguments.firstIndex(of: "--notify-collision"), arguments.indices.contains(notify + 1) {
  exit(deliverNotification(arguments[notify + 1], category: collisionCategory) ? 0 : 1)
} else if arguments.contains("--notification-check") {
  exit(persistentNotificationsEnabled() ? 0 : 1)
} else if arguments.contains("--ingest-claude-hook") {
  do {
    let capture = try ActivityStore().recordClaudeHook(FileHandle.standardInput.readDataToEndOfFile())
    if capture.eventName == "UserPromptSubmit" {
      let issue = capture.issueKey.map { " Automatycznie rozpoznane zadanie: \($0)." } ?? ""
      let catchAll = (try? SettingsStore().loadDraft().catchAllIssue) ?? "RPR-18"
      let context = "This Is Logged zapisał wyłącznie bieżące polecenie jako \(capture.eventID).\(issue) Oceń tylko tę wiadomość, bez pobierania historii: przypisz ją przez suggest_attribution do wiarygodnego zadania Jiry, a zwykłą rozmowę lub pracę ogólną do \(catchAll). Użyj discard_event wyłącznie dla technicznego testu, pomyłki lub wiadomości bez związku z pracą; nie zgaduj innego zadania."
      let response: [String: Any] = [
        "hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": context]
      ]
      let output = try JSONSerialization.data(withJSONObject: response)
      FileHandle.standardOutput.write(output)
      FileHandle.standardOutput.write(Data("\n".utf8))
    }
    exit(0)
  } catch {
    fputs("this-is-logged hook: \(error.localizedDescription)\n", stderr)
    exit(1)
  }
} else if arguments.contains("--mcp") {
  ClaudeMCPServer().run()
} else if arguments.contains("--layout-selfcheck") {
  _ = NSApplication.shared
  let delegate = AppDelegate()
  delegate.layoutSelfcheck(syncEnabled: true)
  withExtendedLifetime(delegate) {}
} else if arguments.contains("--layout-selfcheck-monitoring") {
  _ = NSApplication.shared
  let delegate = AppDelegate()
  delegate.layoutSelfcheck(syncEnabled: false)
  withExtendedLifetime(delegate) {}
} else if arguments.contains("--sync-layout-selfcheck") {
  _ = NSApplication.shared
  let controller = SyncWindowController(period: period()) {}
  controller.layoutSelfcheck()
  withExtendedLifetime(controller) {}
} else if arguments.contains("--activity-layout-selfcheck") {
  _ = NSApplication.shared
  let settings = AppSettings(source: JiraCredentials(url: URL(string: "https://jira.example.com")!, token: "test"))
  let controller = ClaudeActivityWindowController(settings: settings)
  controller.layoutSelfcheck()
  withExtendedLifetime(controller) {}
} else if arguments.contains("--selfcheck") {
  let runs = parseLog("""
  --- 2026-09-01T21:00:00.000Z ---
  2026-09-01  8.00h  ABC-1

  zapisano: 8.00h -> TIME-1 (2026-09)
  --- 2026-09-02T21:00:00.000Z ---
  2026-09-02  5.00h  KOLIZJA: w celu masz juz 8.00h - pomijam

  zapisano: 0.00h -> TIME-1 (2026-09)
  --- 2026-09-03T21:00:00.000Z ---
  niepowodzenie: fetch failed
  """)
  precondition(runs.count == 3, "runs: \(runs)")
  precondition(runs[0].hours == 8, "first: \(runs[0])")
  precondition(runs[1].hours == 0 && runs[1].collisions == 1, "second: \(runs[1])")
  precondition(runs[2].error == "fetch failed", "third: \(runs[2])")
  let status = try! JSONDecoder().decode(ReportStatus.self, from: Data(#"{"checkedAt":"2026-09-02T14:00:00.000Z","syncEnabled":false,"seconds":12600,"expectedSeconds":28800,"today":{"from":"2026-09-02","to":"2026-09-02","workingDays":1,"sourceSeconds":12600,"targetSeconds":null,"missing":[{"date":"2026-09-02","sourceSeconds":12600}],"differences":null},"monthCapacity":{"workingDays":22,"daysOff":8,"expectedSeconds":633600}}"#.utf8))
  precondition(status.syncEnabled == false && status.today?.missing.count == 1 && status.today?.differences == nil && status.monthCapacity?.workingDays == 22, "status")
  precondition(clockParts("23:05")?.hour == 23 && clockParts("24:00") == nil, "clock")
  precondition(textEditingCommands.contains {
    $0.action == #selector(NSText.paste(_:)) && $0.key == "v" && $0.modifiers == .command
  }, "paste shortcut")
  precondition((0..<8).map(weekendMessage) == weekendMessages + weekendMessages, "weekend message rotation")
  precondition((0..<8).map { noDataMessage(day: $0, hour: 7, missingDays: 0) } == (morningMessages + morningMessages).map { " \($0)" }, "morning message rotation")
  precondition(noDataMessage(day: 7, hour: 7, missingDays: 0) == " od ósmej, szefie", "morning message before work")
  precondition(noDataMessage(day: 7, hour: 8, missingDays: 0) == " gdzie VPN?", "no-data message after work starts")
  precondition(noDataMessage(day: 7, hour: 7, missingDays: 2) == " braki: 2", "missing reports stay visible before work")
  precondition(statusBarTitle(seconds: 0, weekendText: "nadgodzinki?", missingDays: 0, day: 7, hour: 7) == " nadgodzinki?", "weekend easter egg")
  precondition(statusBarTitle(seconds: 0, weekendText: "nadgodzinki?", missingDays: 2, day: 7, hour: 7) == " braki: 2", "weekend warning")
  precondition(statusBarTitle(seconds: 0, weekendText: nil, missingDays: 0, day: 7, hour: 7) == " od ósmej, szefie", "live zero before work")
  precondition(statusBarTitle(seconds: 0, weekendText: nil, missingDays: 0, day: 7, hour: 8) == " 0.00 h", "workday starts at eight")
  let closedDays = PeriodStatus(from: "2026-08-31", to: "2026-09-03", workingDays: 4, sourceSeconds: 115_200, targetSeconds: 115_200, missing: [], differences: [])
  let friday = PeriodStatus(from: "2026-09-04", to: "2026-09-04", workingDays: 1, sourceSeconds: 28_800, targetSeconds: 28_800, missing: [], differences: [])
  let completedWeek = completedPeriod(closedDays, including: friday, includeDay: true)
  precondition(completedWeek?.to == "2026-09-04" && completedWeek?.workingDays == 5 && completedWeek?.sourceSeconds == 144_000, "cached Friday totals")
  precondition(currentToday(status, on: LocalDay("2026-09-07")!) == nil, "Friday cache cannot be shown as Monday")
  precondition(dayLabel(LocalDay("2026-09-07")!) == "Poniedziałek, 7 września", "full current date label")
  print("ok")
} else if arguments.contains("--agent-status") {
  runAgentMode {
    let settings = try SettingsStore().load()
    let state = try await SnapshotStore().refresh(using: .live(settings: settings))
    print("\(state.checkedAt) miesiąc: \(nativeHours(state.month?.sourceSeconds ?? 0))/\(nativeHours(state.monthCapacity?.expectedSeconds ?? 0))h")
  }
} else if arguments.contains("--agent-reminder") {
  runAgentMode {
    let settings = try SettingsStore().load()
    let decision = try await TimeReportEngine.live(settings: settings).reminder()
    let activity = settings.claudeIntegrationEnabled
      ? try? ActivityStore().activity(on: Date()) : nil
    let activityMessage = activity?.events.isEmpty == false
      ? "Analiza pracy z Claude Code jest gotowa. Sprawdź przypisania i timestampy." : nil
    let message = [decision.message, activityMessage].compactMap { $0 }.joined(separator: "\n\n")
    if !message.isEmpty, !deliverNotification(message, category: activityMessage == nil ? nil : activityCategory) {
      throw NSError(domain: "ThisIsLogged", code: 3, userInfo: [NSLocalizedDescriptionKey: "Nie udało się wyświetlić powiadomienia."])
    }
    print(message.isEmpty ? "Wszystkie dni robocze są kompletne." : message)
  }
} else if arguments.contains("--agent-sync") {
  print("--- \(TimeReportEngine.iso(Date())) ---")
  runAgentMode {
    let settings = try SettingsStore().load()
    let engine = TimeReportEngine.live(settings: settings)
    let now = LocalDay(Date())
    let (from, to) = syncMonth(now)
    let plan = try await engine.syncPlan(from: from, to: to)
    for item in plan.items {
      switch item.state {
      case .add: print("\(item.day)  \(nativeHours(item.sourceSeconds))h  \(item.issueKeys.joined(separator: ", "))")
      case .synced: print("\(item.day)  \(nativeHours(item.sourceSeconds))h  już zsynchronizowane")
      case .collision: print("\(item.day)  \(nativeHours(item.sourceSeconds))h  KOLIZJA: w celu masz \(nativeHours(item.targetSeconds))h - pomijam")
      }
    }
    if arguments.contains("--dry-run") {
      let seconds = plan.items.filter { $0.state == .add }.reduce(0) { $0 + $1.sourceSeconds }
      print("PODGLĄD: \(nativeHours(seconds))h -> \(settings.targetIssue) (\(now.monthID))")
      return
    }
    let result = try await engine.execute(plan)
    _ = try? await SnapshotStore().refresh(using: engine)
    print("zapisano: \(nativeHours(result.writtenSeconds))h -> \(settings.targetIssue) (\(now.monthID))")
    if result.collisionsSkipped > 0 {
      _ = deliverNotification("Wykryto \(result.collisionsSkipped) różnice w \(now.monthID). Automatyzacja niczego nie nadpisała.", category: collisionCategory)
    }
  }
} else if arguments.contains("--check-config-native") {
  runAgentMode {
    let settings = try SettingsStore().load()
    let source = try await JiraClient(credentials: settings.source).currentUser()
    print("Jira: \(source.displayName)")
    if settings.synchronizationEnabled, let target = settings.target {
      let client = JiraClient(credentials: target)
      let user = try await client.currentUser()
      let issue = try await client.issueSummary(settings.targetIssue)
      print("Cel: \(user.displayName)\nZadanie: \(issue)")
    }
  }
} else {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.setActivationPolicy(.accessory)
  app.delegate = delegate
  app.run()
}
