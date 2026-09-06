import AppKit
import ThisIsLoggedCore

@MainActor final class ClaudeActivityWindowController: NSWindowController, NSTextFieldDelegate {
  private struct Editor {
    let issue: NSTextField
    let duration: NSTextField
    let decision: NSPopUpButton
    let evidence: Int
  }

  private let store = ActivityStore()
  private let settings: AppSettings
  private let datePicker = NSDatePicker()
  private let dayTitle = NSTextField(labelWithString: "")
  private let dayTotal = NSTextField(labelWithString: "")
  private let dayStatus = NSTextField(labelWithString: "")
  private let rows = NSStackView()
  private let feedback = NSTextField(labelWithString: "")
  private let addButton = NSButton(title: "+ Dodaj raport", target: nil, action: nil)
  private let rejectButton = NSButton(title: "Odrzuć dzień", target: nil, action: nil)
  private let saveButton = NSButton(title: "Zapisz zatwierdzone w Jirze", target: nil, action: nil)
  private let progress = NSProgressIndicator()
  private var editors: [Editor] = []
  private var currentActivity: DailyActivity?
  private var reviewStatus: ActivityReviewStatus?

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
    reload()
    super.showWindow(sender)
    window?.center()
    NSApplication.shared.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(sender)
    window?.orderFrontRegardless()
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

    let section = NSTextField(labelWithString: "RAPORTY DO JIRY")
    section.font = .systemFont(ofSize: 11, weight: .semibold)
    section.textColor = .secondaryLabelColor
    root.addArrangedSubview(section)

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    let document = FlippedActivityView(frame: NSRect(x: 0, y: 0, width: 700, height: 1))
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 8
    rows.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(rows)
    scroll.documentView = document
    NSLayoutConstraint.activate([
      rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
      rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])
    root.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

    addButton.target = self
    addButton.action = #selector(addReport)
    root.addArrangedSubview(addButton)

