import AppKit
import ThisIsLoggedCore

@MainActor final class ClaudeActivityWindowController: NSWindowController {
  private let store = ActivityStore()
  private let settings: AppSettings
  private let datePicker = NSDatePicker()
  private let summary = NSTextField(labelWithString: "")
  private let textView = NSTextView()
  private let saveButton = NSButton(title: "Zatwierdź i zapisz w Jirze", target: nil, action: nil)
  private var currentActivity: DailyActivity?

  init(settings: AppSettings) {
    self.settings = settings
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
      styleMask: [.titled, .closable, .resizable, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    panel.title = "Aktywność Claude Code"
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
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
      root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
      root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
      root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
      root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
    ])

    let title = NSTextField(labelWithString: "Co Claude widział dzisiaj")
    title.font = .systemFont(ofSize: 20, weight: .semibold)
    datePicker.datePickerStyle = .textFieldAndStepper
    datePicker.datePickerElements = [.yearMonthDay]
    datePicker.dateValue = Date()
    datePicker.target = self
    datePicker.action = #selector(reload)
    let refresh = NSButton(title: "Odśwież", target: self, action: #selector(reload))
    let header = NSStackView(views: [title, NSView(), datePicker, refresh])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    root.addArrangedSubview(header)

    summary.textColor = .secondaryLabelColor
    summary.font = .systemFont(ofSize: 13)
    root.addArrangedSubview(summary)

    textView.isEditable = false
    textView.isSelectable = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.textContainerInset = NSSize(width: 10, height: 10)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = textView
    root.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    saveButton.target = self
    saveButton.action = #selector(saveToJira)
    let footer = NSStackView(views: [NSView(), saveButton])
    footer.orientation = .horizontal
    footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    root.addArrangedSubview(footer)
    scroll.heightAnchor.constraint(equalTo: root.heightAnchor, constant: -122).isActive = true
  }

  @objc private func reload() {
    do {
      let weekend = Calendar.current.isDateInWeekend(datePicker.dateValue)
      let activity = try store.activity(
        on: datePicker.dateValue,
        targetMinutes: weekend ? 0 : Int(settings.workdayHours * 60)
      )
      currentActivity = activity
      summary.stringValue = "\(activity.events.count) zdarzeń · \(Set(activity.events.map(\.sessionID)).count) sesji · wszystkie worktree razem"
      var lines = ["PROPOZYCJA CZASU (zaokrąglenie do 5 min)"]
      if activity.allocations.isEmpty {
        lines.append("Brak aktywności do rozliczenia.")
      } else {
        lines += activity.allocations.map {
          let hours = Double($0.minutes) / 60
          return "\($0.issueKey): \(String(format: "%.2f", hours)) h   (\($0.evidence) wskazań)"
        }
      }
      lines += ["", "ZDARZENIA"]
      let formatter = DateFormatter()
      formatter.dateFormat = "HH:mm:ss"
      for event in activity.events.reversed() {
        let issue = event.issueKey.map { " [\($0)]" } ?? ""
        let context = event.branch.map { " · \($0)" } ?? ""
        lines.append("\(formatter.string(from: event.occurredAt))  \(event.kind)\(issue)\(context)")
        if let text = event.text, !text.isEmpty {
          lines.append("  " + text.replacingOccurrences(of: "\n", with: "\n  "))
        }
      }
      textView.string = lines.joined(separator: "\n")
      saveButton.isEnabled = activity.allocations.contains { $0.issueKey != "Nieprzypisane" && $0.minutes > 0 }
    } catch {
      currentActivity = nil
      saveButton.isEnabled = false
      summary.stringValue = "Nie udało się odczytać aktywności"
      textView.string = error.localizedDescription
    }
  }

  @objc private func saveToJira() {
    guard let activity = currentActivity else { return }
    let assigned = activity.allocations.filter { $0.issueKey != "Nieprzypisane" }
    let unassigned = activity.allocations.first { $0.issueKey == "Nieprzypisane" }?.minutes ?? 0
    let alert = NSAlert()
    alert.messageText = "Zapisać propozycję w Jirze?"
    alert.informativeText = assigned.map { "\($0.issueKey): \(String(format: "%.2f", Double($0.minutes) / 60)) h" }.joined(separator: "\n")
      + (unassigned > 0 ? "\n\nNieprzypisane: \(String(format: "%.2f", Double(unassigned) / 60)) h — ta część nie zostanie zapisana." : "")
    alert.addButton(withTitle: "Zapisz")
    alert.addButton(withTitle: "Anuluj")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    saveButton.isEnabled = false
    summary.stringValue = "Sprawdzam istniejące worklogi przed zapisem…"
    let settings = self.settings
    Task.detached {
      do {
        let result = try await ActivityJiraLogger(jira: JiraClient(credentials: settings.source)).log(activity)
        await MainActor.run {
          self.summary.stringValue = "Zapisano \(result.writtenMinutes) min w \(result.writtenIssues) zadaniach · pominięto zgodne: \(result.skippedIssues)"
          self.saveButton.isEnabled = true
        }
      } catch {
        await MainActor.run {
          self.summary.stringValue = "Zapis nie został dokończony: \(error.localizedDescription)"
          self.saveButton.isEnabled = true
        }
      }
    }
  }
}
