import AppKit
import ThisIsLoggedCore

@MainActor final class SyncWindowController: NSWindowController {
  private let selectedPeriod: String
  private let rows = NSStackView()
  private let feedback = NSTextField(labelWithString: "Pobieram dane z obu instancji Jiry…")
  private let progress = NSProgressIndicator()
  private let executeButton = NSButton(title: "Synchronizuj", target: nil, action: nil)
  private var choices: [LocalDay: NSPopUpButton] = [:]
  private var engine: TimeReportEngine?
  private var plan: SyncPlan?
  private let completion: () -> Void

  init(period: String, completion: @escaping () -> Void) {
    selectedPeriod = period
    self.completion = completion
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    panel.title = "Synchronizacja — \(period)"
    panel.toolbarStyle = .unifiedCompact
    panel.toolbar = NSToolbar(identifier: "synchronization")
    panel.minSize = NSSize(width: 620, height: 420)
    super.init(window: panel)
    buildUI()
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.center()
    NSApplication.shared.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
    load()
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
      root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
      root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
      root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
    ])

    let title = NSTextField(labelWithString: "Porównanie raportów")
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    root.addArrangedSubview(title)
    let subtitle = NSTextField(labelWithString: "Różnice są domyślnie pomijane. Nadpisanie usuwa wyłącznie Twoje wpisy z wybranego dnia.")
    subtitle.textColor = .secondaryLabelColor
    root.addArrangedSubview(subtitle)

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 620, height: 1))
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 6
    rows.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(rows)
    scroll.documentView = document
    NSLayoutConstraint.activate([
      rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
      rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
      rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
      rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -10),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])
    root.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true

    feedback.textColor = .secondaryLabelColor
    feedback.lineBreakMode = .byWordWrapping
    feedback.maximumNumberOfLines = 2
    progress.style = .spinning
    progress.controlSize = .small
    progress.startAnimation(nil)
    executeButton.target = self
    executeButton.action = #selector(execute)
    executeButton.isEnabled = false
    let footer = NSStackView(views: [progress, feedback, NSView(), executeButton])
    footer.orientation = .horizontal
    footer.alignment = .centerY
    root.addArrangedSubview(footer)
    footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
  }

  private func load() {
    guard plan == nil, let range = Self.range(selectedPeriod) else {
      if plan == nil { show(error: "Nieprawidłowy okres: \(selectedPeriod)") }
      return
    }
    Task {
      do {
        let settings = try SettingsStore().load()
        let engine = TimeReportEngine.live(settings: settings)
        let plan = try await engine.syncPlan(from: range.0, to: range.1)
        self.engine = engine
        self.plan = plan
        render(plan)
      } catch {
        show(error: error.localizedDescription)
      }
    }
  }

  private func render(_ plan: SyncPlan) {
    progress.stopAnimation(nil)
    rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
    choices.removeAll()
    rows.addArrangedSubview(row(["Data", "Jira główna", "Cel", "Decyzja"], header: true))
    for item in plan.items {
      let action = NSPopUpButton(frame: .zero, pullsDown: false)
      switch item.state {
      case .add:
        action.addItem(withTitle: "Dodaj")
        action.isEnabled = false
      case .synced:
        action.addItem(withTitle: "Pomiń — zgodne")
        action.isEnabled = false
      case .collision:
        action.addItems(withTitles: ["Pomiń", "Zsumuj", "Nadpisz"])
        choices[item.day] = action
      }
      rows.addArrangedSubview(row([
        item.day.description,
        "\(hours(item.sourceSeconds)) h",
        item.targetSeconds == 0 ? "—" : "\(hours(item.targetSeconds)) h",
      ], control: action))
    }
    if plan.items.isEmpty {
      rows.addArrangedSubview(NSTextField(labelWithString: "Brak worklogów w wybranym okresie."))
    }
    let collisions = plan.items.filter { $0.state == .collision }.count
    feedback.stringValue = "\(plan.items.count) dni · różnice: \(collisions)"
    feedback.textColor = collisions == 0 ? .systemGreen : .systemOrange
    executeButton.isEnabled = plan.items.contains { $0.state == .add } || collisions > 0
  }

  private func row(_ values: [String], control: NSView? = nil, header: Bool = false) -> NSView {
    let views = values.map { value -> NSView in
      let field = NSTextField(labelWithString: value)
      field.font = header ? .systemFont(ofSize: 12, weight: .semibold) : .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      return field
    } + (control.map { [$0] } ?? [])
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    let widths: [CGFloat] = [105, 120, 120]
    for (index, width) in widths.enumerated() where index < views.count { views[index].widthAnchor.constraint(equalToConstant: width).isActive = true }
    if let control { control.widthAnchor.constraint(equalToConstant: 150).isActive = true }
    return row
  }

  @objc private func execute() {
    guard let engine, let plan else { return }
    var actions: [LocalDay: SyncAction] = [:]
    for (day, popup) in choices {
      actions[day] = popup.titleOfSelectedItem == "Nadpisz" ? .replace : popup.titleOfSelectedItem == "Zsumuj" ? .add : .skip
    }
    let writes = plan.items.filter { item in actions[item.day].map { $0 != .skip } ?? (item.state == .add) }.count
    guard writes > 0 else {
      feedback.stringValue = "Nic nie wybrano do zapisania."
      return
    }
    let alert = NSAlert()
    alert.messageText = "Zapisać \(writes) dni do \(plan.targetIssue)?"
    alert.informativeText = "Operacja zmieni worklogi w Jirze docelowej."
    alert.addButton(withTitle: "Zapisz")
    alert.addButton(withTitle: "Anuluj")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    executeButton.isEnabled = false
    progress.startAnimation(nil)
    feedback.textColor = .secondaryLabelColor
    feedback.stringValue = "Zapisuję…"
    Task {
      do {
        let result = try await engine.execute(plan, actions: actions)
        progress.stopAnimation(nil)
        feedback.textColor = .systemGreen
        feedback.stringValue = "Zapisano \(result.writtenDays) dni, \(hours(result.writtenSeconds)) h."
        completion()
      } catch {
        show(error: "Część dni mogła zostać zapisana. \(error.localizedDescription)")
      }
    }
  }

  private func show(error: String) {
    progress.stopAnimation(nil)
    executeButton.isEnabled = false
    feedback.textColor = .systemRed
    feedback.stringValue = error
  }

  private func hours(_ seconds: Int) -> String { String(format: "%.2f", Double(seconds) / 3600) }

  private static func range(_ value: String) -> (LocalDay, LocalDay)? {
    if let day = LocalDay(value) { return (day, day) }
    guard value.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil,
          let first = LocalDay("\(value)-01") else { return nil }
    return (first, first.adding(months: 1).adding(days: -1))
  }

  func layoutSelfcheck() {
    window?.contentView?.layoutSubtreeIfNeeded()
    precondition(window?.minSize.width == 620 && executeButton.frame.height > 0 && rows.frame.width > 0, "Okno synchronizacji ma nieprawidłowy układ")
    print("ok")
  }
}

private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
