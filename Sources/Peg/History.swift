import AppKit
import ImageIO

/// Reading the shots folder, and throwing away the ones nobody wants any more.
enum HistoryStore {
    /// Formats the shelf and the history will show. GIF because the recorder
    /// writes them, TIFF because plenty of apps still hand you one.
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff"]

    static func files(in folder: URL = Prefs.folderURL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { modified($0) > modified($1) }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Delete shots older than the retention window. Zero days means keep
    /// everything, which is what "never" should mean.
    @discardableResult
    static func purge(olderThanDays days: Int = Prefs.historyDays) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        for url in files() where modified(url) < cutoff {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            removed += 1
        }
        return removed
    }

    static func count(in folder: URL = Prefs.folderURL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0
    }
}

/// Every shot on disk, in one window: the thing Snipaste's history does, except
/// it survives relaunches because the files are the history.
@MainActor
final class HistoryWindow: NSWindowController {
    static let shared = HistoryWindow()

    private let scroll = NSScrollView()
    private let grid = HistoryGrid()
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private var all: [ShotItem] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "截图历史"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 420)
        window.center()
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(grid)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Header: a quiet title, a search field, and how many there are.
        let title = NSTextField(labelWithString: "截图历史")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        search.placeholderString = "搜索文件名"
        search.font = .systemFont(ofSize: 12)
        search.target = self
        search.action = #selector(searchChanged)
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right

        let header = NSStackView(views: [title, search, NSView(), countLabel])
        header.orientation = .horizontal
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let hint = NSTextField(labelWithString:
            "双击标注 · ⏎ 复制 · 空格 贴到屏幕上 · ⌫ 移到废纸篓")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            header.heightAnchor.constraint(equalToConstant: 26),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -0)
        ])

        grid.onActivate = { [weak self] item in self?.copy(item) }
        grid.onEdit = { item in HistoryWindow.edit(item) }
        grid.onPin = { item in PinController.shared.pinFile(at: item.url) }
        grid.onReveal = { item in NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        grid.onTrash = { [weak self] item in self?.trash(item) }
    }

    private func reload() {
        let items = HistoryStore.files().compactMap { url -> ShotItem? in
            guard let thumb = Thumbnailer.make(url, maxPixel: 420) else { return nil }
            return ShotItem(url: url, created: HistoryStore.modified(url), thumb: thumb)
        }
        all = items
        applyFilter()
    }

    private func applyFilter() {
        let needle = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = needle.isEmpty ? all : all.filter { $0.url.lastPathComponent.lowercased().contains(needle) }
        grid.setItems(shown)
        countLabel.stringValue = "\(shown.count) 张"
        fitWindow(to: shown.count)
    }

    /// Keep the window as tall as the shots need: a mostly empty window looks
    /// like an unfinished app.
    private func fitWindow(to count: Int) {
        guard let window, let content = window.contentView else { return }
        let usable = max(320, content.bounds.width - 32)
        let columns = max(1, Int((usable + 12) / (158 + 12)))
        let rows = max(1, (count + columns - 1) / columns)
        let gridHeight = 32 + CGFloat(rows) * (124 + 12)
        let chrome: CGFloat = 104
        let target = min(700, max(300, gridHeight + chrome))
        let delta = target - content.bounds.height
        guard abs(delta) > 2 else { return }
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        window.setFrame(frame, display: true, animate: false)
    }

    @objc private func searchChanged() {
        applyFilter()
    }

    private func copy(_ item: ShotItem) {
        Clip.copy(contentsOf: item.url)
        window?.close()
    }

    private func trash(_ item: ShotItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        all.removeAll { $0.url == item.url }
        applyFilter()
    }

    private static func edit(_ item: ShotItem) {
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        HistoryWindow.shared.window?.orderOut(nil)
        AnnotationEditor.shared.present(image: image, on: NSScreen.main)
    }
}

/// A grid of shots. Laid out by hand: a collection view would be more code for
/// the same result, and this way the spacing is exactly what it looks like.
final class HistoryGrid: NSView {
    var onActivate: ((ShotItem) -> Void)?
    var onEdit: ((ShotItem) -> Void)?
    var onPin: ((ShotItem) -> Void)?
    var onReveal: ((ShotItem) -> Void)?
    var onTrash: ((ShotItem) -> Void)?

    private var cells: [HistoryCell] = []
    private var selected = 0

    private let cellSize = NSSize(width: 158, height: 124)
    private let gap: CGFloat = 12
    private let padding: CGFloat = 16

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setItems(_ items: [ShotItem]) {
        cells.forEach { $0.removeFromSuperview() }
        cells = items.map { item in
            let cell = HistoryCell(item: item)
            cell.onActivate = { [weak self] in self?.onActivate?(item) }
            cell.onEdit = { [weak self] in self?.onEdit?(item) }
            cell.onPin = { [weak self] in self?.onPin?(item) }
            cell.onReveal = { [weak self] in self?.onReveal?(item) }
            cell.onTrash = { [weak self] in self?.onTrash?(item) }
            cell.onSelect = { [weak self] in self?.select(cell) }
            addSubview(cell)
            return cell
        }
        selected = 0
        needsLayout = true
        updateSelection()
    }

