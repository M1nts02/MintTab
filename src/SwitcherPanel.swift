import AppKit

// ============================================================
// MARK: - Layout Constants
// ============================================================

private enum Layout {
    static let cornerRadius: CGFloat = 16
    static let selectionRingWidth: CGFloat = 3
    static let selectionColor = NSColor.controlAccentColor
    static let panelPadding: CGFloat = 20
    static let groupRowGap: CGFloat = 8
    static let groupLabelWidth: CGFloat = 56
    static let groupLabelFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    /// Return size-dependent layout values.
    static func values(for size: MintTabConfig.UISize) -> LayoutValues {
        switch size {
        case .small:
            return LayoutValues(
                iconSize: 84, iconPadding: 18,
                listIconSize: 54, listItemWidth: 330, listItemHeight: 60,
                listTitleFontSize: 20, listIconTitleGap: 12)
        case .medium:
            return LayoutValues(
                iconSize: 108, iconPadding: 24,
                listIconSize: 66, listItemWidth: 420, listItemHeight: 78,
                listTitleFontSize: 23, listIconTitleGap: 18)
        case .large:
            return LayoutValues(
                iconSize: 132, iconPadding: 30,
                listIconSize: 78, listItemWidth: 510, listItemHeight: 96,
                listTitleFontSize: 26, listIconTitleGap: 24)
        }
    }
}

struct LayoutValues {
    let iconSize: CGFloat
    let iconPadding: CGFloat
    let listIconSize: CGFloat
    let listItemWidth: CGFloat
    let listItemHeight: CGFloat
    let listTitleFontSize: CGFloat
    let listIconTitleGap: CGFloat
    var titleFontSize: CGFloat { round(iconSize * 0.22) }
    var titleHeight: CGFloat { titleFontSize * 2 }
}

// ============================================================
// MARK: - Icon View
// ============================================================

private class IconView: NSView {
    let imageView = NSImageView()
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    var onMouseDown: (() -> Void)?
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?

    private var mouseDownPoint: NSPoint = .zero
    private var didDrag = false

    init(icon: NSImage?, size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = bounds.insetBy(dx: 4, dy: 4)
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(ta)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - mouseDownPoint.x) > 3 || abs(p.y - mouseDownPoint.y) > 3 {
            didDrag = true
            onDrag?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            onMouseDown?()
        }
        didDrag = false
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected {
            Layout.selectionColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
            path.lineWidth = Layout.selectionRingWidth
            path.stroke()
        }
    }
}

// ============================================================
// MARK: - List Item View
// ============================================================

private class ListItemView: NSView {
    let iconView = NSImageView()
    let titleLabel = NSTextField()
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    var onMouseDown: (() -> Void)?
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?

    init(icon: NSImage?, title: String, layout: LayoutValues) {
        super.init(frame: NSRect(x: 0, y: 0, width: layout.listItemWidth, height: layout.listItemHeight))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(ta)

        let iconY = (layout.listItemHeight - layout.listIconSize) / 2
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 6, y: iconY, width: layout.listIconSize, height: layout.listIconSize)
        addSubview(iconView)

        let titleX = layout.listIconSize + layout.listIconTitleGap + 6
        let titleWidth = layout.listItemWidth - titleX - 8
        let titleHeight = layout.listTitleFontSize + 8
        let titleY = (layout.listItemHeight - titleHeight) / 2
        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: layout.listTitleFontSize)
        titleLabel.alignment = .center
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.textColor = NSColor.labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.frame = NSRect(x: titleX, y: titleY, width: titleWidth, height: titleHeight)
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelected {
            Layout.selectionColor.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            path.lineWidth = Layout.selectionRingWidth
            path.stroke()
        }
    }
}

// ============================================================
// MARK: - Switcher Content View
// ============================================================

private class SwitcherContentView: NSView, NSDraggingSource {
    private var itemViews: [NSView] = []
    private let titleLabel = NSTextField()
    private var displayTitles: [String] = []
    /// Maps entry index → itemViews index for grouped mode.
    private var entryToViewIndex: [Int: Int] = [:]
    var style: MintTabConfig.UIStyle = .icons
    var lv: LayoutValues = Layout.values(for: .medium)
    var selectedEntryIndex: Int = 0 {
        didSet { updateSelection() }
    }
    var onIconClick: ((Int) -> Void)?
    var onKeyEvent: ((String) -> Void)?  // "tab", "shiftTab", "escape", "enter", "up", "down"
    var kbSelectedIndex: Int = 0 { didSet { if !mouseActive { selectedEntryIndex = kbSelectedIndex } } }
    private var mouseActive = false
    var onDropToGroup: ((Int, Int) -> Void)?  // (entryIndex, targetGroup)

