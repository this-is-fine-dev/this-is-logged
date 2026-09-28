import AppKit
import ThisIsLoggedCore

@MainActor final class SyncViewController: NSViewController {
  private var selectedPeriod: String
  private let rows = FlippedSyncStackView()
  private let dayPicker = NSDatePicker(frame: .zero)
  private let refreshButton = NSButton(title: "Odśwież", target: nil, action: nil)
  private let periodLabel = NSTextField(labelWithString: "")
  private var loadTask: Task<Void, Never>?
  private var writing = false
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
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 500))
    buildUI()
  }

  func showPeriod(_ period: String) {
    guard !writing else { return }
    selectedPeriod = period
    dayPicker.dateValue = LocalDay(period)?.date ?? Date()
  }

  @objc func refresh() {
    guard !writing else { return }
    loadTask?.cancel()
    plan = nil
    engine = nil
    executeButton.isEnabled = false
    choices.removeAll()
    rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
    periodLabel.stringValue = "Okres: \(selectedPeriod)"
    progress.startAnimation(nil)
    feedback.textColor = .secondaryLabelColor
    feedback.stringValue = "Pobieram dane z obu instancji Jiry…"
    load()
  }

  private func buildUI() {
    let content = view
    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 12
    root.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(root)
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
      root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
      root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
    ])

    let title = NSTextField(labelWithString: "Synchronizacja")
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    root.addArrangedSubview(title)
    let subtitle = NSTextField(wrappingLabelWithString: "Porównaj godziny w obu Jirach i uzupełnij braki wybranego dnia.")
    subtitle.textColor = .secondaryLabelColor
    root.addArrangedSubview(subtitle)
    subtitle.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    dayPicker.datePickerElements = .yearMonthDay
    dayPicker.datePickerStyle = .textFieldAndStepper
    dayPicker.locale = Locale(identifier: "pl_PL")
    dayPicker.dateValue = LocalDay(selectedPeriod)?.date ?? Date()
    dayPicker.target = self
    dayPicker.action = #selector(dayChanged)
    refreshButton.target = self
    refreshButton.action = #selector(refresh)
    let dayRow = NSStackView(views: [NSTextField(labelWithString: "Pokaż dzień"), dayPicker, NSView(), refreshButton])
    dayRow.orientation = .horizontal
    dayRow.alignment = .centerY
    dayRow.spacing = 10
    root.addArrangedSubview(dayRow)
    dayRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    periodLabel.font = .systemFont(ofSize: 12)
    periodLabel.stringValue = "Okres: \(selectedPeriod)"
    root.addArrangedSubview(periodLabel)

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 6
    rows.frame = NSRect(x: 0, y: 0, width: 500, height: 1)
    rows.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    rows.autoresizingMask = [.width]
    scroll.documentView = rows
    root.addArrangedSubview(scroll)
    scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

    feedback.textColor = .secondaryLabelColor
    feedback.lineBreakMode = .byWordWrapping
    feedback.maximumNumberOfLines = 2
    feedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
    loadTask = Task {
      do {
        let settings = try SettingsStore().load()
        guard settings.synchronizationEnabled else {
          show(error: "Połącz drugą Jirę w zakładce Połączenia i zapisz ustawienia.")
          return
        }
        guard !settings.isOnVacation() else {
          throw NSError(domain: "ThisIsLogged", code: 4, userInfo: [NSLocalizedDescriptionKey: "Synchronizacja jest wyłączona na czas urlopu."])
        }
        let engine = TimeReportEngine.live(settings: settings)
        let plan = try await engine.syncPlan(from: range.0, to: range.1)
        try Task.checkCancellation()
        self.engine = engine
        self.plan = plan
        render(plan)
      } catch {
        guard !Task.isCancelled else { return }
        show(error: error.localizedDescription)
      }
    }
  }

  private func render(_ plan: SyncPlan) {
    self.plan = plan
    progress.stopAnimation(nil)
    rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
    choices.removeAll()
    let additions = plan.items.filter { $0.state == .add }
    let collisions = plan.items.filter { $0.state == .collision }
    rows.addArrangedSubview(row(["Data", "Jira główna", "Cel", "Stan / decyzja"], header: true))
    for item in plan.items {
      let action: NSView
      if item.state == .collision {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        if plan.cachedSourceAt != nil {
          popup.addItem(withTitle: "Zostaw — źródło offline")
          popup.isEnabled = false
        } else if item.sourceSeconds == 0 {
          popup.addItems(withTitles: ["Zostaw bez zmian", "Usuń wpisy z docelowej"])
          popup.target = self
          popup.action = #selector(choiceChanged)
          choices[item.day] = popup
        } else {
          popup.addItems(withTitles: ["Zostaw bez zmian", "Dodaj czas ze źródła", "Ustaw jak w głównej Jirze"])
          popup.target = self
          popup.action = #selector(choiceChanged)
          choices[item.day] = popup
        }
        action = popup
      } else {
        action = NSTextField(labelWithString: item.state == .add
          ? "Uzupełnij o \(hours(item.secondsToAdd)) h"
          : "Zsynchronizowane")
      }
      rows.addArrangedSubview(row([
        item.day.description,
        "\(hours(item.sourceSeconds)) h",
        item.targetSeconds == 0 ? "—" : "\(hours(item.targetSeconds)) h",
      ], control: action))
    }
    if plan.items.isEmpty {
      rows.addArrangedSubview(NSTextField(labelWithString: "Brak godzin w Jirze głównej dla wybranego okresu."))
    }
    feedback.stringValue = plan.items.isEmpty ? "Brak wpisów w obu Jirach." : additions.isEmpty && collisions.isEmpty
      ? "Wszystko jest zsynchronizowane."
      : "Do uzupełnienia: \(additions.count) · do wyjaśnienia: \(collisions.count)"
    if let timestamp = plan.cachedSourceAt {
      feedback.stringValue += " · źródło z pamięci: \(timestamp)"
    }
    feedback.textColor = additions.isEmpty && collisions.isEmpty ? .systemGreen : .systemOrange
    executeButton.isEnabled = !additions.isEmpty
    resizeDocument()
  }

  private func resizeDocument() {
    rows.layoutSubtreeIfNeeded()
    rows.setFrameSize(NSSize(width: rows.frame.width, height: rows.fittingSize.height))
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
    row.spacing = 8
    let widths: [CGFloat] = [76, 76, 60]
    for (index, width) in widths.enumerated() where index < views.count { views[index].widthAnchor.constraint(equalToConstant: width).isActive = true }
    if let control { control.widthAnchor.constraint(equalToConstant: 205).isActive = true }
    return row
  }

  @objc private func choiceChanged() {
    executeButton.isEnabled = plan?.items.contains { $0.state == .add } == true || choices.values.contains { $0.indexOfSelectedItem > 0 }
  }

  @objc private func dayChanged() {
    selectedPeriod = LocalDay(dayPicker.dateValue).description
    refresh()
  }

  @objc private func execute() {
    guard let engine, let plan else { return }
    var actions: [LocalDay: SyncAction] = [:]
    for (day, popup) in choices {
      let sourceIsEmpty = plan.items.first { $0.day == day }?.sourceSeconds == 0
      actions[day] = popup.indexOfSelectedItem == 0 ? .skip
        : sourceIsEmpty ? .replace
        : popup.indexOfSelectedItem == 2 ? .replace : .add
    }
    let writes = plan.items.filter { $0.state == .add }.count + actions.values.filter { $0 != .skip }.count
    guard writes > 0 else {
      feedback.stringValue = "Nic nie wybrano do zapisania."
      return
    }
    let alert = NSAlert()
    alert.messageText = "Zapisać \(writes) dni do \(plan.targetIssue)?"
    alert.informativeText = actions.values.contains(.replace)
      ? "Ustawienie wartości jak w głównej Jirze usunie wyłącznie Twoje wpisy z wybranych dni."
      : "Operacja dopisze czas ze źródła do Jiry docelowej."
    if let timestamp = plan.cachedSourceAt {
      alert.informativeText += " Źródło jest niedostępne; używam godzin pobranych \(timestamp)."
    }
    alert.addButton(withTitle: "Zapisz")
    alert.addButton(withTitle: "Anuluj")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    writing = true
    dayPicker.isEnabled = false
    refreshButton.isEnabled = false
    executeButton.isEnabled = false
    progress.startAnimation(nil)
    feedback.textColor = .secondaryLabelColor
    feedback.stringValue = "Zapisuję…"
    Task {
      defer {
        writing = false
        dayPicker.isEnabled = true
        refreshButton.isEnabled = true
      }
      do {
        guard !(try SettingsStore().load()).isOnVacation() else {
          show(error: "Synchronizacja jest wyłączona na czas urlopu.")
          return
        }
        let result = try await engine.execute(plan, actions: actions)
        do {
          let refreshedPlan = try await engine.syncPlan(from: plan.from, to: plan.to)
          didExecute(result, refreshedPlan: refreshedPlan)
        } catch {
          progress.stopAnimation(nil)
          feedback.textColor = .systemOrange
          feedback.stringValue = "Zapisano \(result.writtenDays) dni, \(hours(result.writtenSeconds)) h, ale nie udało się potwierdzić nowych wartości. Kliknij Odśwież."
          completion()
        }
      } catch {
        show(error: "Część dni mogła zostać zapisana. \(error.localizedDescription)")
      }
    }
  }

  private func didExecute(_ result: SyncResult, refreshedPlan: SyncPlan) {
    plan = refreshedPlan
    render(refreshedPlan)
    feedback.textColor = .systemGreen
    feedback.stringValue = "Zapisano \(result.writtenDays) dni, \(hours(result.writtenSeconds)) h · dane potwierdzone w Jirze."
    completion()
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
    _ = view
    let plan = try! JSONDecoder().decode(SyncPlan.self, from: Data(#"{"from":"2026-09-07","to":"2026-09-07","targetIssue":"AUT-1","items":[{"day":"2026-09-07","sourceSeconds":28800,"targetSeconds":36000,"issueKeys":["RPR-1"],"targetWorklogIDs":["old-1"],"state":"collision"}]}"#.utf8))
    render(plan)
    view.layoutSubtreeIfNeeded()
    rows.layoutSubtreeIfNeeded()
    let renderedViews = rows.arrangedSubviews.flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [] }
    let viewport = rows.enclosingScrollView!.contentView
    precondition(
      dayPicker.frame.height > 0 && executeButton.frame.height > 0 && rows.frame.width > 0 && rows.frame.height > 30 &&
        renderedViews.count == 8 && renderedViews.allSatisfy {
          let frame = viewport.convert($0.bounds, from: $0)
          return frame.height > 0 && frame.minX >= 0 && frame.maxX <= viewport.bounds.width
        } && view.bounds.contains(view.convert(dayPicker.bounds, from: dayPicker)) &&
        view.bounds.contains(view.convert(executeButton.bounds, from: executeButton)),
      "Okno synchronizacji ma nieprawidłowy układ"
    )
    choices.values.first?.selectItem(at: 1)
    choiceChanged()
    precondition(executeButton.isEnabled, "Wybór decyzji nie aktywuje zapisu")
    let topUpPlan = try! JSONDecoder().decode(SyncPlan.self, from: Data(#"{"from":"2026-09-07","to":"2026-09-07","targetIssue":"AUT-1","items":[{"day":"2026-09-07","sourceSeconds":28800,"targetSeconds":14400,"issueKeys":["RPR-1"],"targetWorklogIDs":["old-1"],"state":"add"}]}"#.utf8))
    render(topUpPlan)
    precondition(rows.arrangedSubviews.count == 2 && executeButton.isEnabled, "Bezpieczne uzupełnienia powinny być gotowe do zapisu")
    let syncedPlan = try! JSONDecoder().decode(SyncPlan.self, from: Data(#"{"from":"2026-09-07","to":"2026-09-07","targetIssue":"AUT-1","items":[{"day":"2026-09-07","sourceSeconds":28800,"targetSeconds":28800,"issueKeys":["RPR-1"],"targetWorklogIDs":["old-1","new-1"],"state":"synced"}]}"#.utf8))
    didExecute(SyncResult(writtenDays: 1, writtenSeconds: 14400, collisionsSkipped: 0), refreshedPlan: syncedPlan)
    precondition(
      rows.arrangedSubviews.count == 2 && !executeButton.isEnabled,
      "Okno nie pokazuje wyniku zakończonej synchronizacji"
    )
    print("ok")
  }
}

private final class FlippedSyncStackView: NSStackView {
  nonisolated override var isFlipped: Bool { true }
}
