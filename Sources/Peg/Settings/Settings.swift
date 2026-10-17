import AppKit
import UniformTypeIdentifiers

/// Everything the user can change, remembered between launches.
enum Prefs {
    enum Format: String, CaseIterable {
        case png, jpeg

        var title: String {
            switch self {
            case .png: return "PNG 无损"
            case .jpeg: return "JPEG 小体积"
            }
        }

        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            }
        }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }
    }

    static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Peg", isDirectory: true)
    }

    static var folderURL: URL {
        get {
            let path = UserDefaults.standard.string(forKey: "saveFolder") ?? defaultFolder.path
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "saveFolder")
        }
    }

    static func ensureFolder() -> URL {
        let url = folderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var format: Format {
        get { Format(rawValue: UserDefaults.standard.string(forKey: "saveFormat") ?? "png") ?? .png }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "saveFormat") }
    }

    /// 0.5 ... 1.0, only used for JPEG.
    static var quality: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "saveQuality")
            return value > 0 ? value : 0.92
        }
        set { UserDefaults.standard.set(newValue, forKey: "saveQuality") }
    }

    /// Days to keep shots on disk; 0 means keep everything.
    static var historyDays: Int {
        get {
            UserDefaults.standard.object(forKey: "historyDays") == nil
                ? 30
                : UserDefaults.standard.integer(forKey: "historyDays")
        }
        set { UserDefaults.standard.set(newValue, forKey: "historyDays") }
    }

    /// Show Peg in the Dock as well as the menu bar.
    static var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: "showInDock") }
        set { UserDefaults.standard.set(newValue, forKey: "showInDock") }
    }

    /// Round the corners of every capture. On unless the user turns it off.
    static var roundedCorners: Bool {
        get { UserDefaults.standard.object(forKey: "roundedCorners") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "roundedCorners") }
    }

    /// Copy every snip to the clipboard without being asked.
    static var autoCopy: Bool {
        get { UserDefaults.standard.object(forKey: "autoCopy") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCopy") }
    }
}

/// A plain settings window: where shots go, what format, and clipboard habits.
@MainActor
final class SettingsWindow: NSWindowController {
    static let shared = SettingsWindow()

