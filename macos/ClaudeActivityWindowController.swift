import AppKit
import ThisIsLoggedCore

@MainActor final class ClaudeActivityWindowController: NSWindowController {
  private let store = ActivityStore()
  private let settings: AppSettings
  private let datePicker = NSDatePicker()
  private let dayTitle = NSTextField(labelWithString: "")
  private let dayTotal = NSTextField(labelWithString: "")
  private let dayStatus = NSTextField(labelWithString: "")
  private let scroll = NSScrollView()
  private let rows = FlippedActivityStackView()
  private let safety = NSTextField(labelWithString: "Tryb analizy · nic nie jest wysyłane do Jiry")
  private var allocationRows: [NSView] = []
  private var issueFields: [String: NSTextField] = [:]
  private var issueTitles: [String: String] = [:]
  private var loadingTitles: Set<String> = []

  init(settings: AppSettings) {
    self.settings = settings
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "Aktywność Claude Code"
    panel.toolbarStyle = .unifiedCompact
    panel.toolbar = NSToolbar(identifier: "claude-activity")
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.collectionBehavior.insert(.moveToActiveSpace)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.minSize = NSSize(width: 700, height: 560)
    super.init(window: panel)
    buildUI()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.center()
    NSApplication.shared.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(sender)
    window?.orderFrontRegardless()
    reload()
  }