    /// The document view grows with its contents, so the available width has to
    /// come from the scroll view, not from ourselves.
    private var availableWidth: CGFloat {
        max(superview?.bounds.width ?? bounds.width, 320)
    }

    override func layout() {
        super.layout()
        guard !cells.isEmpty else { return }
        let width = availableWidth
        let columns = max(1, Int((width - padding * 2 + gap) / (cellSize.width + gap)))
        for (index, cell) in cells.enumerated() {
            let column = index % columns
            let row = index / columns
            cell.frame = NSRect(x: padding + CGFloat(column) * (cellSize.width + gap),
                                y: padding + CGFloat(row) * (cellSize.height + gap),
                                width: cellSize.width,
                                height: cellSize.height)
        }
        let rows = (cells.count + columns - 1) / columns
        setFrameSize(NSSize(width: width,
                            height: padding * 2 + CGFloat(rows) * (cellSize.height + gap)))
    }

    private func select(_ cell: HistoryCell) {
        guard let index = cells.firstIndex(where: { $0 === cell }) else { return }
        selected = index
        updateSelection()
    }

    private func updateSelection() {
        for (index, cell) in cells.enumerated() {
            cell.isSelected = index == selected
        }
    }

    private func step(_ delta: Int) {
        guard !cells.isEmpty else { return }
        let next = min(max(0, selected + delta), cells.count - 1)
        guard next != selected else { return }
        selected = next
        updateSelection()
        scrollToVisible(cells[selected].frame)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            window?.close()
        case 123: step(-1)
        case 124: step(1)
        case 126: step(-1 * max(1, columnsCount()))
        case 125: step(max(1, columnsCount()))
        case 36, 76:
            if cells.indices.contains(selected) { onActivate?(cells[selected].item) }
        case 49:
            if cells.indices.contains(selected) { onPin?(cells[selected].item) }
        case 51, 117:
            if cells.indices.contains(selected) { onTrash?(cells[selected].item) }
        default:
            super.keyDown(with: event)
        }
    }

    private func columnsCount() -> Int {
        max(1, Int((availableWidth - padding * 2 + gap) / (cellSize.width + gap)))
    }
}

/// One shot: the picture, and its name on hover.
final class HistoryCell: NSView {
    let item: ShotItem
    var isSelected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    var onActivate: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPin: (() -> Void)?
    var onReveal: (() -> Void)?
    var onTrash: (() -> Void)?
    var onSelect: (() -> Void)?

    init(item: ShotItem) {
        self.item = item
        super.init(frame: .zero)
        toolTip = item.url.lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        if event.clickCount == 2 { onEdit?() }
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1 { onActivate?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onSelect?()
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "复制") { [weak self] in self?.onActivate?() })
        menu.addItem(ClosureMenuItem(title: "标注…") { [weak self] in self?.onEdit?() })
        menu.addItem(ClosureMenuItem(title: "贴到屏幕上") { [weak self] in self?.onPin?() })
        menu.addItem(ClosureMenuItem(title: "在访达中显示") { [weak self] in self?.onReveal?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "移到废纸篓") { [weak self] in self?.onTrash?() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9)
        if isSelected {
            NSColor.systemBlue.withAlphaComponent(0.10).setFill()
        } else if hovering {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.10).setFill()
        } else {
            NSColor.textBackgroundColor.setFill()
        }
        plate.fill()

        if isSelected {
            NSColor.systemBlue.setStroke()
            plate.lineWidth = 2
            plate.stroke()
        } else {
            NSColor.separatorColor.setStroke()
            plate.lineWidth = 1
            plate.stroke()
        }

        let inset: CGFloat = 8
        let labelHeight: CGFloat = 16
        let box = NSRect(x: inset, y: inset,
                         width: bounds.width - inset * 2,
                         height: bounds.height - inset * 2 - labelHeight)
        let image = item.thumb
        let aspect = image.size.width / max(1, image.size.height)
        var rect = box
        if box.width / box.height > aspect {
            rect.size.width = box.height * aspect
            rect.origin.x = box.minX + (box.width - rect.width) / 2
        } else {
            rect.size.height = box.width / aspect
            rect.origin.y = box.minY + (box.height - rect.height) / 2
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        let name = item.url.lastPathComponent
            .replacingOccurrences(of: "Peg ", with: "")
            .replacingOccurrences(of: ".\(item.url.pathExtension)", with: "")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let text = NSAttributedString(string: name, attributes: attributes)
        text.draw(in: NSRect(x: inset, y: bounds.maxY - labelHeight - 1,
                             width: bounds.width - inset * 2, height: labelHeight))
    }
}