    feedback.textColor = .secondaryLabelColor
    feedback.lineBreakMode = .byWordWrapping
    feedback.maximumNumberOfLines = 2
    progress.style = .spinning
    progress.controlSize = .small
    progress.isDisplayedWhenStopped = false
    rejectButton.target = self
    rejectButton.action = #selector(rejectDay)
    saveButton.target = self
    saveButton.action = #selector(saveToJira)
    saveButton.keyEquivalent = "\r"
    let footer = NSStackView(views: [progress, feedback, NSView(), rejectButton, saveButton])
    footer.orientation = .horizontal
    footer.alignment = .centerY
    root.addArrangedSubview(footer)
    footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
  }

  @objc private func reload() {
    do {
      let target = Calendar.current.isDateInWeekend(datePicker.dateValue) ? 0 : Int(settings.workdayHours * 60)
      let computed = try store.activity(on: datePicker.dateValue, targetMinutes: target)
      let review = try store.review(day: computed.day)
      let allocations = review?.status == .approved ? review!.allocations : computed.allocations
      currentActivity = DailyActivity(day: computed.day, events: computed.events, allocations: allocations)
      reviewStatus = review?.status
      render(allocations)
    } catch {
      currentActivity = nil
      reviewStatus = nil
      render([])
      feedback.textColor = .systemRed
      feedback.stringValue = "Nie udało się odczytać aktywności: \(error.localizedDescription)"
    }
  }

  private func render(_ allocations: [ActivityAllocation]) {
    editors.removeAll()
    rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
    rows.addArrangedSubview(row([
      label("Zadanie", header: true), label("Czas", header: true),
      label("Podstawa", header: true), label("Decyzja", header: true),
    ]))
    for allocation in allocations { appendEditor(allocation) }
    if allocations.isEmpty {
      let empty = label("Brak aktywności Claude Code dla tego dnia.")
      empty.textColor = .secondaryLabelColor
      rows.addArrangedSubview(empty)
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pl_PL")
    formatter.dateFormat = "EEEE, d MMMM"
    dayTitle.stringValue = formatter.string(from: datePicker.dateValue).capitalized
    let sessions = Set(currentActivity?.events.map(\.sessionID) ?? []).count
    let events = currentActivity?.events.count ?? 0
    dayStatus.stringValue = switch reviewStatus {
    case .approved: "Zatwierdzone i zapisane w Jirze"
    case .rejected: "Podsumowanie odrzucone · możesz zmienić decyzje"
    case nil: "\(sessions) sesji · \(events) zdarzeń · wszystkie worktree razem"
    }
    let locked = reviewStatus == .approved
    editors.forEach { $0.issue.isEnabled = !locked; $0.duration.isEnabled = !locked; $0.decision.isEnabled = !locked }
    addButton.isEnabled = !locked
    rejectButton.isEnabled = !locked && !allocations.isEmpty
    updateTotals()
  }

  private func appendEditor(_ allocation: ActivityAllocation) {
    let issue = NSTextField(string: allocation.issueKey == "Nieprzypisane" ? "" : allocation.issueKey)
    issue.placeholderString = "np. ABC-123"
    issue.delegate = self
    let duration = NSTextField(string: Self.duration(allocation.minutes))
    duration.placeholderString = "GG:MM"
    duration.delegate = self
    let evidence = label(allocation.evidence == 0 ? "ręcznie" : "\(allocation.evidence) wskazań")
    evidence.textColor = .secondaryLabelColor
    let decision = NSPopUpButton(frame: .zero, pullsDown: false)
    decision.addItems(withTitles: ["Zatwierdź", "Odrzuć"])
    if allocation.issueKey == "Nieprzypisane" || reviewStatus == .rejected { decision.selectItem(at: 1) }
    decision.target = self
    decision.action = #selector(editorChanged)
    editors.append(Editor(issue: issue, duration: duration, decision: decision, evidence: allocation.evidence))
    rows.addArrangedSubview(row([issue, duration, evidence, decision]))
  }

  private func row(_ views: [NSView]) -> NSView {
    let result = NSStackView(views: views)
    result.orientation = .horizontal
    result.alignment = .centerY
    result.spacing = 12
    for (view, width) in zip(views, [250, 80, 110, 120] as [CGFloat]) {
      view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    return result
  }

  private func label(_ value: String, header: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = header ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 13)
    return field
  }

  @objc private func changeDay(_ sender: NSButton) {
    datePicker.dateValue = Calendar.current.date(byAdding: .day, value: sender.tag, to: datePicker.dateValue) ?? datePicker.dateValue
    reload()
  }

  @objc private func addReport() {
    appendEditor(ActivityAllocation(issueKey: "Nieprzypisane", minutes: 5, evidence: 0))
    editors.last?.decision.selectItem(at: 0)
    editors.last?.issue.becomeFirstResponder()
    updateTotals()
  }

  @objc private func editorChanged() { updateTotals() }

  func controlTextDidChange(_ notification: Notification) { updateTotals() }

  private func updateTotals() {
    let target = Calendar.current.isDateInWeekend(datePicker.dateValue) ? 0 : Int(settings.workdayHours * 60)
    let accepted: [ActivityAllocation]
    do {
      accepted = try acceptedAllocations()
    } catch {
      dayTotal.stringValue = "— / \(Self.duration(target)) h"
      dayTotal.textColor = .systemOrange
      saveButton.isEnabled = false
      feedback.textColor = .systemRed
      feedback.stringValue = error.localizedDescription
      return
    }
    let total = accepted.reduce(0) { $0 + $1.minutes }
    dayTotal.stringValue = "\(Self.duration(total)) / \(Self.duration(target)) h"
    dayTotal.textColor = total == target || target == 0 ? .labelColor : .systemOrange
    let locked = reviewStatus == .approved
    saveButton.isEnabled = !locked && !accepted.isEmpty
    if locked {
      feedback.textColor = .systemGreen
      feedback.stringValue = "Podsumowanie zostało już zapisane."
    } else {
      feedback.textColor = .secondaryLabelColor
      feedback.stringValue = total == target || target == 0
        ? "Gotowe do zatwierdzenia"
        : "Bilans zatwierdzonych raportów różni się od celu o \(Self.duration(abs(target - total))) h"
    }
  }

  private func acceptedAllocations() throws -> [ActivityAllocation] {
    let allocations = try editors.filter { $0.decision.indexOfSelectedItem == 0 }.map { editor in
      let issue = editor.issue.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      guard issue.range(of: #"^[A-Z][A-Z0-9]*-\d+$"#, options: .regularExpression) != nil else {
        throw EditorError.invalidIssue
      }
      guard let minutes = Self.minutes(editor.duration.stringValue) else { throw EditorError.invalidDuration }
      return ActivityAllocation(issueKey: issue, minutes: minutes, evidence: editor.evidence)
    }
    return Dictionary(grouping: allocations, by: \.issueKey).map { issue, values in
      ActivityAllocation(
        issueKey: issue,
        minutes: values.reduce(0) { $0 + $1.minutes },
        evidence: values.reduce(0) { $0 + $1.evidence }
      )
    }.sorted { $0.issueKey < $1.issueKey }
  }

  @objc private func rejectDay() {
    guard let activity = currentActivity else { return }
    do {
      try store.saveReview(day: activity.day, status: .rejected, allocations: activity.allocations)
      reviewStatus = .rejected
      render(activity.allocations)
    } catch {
      feedback.textColor = .systemRed
      feedback.stringValue = "Nie udało się odrzucić podsumowania: \(error.localizedDescription)"
    }
  }

  @objc private func saveToJira() {
    guard let activity = currentActivity else { return }
    let allocations: [ActivityAllocation]
    do {
      allocations = try acceptedAllocations()
    } catch {
      feedback.textColor = .systemRed
      feedback.stringValue = error.localizedDescription
      return
    }
    let edited = DailyActivity(day: activity.day, events: activity.events, allocations: allocations)
    let alert = NSAlert()
    alert.messageText = "Zapisać dzienne podsumowanie w Jirze?"
    alert.informativeText = allocations.map { "\($0.issueKey): \(Self.duration($0.minutes)) h" }.joined(separator: "\n")
    alert.addButton(withTitle: "Zapisz")
    alert.addButton(withTitle: "Anuluj")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    saveButton.isEnabled = false
    rejectButton.isEnabled = false
    progress.startAnimation(nil)
    feedback.textColor = .secondaryLabelColor
    feedback.stringValue = "Sprawdzam istniejące raporty w Jirze…"
    Task {
      do {
        let result = try await ActivityJiraLogger(jira: JiraClient(credentials: settings.source)).log(edited)
        try store.saveReview(day: activity.day, status: .approved, allocations: allocations)
        reviewStatus = .approved
        progress.stopAnimation(nil)
        feedback.textColor = .systemGreen
        feedback.stringValue = "Zapisano \(result.writtenMinutes) min · zgodne i pominięte: \(result.skippedIssues)"
        render(allocations)
      } catch {
        progress.stopAnimation(nil)
        rejectButton.isEnabled = true
        saveButton.isEnabled = true
        feedback.textColor = .systemRed
        feedback.stringValue = "Nie zapisano podsumowania: \(error.localizedDescription)"
      }
    }
  }

  private static func duration(_ minutes: Int) -> String {
    String(format: "%d:%02d", minutes / 60, minutes % 60)
  }

  private static func minutes(_ value: String) -> Int? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
    let minutes: Int?
    if value.contains(":") {
      let parts = value.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 2, let hours = Int(parts[0]), let remainder = Int(parts[1]), hours >= 0, (0..<60).contains(remainder) else { return nil }
      minutes = hours * 60 + remainder
    } else if let hours = Double(value), hours > 0 {
      minutes = Int((hours * 60).rounded())
    } else {
      minutes = nil
    }
    guard let minutes, (1...1_440).contains(minutes), minutes % 5 == 0 else { return nil }
    return minutes
  }

  func layoutSelfcheck() {
    window?.contentView?.layoutSubtreeIfNeeded()
    precondition(
      window?.minSize.width == 700 && rows.frame.width > 0 && saveButton.frame.height > 0 &&
        Self.minutes("1:30") == 90 && Self.minutes("1,5") == 90 && Self.minutes("1:07") == nil,
      "Okno aktywności ma nieprawidłowy układ"
    )
    print("ok")
  }
}

private enum EditorError: LocalizedError {
  case invalidIssue
  case invalidDuration

  var errorDescription: String? {
    switch self {
    case .invalidIssue: "Zatwierdzony raport wymaga klucza zadania, np. ABC-123."
    case .invalidDuration: "Czas podaj jako GG:MM lub liczbę godzin, w krokach po 5 minut."
    }
  }
}

private final class FlippedActivityView: NSView {
  override var isFlipped: Bool { true }
}