    static let dragType = NSPasteboard.PasteboardType("com.minttab.icon-drag")
    private var dragEntryIdx: Int = -1

    override var acceptsFirstResponder: Bool { true }

    func restoreKbSelection() {
        mouseActive = false
        selectedEntryIndex = kbSelectedIndex
    }

    func markKbSelection(_ idx: Int) {
        kbSelectedIndex = idx
        mouseActive = false
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.dragType])
        titleLabel.alignment = .center
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.textColor = NSColor.labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isHidden = true
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateTitleLabel(text: String) {
        guard style == .icons else { return }
        titleLabel.stringValue = text
        titleLabel.font = NSFont.systemFont(ofSize: lv.titleFontSize, weight: .medium)
        titleLabel.isHidden = false
    }

    func update(with entries: [AppEntry]) {
        buildViews(entries: entries)
    }

    /// Grouped display: each section gets a label row + icon row.
    func updateGrouped(sections: [(group: Int, label: String, entries: [AppEntry])]) {
        // Build flat list of entry→view, with group labels inserted
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews.removeAll()

        entryToViewIndex = [:]

        var flatIndex = 0
        for section in sections {
            // Icons for this group
            for entry in section.entries {
                let iconSize = lv.iconSize
                let resizedIcon = resizedImage(
                    entry.icon, to: NSSize(width: iconSize - 8, height: iconSize - 8))
                let view = IconView(icon: resizedIcon, size: iconSize)
                let viewIdx = itemViews.count
                let capIdx = flatIndex
                view.onMouseDown = { [weak self] in self?.onIconClick?(capIdx) }
                view.onMouseEnter = { [weak self] in self?.mouseActive = true; self?.selectedEntryIndex = capIdx }
                view.onMouseExit = { [weak self] in self?.restoreKbSelection() }
                view.onDrag = { [weak self] event in self?.startDrag(forEntryIndex: capIdx, event: event) }
                itemViews.append(view)
                addSubview(view)
                entryToViewIndex[flatIndex] = viewIdx


                flatIndex += 1
            }
        }

        displayTitles = sections.flatMap { $0.entries }.map { $0.displayTitle }
        updateTitleLabel(text: displayTitles.first ?? "")

        updateSelection()
    }

    private func buildViews(entries: [AppEntry]) {
        let L = lv
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews.removeAll()

        displayTitles = entries.map { $0.displayTitle }

        if style == .list {
            titleLabel.isHidden = true
            for entry in entries {
                let resizedIcon = resizedImage(
                    entry.icon, to: NSSize(width: L.listIconSize - 8, height: L.listIconSize - 8))
                let view = ListItemView(icon: resizedIcon, title: entry.displayTitle, layout: L)
                let ei2 = itemViews.count
                view.onMouseDown = { [weak self] in self?.onIconClick?(ei2) }
                view.onMouseEnter = { [weak self] in self?.mouseActive = true; self?.selectedEntryIndex = ei2 }
                view.onMouseExit = { [weak self] in self?.restoreKbSelection() }
                itemViews.append(view)
                addSubview(view)

            }
        } else {
            for entry in entries {
                let iconSize = L.iconSize
                let resizedIcon = resizedImage(
                    entry.icon, to: NSSize(width: iconSize - 8, height: iconSize - 8))
                let view = IconView(icon: resizedIcon, size: iconSize)
                let ei1 = itemViews.count
                view.onMouseDown = { [weak self] in self?.onIconClick?(ei1) }
                view.onMouseEnter = { [weak self] in self?.mouseActive = true; self?.selectedEntryIndex = ei1 }
                view.onMouseExit = { [weak self] in self?.restoreKbSelection() }
                itemViews.append(view)
                addSubview(view)

            }
            updateTitleLabel(text: displayTitles.first ?? "")
        }

        updateSelection()
    }

    private func resizedImage(_ image: NSImage?, to size: NSSize) -> NSImage? {
        guard let image else { return nil }
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
    }

    func updateSelection() {
        let highlightIdx = entryToViewIndex[selectedEntryIndex] ?? selectedEntryIndex

        for (index, view) in itemViews.enumerated() {
            if let iconView = view as? IconView {
                iconView.isSelected = (index == highlightIdx)
            } else if let listView = view as? ListItemView {
                listView.isSelected = (index == highlightIdx)
            }
        }
        // Update title (icons mode only; list mode has its own per-item titles)
        if style == .icons, selectedEntryIndex >= 0, selectedEntryIndex < displayTitles.count {
            updateTitleLabel(text: displayTitles[selectedEntryIndex])
        }
    }

    // MARK: - Layouts

    func layoutFlat() {
        let L = lv
        let count = itemViews.count
        guard count > 0 else { return }
        let itemWidth = (style == .list) ? L.listItemWidth : L.iconSize
        let itemHeight = (style == .list) ? L.listItemHeight : L.iconSize
        let gap = L.iconPadding
        let titleH: CGFloat = (style == .list) ? 0 : L.titleHeight

        if style == .list {
            let totalHeight = CGFloat(count) * itemHeight + CGFloat(max(count - 1, 0)) * gap
            let yStart: CGFloat = (bounds.height - totalHeight) / 2
            let x: CGFloat = (bounds.width - itemWidth) / 2
            for (i, view) in itemViews.enumerated() {
                let y = yStart + CGFloat(count - 1 - i) * (itemHeight + gap)
                view.frame = NSRect(x: x, y: y, width: itemWidth, height: itemHeight)
            }
        } else {
            let totalWidth = CGFloat(count) * itemWidth + CGFloat(count - 1) * gap
            let iconsTop = (bounds.height - itemHeight - titleH) / 2 + titleH + 4
            var x: CGFloat = (bounds.width - totalWidth) / 2
            let y: CGFloat = iconsTop
            for view in itemViews {
                view.frame = NSRect(x: x, y: y, width: itemWidth, height: itemHeight)
                x += itemWidth + gap
            }
            titleLabel.frame = NSRect(x: Layout.panelPadding, y: 4,
                width: bounds.width - Layout.panelPadding * 2, height: titleH)
        }
    }

    /// Layout for grouped (show all) mode: vertical stack of rows.
    func layoutGrouped(sections: [(group: Int, label: String, entries: [AppEntry])]) {
        let L = lv
        // Build section view starts
        var sectionViewStart: [(Int, Int)] = []
        var viewIdx = 0
        for section in sections {
            let vc = section.entries.count
            sectionViewStart.append((viewIdx, vc))
            viewIdx += vc
        }

        var maxRowWidth: CGFloat = 0
        for section in sections {
            let rowW = CGFloat(section.entries.count) * L.iconSize
                + CGFloat(max(section.entries.count - 1, 0)) * L.iconPadding
            if rowW > maxRowWidth { maxRowWidth = rowW }
        }

        let rowHeight = L.iconSize
        let titleH = L.titleHeight
        let titleGap: CGFloat = 6
        let rowGap = Layout.groupRowGap
        let rowsHeight = CGFloat(sections.count) * rowHeight
            + CGFloat(max(sections.count - 1, 0)) * rowGap
        let totalHeight = rowsHeight + titleH + titleGap
        let bottomOffset = (bounds.height - totalHeight) / 2

        // Title at bottom
        titleLabel.frame = NSRect(
            x: Layout.panelPadding, y: bottomOffset + titleGap,
            width: bounds.width - Layout.panelPadding * 2, height: titleH)

        // Rows from bottom up
        var y = bottomOffset + titleH + titleGap + rowsHeight - rowHeight

        for (i, section) in sections.enumerated() {
            let (vStart, _) = sectionViewStart[i]
            let iconCount = section.entries.count
            let rowX: CGFloat = (bounds.width - maxRowWidth) / 2

            var iconX: CGFloat = rowX
            for j in 0..<iconCount {
                let vi = vStart + j
                if vi < itemViews.count {
                    itemViews[vi].frame = NSRect(
                        x: iconX, y: y, width: L.iconSize, height: L.iconSize)
                    iconX += L.iconSize + L.iconPadding
                }
            }

            y -= rowHeight + rowGap
        }
    }

    // MARK: - Mouse Events

    /// Return the entry index for the icon at the given point.
    private func entryAtPoint(_ point: NSPoint) -> Int? {
        for (idx, view) in itemViews.enumerated() {
            if view.tag == -1 { continue }
            let f = convert(view.frame, from: view.superview)
            if f.contains(point) {
                return viewToEntryIndex(idx)
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let entryIdx = entryAtPoint(point) {
            onIconClick?(entryIdx)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let entryIdx = entryAtPoint(point), entryIdx != selectedEntryIndex {
            selectedEntryIndex = entryIdx
        }
    }

    private func viewToEntryIndex(_ viewIdx: Int) -> Int {
        if entryToViewIndex.isEmpty { return viewIdx }
        for (e, v) in entryToViewIndex where v == viewIdx { return e }
        return viewIdx
    }

    func startDrag(forEntryIndex entryIdx: Int, event: NSEvent) {
        guard entryIdx >= 0 else { return }
        dragEntryIdx = entryIdx
        let view: NSView? = {
            if let vi = entryToViewIndex[entryIdx], vi < itemViews.count { return itemViews[vi] }
            if entryIdx < itemViews.count { return itemViews[entryIdx] }
            return nil
        }()
        // Render drag preview BEFORE hiding selection
        let pb = NSPasteboardItem()
        pb.setString("\(entryIdx)", forType: Self.dragType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pb)
        if let v = view {
            let rect = v.bounds
            let dragImage = NSImage(size: rect.size)
            dragImage.lockFocus()
            v.draw(rect)
            dragImage.unlockFocus()
            let frame = convert(v.frame, from: v.superview)
            draggingItem.setDraggingFrame(frame, contents: dragImage)
        }
        // Hide selection on the dragged icon after rendering
        if let v = view as? IconView {
            v.isSelected = false
        }
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    @objc func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Restore selection after drag
        updateSelection()
        dragEntryIdx = -1
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard dragEntryIdx >= 0 else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        print("[MintTab] drag drop at \(point)")
        // Find which row the drop is on by checking item view frames
        var targetGroup = 0
        for (vi, _) in itemViews.enumerated() {
            let f = itemViews[vi].frame
            if point.y >= f.minY - 4 && point.y <= f.maxY + 4 {
                // Found a target icon, find its group
                for (e, v) in entryToViewIndex where v == vi {
                    // e is entry index in currentEntries
                    // Need group info from outside — pass entry index up
                    print("[MintTab]   dragIdx=\(dragEntryIdx) targetIdx=\(e)")
                    onDropToGroup?(dragEntryIdx, e)
                    break
                }
                break
            }
        }
        dragEntryIdx = -1
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Deduplicate with the CGEvent tap / local monitor so a single key press
        // is handled only once.
        let keyCode = Int64(event.keyCode)
        guard markKeyEventHandled(keyCode) else { return }

        let mods = event.modifierFlags.carbonModifiers
        if let action = directionAction(forCarbonKeyCode: UInt32(keyCode), modifiers: mods) {
            switch action {
            case .up: onKeyEvent?("up")
            case .down: onKeyEvent?("down")
            case .left: onKeyEvent?("left")
            case .right: onKeyEvent?("right")
            }
            return
        }

        // Tab / Shift+Tab cycling is handled by the Carbon global hotkey.
        switch Int(event.keyCode) {
        case Int(KeyCode.escape):
            onKeyEvent?("escape")
        case Int(KeyCode.return):
            onKeyEvent?("enter")
        default:
            super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {}
}

// ============================================================
// MARK: - Switcher Panel
// ============================================================

class SwitcherPanel: NSPanel {
    static let shared = SwitcherPanel()
    private let switcherContentView = SwitcherContentView()
    private let blurView = NSVisualEffectView()
    private let solidBg = NSView()
    private var dragStart: NSPoint = .zero

    var selectedIndex: Int {
        get { switcherContentView.selectedEntryIndex }
        set { switcherContentView.selectedEntryIndex = newValue }
    }

    var onIconClick: ((Int) -> Void)? {
        get { switcherContentView.onIconClick }
        set { switcherContentView.onIconClick = newValue }
    }

    var onKeyEvent: ((String) -> Void)? {
        get { switcherContentView.onKeyEvent }
        set { switcherContentView.onKeyEvent = newValue }
    }

    var onDropToGroup: ((Int, Int) -> Void)? {
        get { switcherContentView.onDropToGroup }
        set { switcherContentView.onDropToGroup = newValue }
    }

    func startDrag(entryIdx: Int, event: NSEvent) {
        switcherContentView.startDrag(forEntryIndex: entryIdx, event: event)
    }

    private init() {
        let initialRect = NSRect(x: 0, y: 0, width: 400, height: 88)
        super.init(
            contentRect: initialRect,
            styleMask: [.titled, .fullSizeContentView, .borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false

        blurView.frame = initialRect
        blurView.material = .popover
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = Layout.cornerRadius
        blurView.layer?.masksToBounds = true
        blurView.autoresizingMask = [.width, .height]

        switcherContentView.addSubview(blurView, positioned: .below, relativeTo: nil)

        // Solid fallback background when blur is off
        solidBg.frame = initialRect
        solidBg.wantsLayer = true
        solidBg.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        solidBg.layer?.cornerRadius = Layout.cornerRadius
        solidBg.layer?.masksToBounds = true
        solidBg.autoresizingMask = [.width, .height]
        solidBg.isHidden = true
        switcherContentView.addSubview(solidBg, positioned: .below, relativeTo: blurView)

        switcherContentView.wantsLayer = true
        switcherContentView.layer?.backgroundColor = NSColor.clear.cgColor
        switcherContentView.layer?.cornerRadius = Layout.cornerRadius
        switcherContentView.layer?.masksToBounds = true

        self.contentView = switcherContentView
    }

    func show(with entries: [AppEntry], selectedIndex: Int, style: MintTabConfig.UIStyle = .icons,
              size: MintTabConfig.UISize = .medium) {
        let L = Layout.values(for: size)
        switcherContentView.lv = L
        switcherContentView.style = style
        switcherContentView.update(with: entries)
        switcherContentView.selectedEntryIndex = selectedIndex

        let itemWidth = (style == .list) ? L.listItemWidth : L.iconSize
        let itemHeight = (style == .list) ? L.listItemHeight : L.iconSize
        let count = entries.count

        let panelWidth: CGFloat
        let panelHeight: CGFloat
        if style == .list {
            panelWidth = itemWidth + Layout.panelPadding * 2
            panelHeight = CGFloat(count) * itemHeight
                + CGFloat(max(count - 1, 0)) * L.iconPadding
                + Layout.panelPadding * 2
        } else {
            let contentWidth = max(
                CGFloat(count) * itemWidth + CGFloat(max(count - 1, 0)) * L.iconPadding,
                itemWidth
            )
            panelWidth = contentWidth + Layout.panelPadding * 2
            panelHeight = itemHeight + Layout.panelPadding * 2 + L.titleHeight + 6
        }

        layoutAndShow(panelWidth: panelWidth, panelHeight: panelHeight)
        switcherContentView.layoutFlat()
    }

    /// Grouped display: sections with labels (show-all mode, icons only).
    func showGrouped(sections: [(group: Int, label: String, entries: [AppEntry])], selectedIndex: Int,
                     size: MintTabConfig.UISize = .medium) {
        let L = Layout.values(for: size)
        switcherContentView.lv = L
        switcherContentView.style = .icons
        switcherContentView.updateGrouped(sections: sections)
        switcherContentView.selectedEntryIndex = selectedIndex

        let maxIcons = sections.map { $0.entries.count }.max() ?? 0
        let rowContentWidth = CGFloat(maxIcons) * L.iconSize
            + CGFloat(max(maxIcons - 1, 0)) * L.iconPadding
        let panelWidth = max(rowContentWidth, 200) + Layout.panelPadding * 2
        let panelHeight = CGFloat(sections.count) * L.iconSize
            + CGFloat(max(sections.count - 1, 0)) * Layout.groupRowGap
            + Layout.panelPadding * 2 + L.titleHeight + 6

        layoutAndShow(panelWidth: panelWidth, panelHeight: panelHeight)
        switcherContentView.layoutGrouped(sections: sections)
    }

    private func layoutAndShow(panelWidth: CGFloat, panelHeight: CGFloat) {
        let screenFrame = NSScreen.main?.frame ?? .zero
        let panelRect = NSRect(
            x: (screenFrame.width - panelWidth) / 2 + screenFrame.minX,
            y: (screenFrame.height - panelHeight) / 2 + screenFrame.minY,
            width: panelWidth,
            height: panelHeight
        )

        setFrame(panelRect, display: true)
        switcherContentView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        blurView.frame = switcherContentView.bounds
        solidBg.frame = switcherContentView.bounds

        alphaValue = 0
        makeKeyAndOrderFront(nil)
        makeFirstResponder(switcherContentView)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func setBlur(_ enabled: Bool) {
        blurView.isHidden = !enabled
        solidBg.isHidden = enabled
    }

    func setMouse(_ enabled: Bool) {
        acceptsMouseMovedEvents = enabled
    }

    func markKbSelection(_ idx: Int) {
        switcherContentView.markKbSelection(idx)
    }

    func highlight(index: Int) {
        switcherContentView.selectedEntryIndex = index
    }

    func hide() {
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.08
                animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                self?.orderOut(nil)
            })
    }
}