    private let folderLabel = NSTextField(labelWithString: "")
    private let formatControl = NSSegmentedControl(labels: Prefs.Format.allCases.map { $0.title },
                                                   trackingMode: .selectOne,
                                                   target: nil,
                                                   action: nil)
    private let qualityRow = NSStackView()
    private let qualitySlider = NSSlider(value: Prefs.quality, minValue: 0.5, maxValue: 1, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "")
    private let copyCheck = NSButton(checkboxWithTitle: "截图后自动复制到剪贴板", target: nil, action: nil)
    private let roundCheck = NSButton(checkboxWithTitle: "截图四角改成圆角", target: nil, action: nil)
    private var shortcutButtons: [ShortcutAction: ShortcutRecorderButton] = [:]
    private let retentionPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 812),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Peg 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20)
        ])

        // Where screenshots go.
        let folderTitle = NSTextField(labelWithString: "保存位置")
        folderTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let choose = NSButton(title: "选择…", target: self, action: #selector(chooseFolder))
        let reveal = NSButton(title: "打开", target: self, action: #selector(revealFolder))
        let folderRow = NSStackView(views: [folderLabel, NSView(), choose, reveal])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8

        // Format and quality.
        let formatTitle = NSTextField(labelWithString: "保存格式")
        formatTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        formatControl.target = self
        formatControl.action = #selector(formatChanged)
        formatControl.segmentStyle = .rounded

        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.isContinuous = true
        qualitySlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        qualityLabel.textColor = .secondaryLabelColor
        qualityRow.setViews([NSTextField(labelWithString: "质量"), qualitySlider, qualityLabel], in: .leading)
        qualityRow.orientation = .horizontal
        qualityRow.spacing = 10

        // History retention.
        let historyTitle = NSTextField(labelWithString: "历史保留")
        historyTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        retentionPopup.addItems(withTitles: ["7 天", "30 天", "90 天", "永久保留"])
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)
        let retentionRow = NSStackView(views: [retentionPopup,
                                               NSTextField(labelWithString: "之后的截图会自动移到废纸篓")])
        retentionRow.orientation = .horizontal
        retentionRow.spacing = 10
        (retentionRow.arrangedSubviews[1] as? NSTextField)?.textColor = .secondaryLabelColor
        (retentionRow.arrangedSubviews[1] as? NSTextField)?.font = .systemFont(ofSize: 11)

        // Clipboard.
        let clipTitle = NSTextField(labelWithString: "剪贴板")
        clipTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        copyCheck.target = self
        copyCheck.action = #selector(copyChanged)
        roundCheck.target = self
        roundCheck.action = #selector(roundChanged)

        // Shortcuts, one row per action.
        let shortcutTitle = NSTextField(labelWithString: "快捷键")
        shortcutTitle.font = .systemFont(ofSize: 12, weight: .semibold)

        var shortcutRows: [NSView] = []
        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            label.font = .systemFont(ofSize: 12)
            let button = ShortcutRecorderButton(shortcut: ShortcutStore.shortcut(for: action))
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
            button.onCapture = { [weak self] captured in
                self?.capture(captured, for: action)
            }
            shortcutButtons[action] = button
            let row = NSStackView(views: [label, NSView(), button])
            row.orientation = .horizontal
            row.spacing = 8
            shortcutRows.append(row)
        }

        let resetShortcuts = NSButton(title: "恢复默认", target: self, action: #selector(resetShortcuts))
        resetShortcuts.bezelStyle = .inline
        resetShortcuts.controlSize = .small

        let resetRow = NSStackView(views: [resetShortcuts, NSView()])
        resetRow.orientation = .horizontal

        let note = NSTextField(wrappingLabelWithString:
            "标注时　1–8 选工具　⏎ 完成　P 贴到屏幕　L 长截图　Esc 取消")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        for view in [folderTitle, folderRow, formatTitle, formatControl, qualityRow,
                     historyTitle, retentionRow, clipTitle, copyCheck, roundCheck,
                     shortcutTitle] + shortcutRows + [resetRow, note] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func refresh() {
        folderLabel.stringValue = (Prefs.folderURL.path as NSString).abbreviatingWithTildeInPath
        formatControl.selectedSegment = Prefs.format == .png ? 0 : 1
        formatControl.setWidth(110, forSegment: 0)
        formatControl.setWidth(110, forSegment: 1)
        qualitySlider.doubleValue = Prefs.quality
        qualityLabel.stringValue = "\(Int((Prefs.quality * 100).rounded()))%"
        qualityRow.isHidden = Prefs.format != .jpeg
        let days = Prefs.historyDays
        retentionPopup.selectItem(at: days == 0 ? 3 : days <= 7 ? 0 : days <= 30 ? 1 : 2)
        copyCheck.state = Prefs.autoCopy ? .on : .off
        roundCheck.state = Prefs.roundedCorners ? .on : .off
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.folderURL
        panel.prompt = "选这个文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Prefs.folderURL = url
        _ = Prefs.ensureFolder()
        refresh()
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.open(Prefs.ensureFolder())
    }

    @objc private func formatChanged() {
        Prefs.format = formatControl.selectedSegment == 0 ? .png : .jpeg
        refresh()
    }

    @objc private func qualityChanged() {
        Prefs.quality = qualitySlider.doubleValue
        qualityLabel.stringValue = "\(Int((Prefs.quality * 100).rounded()))%"
    }

    @objc private func retentionChanged() {
        let values = [7, 30, 90, 0]
        Prefs.historyDays = values[max(0, min(3, retentionPopup.indexOfSelectedItem))]
        _ = HistoryStore.purge()
    }

    private func capture(_ shortcut: Shortcut?, for action: ShortcutAction) {
        guard let shortcut else {
            shortcutButtons[action]?.setShortcut(ShortcutStore.shortcut(for: action))
            return
        }
        guard ShortcutStore.set(shortcut, for: action) else {
            // Someone else already owns it: point at the collision.
            NSSound.beep()
            let owner = ShortcutStore.bindings.first { $0.value == shortcut }?.key
            let alert = NSAlert()
            alert.messageText = "这个快捷键已经被「\(owner?.title ?? "其它动作")」占用"
            alert.addButton(withTitle: "好")
            alert.runModal()
            shortcutButtons[action]?.setShortcut(ShortcutStore.shortcut(for: action))
            return
        }
        AppDelegate.shared?.reloadHotKeys()
        refreshShortcutTitles()
    }

    @objc private func resetShortcuts() {
        ShortcutStore.reset()
        AppDelegate.shared?.reloadHotKeys()
        refreshShortcutTitles()
    }

    private func refreshShortcutTitles() {
        for action in ShortcutAction.allCases {
            shortcutButtons[action]?.setShortcut(ShortcutStore.shortcut(for: action))
        }
    }

    @objc private func roundChanged() {
        Prefs.roundedCorners = roundCheck.state == .on
    }

    @objc private func copyChanged() {
        Prefs.autoCopy = copyCheck.state == .on
    }
}