  private func buildUI() {
    guard let content = window?.contentView else { return }
    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 12
    root.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(root)
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
      root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
      root.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 18),
      root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
    ])

    let previous = NSButton(title: "‹", target: self, action: #selector(changeDay(_:)))
    previous.tag = -1
    let next = NSButton(title: "›", target: self, action: #selector(changeDay(_:)))
    next.tag = 1
    datePicker.datePickerStyle = .textFieldAndStepper
    datePicker.datePickerElements = [.yearMonthDay]
    datePicker.dateValue = Date()
    datePicker.target = self
    datePicker.action = #selector(reload)
    let refresh = NSButton(title: "Odśwież", target: self, action: #selector(reload))
    let navigation = NSStackView(views: [previous, datePicker, next, NSView(), refresh])
    navigation.orientation = .horizontal
    navigation.alignment = .centerY
    root.addArrangedSubview(navigation)
    navigation.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

    dayTitle.font = .systemFont(ofSize: 14, weight: .semibold)
    dayTitle.textColor = .secondaryLabelColor
    dayTotal.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
    dayStatus.font = .systemFont(ofSize: 13)
    dayStatus.textColor = .secondaryLabelColor
    root.addArrangedSubview(dayTitle)
    root.addArrangedSubview(dayTotal)
    root.addArrangedSubview(dayStatus)

    let separator = NSBox()
    separator.boxType = .separator
    root.addArrangedSubview(separator)
    separator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 8
    rows.frame = NSRect(x: 0, y: 0, width: 700, height: 1)
    rows.autoresizingMask = [.width]
    scroll.documentView = rows
    root.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

    safety.font = .systemFont(ofSize: 12, weight: .medium)
    safety.textColor = .systemGreen
    root.addArrangedSubview(safety)
  }

  @objc private func reload() {
    do {
      let now = Date()
      render(try store.activity(
        on: datePicker.dateValue,
        now: now,
        targetMinutes: targetMinutes(for: datePicker.dateValue, now: now)
      ))
    } catch {
      render(DailyActivity(day: "", events: [], allocations: []))
      dayStatus.textColor = .systemRed
      dayStatus.stringValue = "Nie udało się odczytać aktywności: \(error.localizedDescription)"
    }
  }

  private func render(_ activity: DailyActivity, fetchTitles: Bool = true) {
    rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
    allocationRows.removeAll()
    issueFields.removeAll()

    rows.addArrangedSubview(section("SZACOWANY PODZIAŁ CZASU"))
    rows.addArrangedSubview(row([
      label("Zadanie", header: true), label("Czas", header: true),
      label("Podstawa", header: true), label("Zakres sygnałów", header: true),
    ], widths: [330, 70, 90, 160]))
    for allocation in activity.allocations {
      let evidence = allocation.evidence == 0 ? "bez wskazań" : "\(allocation.evidence) wskazań"
      let task = label(Self.taskLabel(allocation.issueKey, title: issueTitles[allocation.issueKey]))
      task.toolTip = task.stringValue
      issueFields[allocation.issueKey] = task
      let item = row([
        task, label(Self.duration(allocation.minutes)),
        label(evidence), label(signalRange(for: allocation.issueKey, events: activity.events)),
      ], widths: [330, 70, 90, 160])
      allocationRows.append(item)
      rows.addArrangedSubview(item)
    }
    if activity.allocations.isEmpty {
      let empty = label("Za mało aktywności, aby wyliczyć pierwsze 5 minut.")
      empty.textColor = .secondaryLabelColor
      rows.addArrangedSubview(empty)
    }

    let separator = NSBox()
    separator.boxType = .separator
    separator.widthAnchor.constraint(equalToConstant: 686).isActive = true
    rows.addArrangedSubview(separator)
    let displayedEvents = activity.events.suffix(50)
    rows.addArrangedSubview(section("OSTATNIE ISTOTNE ZDARZENIA · \(displayedEvents.count) Z \(activity.events.count)"))
    rows.addArrangedSubview(row([
      label("Czas", header: true), label("Akcja", header: true),
      label("Kontekst", header: true), label("Szczegóły", header: true),
    ], widths: [70, 115, 130, 335]))
    for event in displayedEvents {
      rows.addArrangedSubview(row([
        label(Self.timeFormatter.string(from: event.occurredAt)), label(Self.eventName(event.kind)),
        label(event.issueKey ?? event.branch ?? "—"), label(Self.detail(event)),
      ], widths: [70, 115, 130, 335]))
    }
    if activity.events.isEmpty {
      let empty = label("Brak zdarzeń Claude Code dla tego dnia.")
      empty.textColor = .secondaryLabelColor
      rows.addArrangedSubview(empty)
    } else if activity.events.count > displayedEvents.count {
      let more = label("Starsze zdarzenia pominięto w widoku, ale nadal uwzględniono je w obliczeniu czasu.")
      more.textColor = .secondaryLabelColor
      rows.addArrangedSubview(more)
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pl_PL")
    formatter.dateFormat = "EEEE, d MMMM"
    dayTitle.stringValue = formatter.string(from: datePicker.dateValue).capitalized
    let total = activity.allocations.reduce(0) { $0 + $1.minutes }
    let target = Calendar.current.isDateInWeekend(datePicker.dateValue) ? 0 : Int(settings.workdayHours * 60)
    dayTotal.stringValue = "\(Self.duration(total)) / \(Self.duration(target)) h"
    dayTotal.textColor = total == target || target == 0 ? .labelColor : .systemOrange
    let sessions = Set(activity.events.map(\.sessionID)).count
    dayStatus.textColor = .secondaryLabelColor
    let estimate = activity.inferredMinutes > 0 ? " · +\(Self.duration(activity.inferredMinutes)) estymacji" : ""
    dayStatus.stringValue = "\(sessions) sesji · \(activity.events.count) zdarzeń · \(Self.duration(activity.observedMinutes)) z aktywności\(estimate)"
    resizeDocument()
    if fetchTitles { loadTitles(for: activity.allocations.map(\.issueKey)) }
  }

  private func targetMinutes(for date: Date, now: Date) -> Int? {
    let calendar = Calendar.current
    guard !calendar.isDateInWeekend(date) else { return nil }
    let selectedDay = calendar.startOfDay(for: date)
    let today = calendar.startOfDay(for: now)
    let dailyTarget = Int(settings.workdayHours * 60)
    if selectedDay < today { return dailyTarget }
    guard selectedDay == today,
          let start = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: selectedDay) else { return 0 }
    return min(dailyTarget, max(0, Int(now.timeIntervalSince(start) / 60)))
  }

  private func loadTitles(for issues: [String]) {
    let pending = Set(issues).filter { $0 != "Nieprzypisane" && issueTitles[$0] == nil && !loadingTitles.contains($0) }
    guard !pending.isEmpty else { return }
    let client = JiraClient(credentials: settings.source)
    for issue in pending {
      loadingTitles.insert(issue)
      Task { [weak self] in
        let title = try? await client.issueSummary(issue)
        guard let self else { return }
        self.loadingTitles.remove(issue)
        guard let title else { return }
        self.issueTitles[issue] = title
        if let field = self.issueFields[issue] {
          field.stringValue = Self.taskLabel(issue, title: title)
          field.toolTip = field.stringValue
        }
      }
    }
  }

  private func signalRange(for issue: String, events: [ActivityEvent]) -> String {
    let dates = events.filter { ($0.issueKey ?? "Nieprzypisane") == issue }.map(\.occurredAt)
    guard let first = dates.first, let last = dates.last else { return "—" }
    let start = Self.timeFormatter.string(from: first)
    let end = Self.timeFormatter.string(from: last)
    return start == end ? start : "\(start)–\(end)"
  }

  private func resizeDocument() {
    rows.layoutSubtreeIfNeeded()
    rows.setFrameSize(NSSize(width: max(686, scroll.contentSize.width), height: rows.fittingSize.height))
  }

  private func row(_ views: [NSView], widths: [CGFloat]) -> NSView {
    let result = NSStackView(views: views)
    result.orientation = .horizontal
    result.alignment = .centerY
    result.spacing = 12
    for (view, width) in zip(views, widths) {
      view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    return result
  }

  private func label(_ value: String, header: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = header ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 13)
    field.lineBreakMode = .byTruncatingTail
    return field
  }

  private func section(_ value: String) -> NSTextField {
    let field = label(value, header: true)
    field.textColor = .secondaryLabelColor
    return field
  }

  @objc private func changeDay(_ sender: NSButton) {
    datePicker.dateValue = Calendar.current.date(byAdding: .day, value: sender.tag, to: datePicker.dateValue) ?? datePicker.dateValue
    reload()
  }

  private static func duration(_ minutes: Int) -> String {
    String(format: "%d:%02d", minutes / 60, minutes % 60)
  }

  private static func taskLabel(_ issue: String, title: String?) -> String {
    title.map { "\(issue) · \($0)" } ?? issue
  }

  private static func eventName(_ kind: String) -> String {
    switch kind {
    case "UserPromptSubmit": "Wiadomość"
    case "Stop": "Koniec odpowiedzi"
    default: kind
    }
  }

  private static func detail(_ event: ActivityEvent) -> String {
    let value = event.toolName ?? event.text ?? event.cwd
    return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pl_PL")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  func layoutSelfcheck() {
    window?.contentView?.layoutSubtreeIfNeeded()
    render(DailyActivity(day: "2026-09-07", events: [], allocations: [
      ActivityAllocation(issueKey: "ABC-1", minutes: 15, evidence: 3),
      ActivityAllocation(issueKey: "ABC-2", minutes: 15, evidence: 3),
      ActivityAllocation(issueKey: "ABC-3", minutes: 15, evidence: 3),
      ActivityAllocation(issueKey: "ABC-4", minutes: 15, evidence: 3),
    ]), fetchTitles: false)
    window?.contentView?.layoutSubtreeIfNeeded()
    resizeDocument()
    let frames = allocationRows.map { $0.convert($0.bounds, to: rows) }.sorted { $0.minY < $1.minY }
    let separated = frames.allSatisfy { $0.width >= 650 && $0.height >= 15 } &&
      zip(frames, frames.dropFirst()).allSatisfy { $0.maxY <= $1.minY }
    precondition(
      window?.minSize.width == 700 && rows.isFlipped && rows.frame.height > 100 && safety.frame.height > 0 && separated &&
        Self.taskLabel("ABC-1", title: "Napraw formularz") == "ABC-1 · Napraw formularz",
      "Okno aktywności ma nieprawidłowy układ"
    )
    print("ok")
  }
}

private final class FlippedActivityStackView: NSStackView {
  override var isFlipped: Bool { true }
}
