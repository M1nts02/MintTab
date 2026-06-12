import AppKit

// ============================================================
// MARK: - Menu Bar Manager
// ============================================================

class MenuBarManager: NSObject, NSMenuDelegate {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private var enabled = false
    private var currentGroup = 0
    private var groupNames: [String] = (1...9).map { "Group \($0)" }
    private var iconFormat: String = "{index}"

    // MARK: - Callbacks

    var onShowAll: (() -> Void)?
    var onSwitchToGroup: ((Int) -> Void)?
    var onMoveToGroup: ((Int) -> Void)?
    var onReloadConfig: (() -> Void)?
    var onQuit: (() -> Void)?

    // MARK: - Setup

    func setup(enabled: Bool, groupNames: [String]? = nil,
               iconFormat: String = "{index}") {
        self.enabled = enabled
        self.iconFormat = iconFormat
        if let names = groupNames, names.count == 9 { self.groupNames = names }
        if enabled {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = ""
            statusItem = item
            buildMenu()
            updateIcon()
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    /// Update the menu bar icon to reflect the current group.
    /// Group 0 (no filter) shows a neutral icon.
    func updateIcon(group: Int = 0) {
        currentGroup = group
        guard let button = statusItem?.button else { return }

        let text: String

        if group > 0 {
            text = iconFormat
                .replacingOccurrences(of: "{index}", with: "\(group)")
                .replacingOccurrences(of: "{name}", with: groupNames[group - 1])
        } else {
            text = "◆"
        }

        let font = group > 0
            ? NSFont.menuBarFont(ofSize: 0).boldVersion()
            : NSFont.menuBarFont(ofSize: 0)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let rect = text.boundingRect(
            with: NSSize(width: 300, height: 22), options: [], attributes: attrs)

        let pad: CGFloat = 4
        let imgW = rect.width + pad * 2
        let imgH: CGFloat = 22

        let image = NSImage(size: NSSize(width: imgW, height: imgH))
        image.isTemplate = true
        image.lockFocus()
        text.draw(at: NSPoint(x: pad, y: (imgH - rect.height) / 2),
                   withAttributes: attrs)
        image.unlockFocus()

        button.image = image
    }

    // MARK: - Menu Construction

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Show All Windows
        let showAll = NSMenuItem(
            title: "Show All Windows", action: #selector(showAllAction), keyEquivalent: "")
        showAll.target = self
        showAll.isEnabled = true
        menu.addItem(showAll)

        menu.addItem(NSMenuItem.separator())

        // Switch to Group (submenu built dynamically in menuWillOpen)
        let switchItem = NSMenuItem(title: "Switch to Group", action: nil, keyEquivalent: "")
        switchItem.submenu = NSMenu()
        switchItem.isEnabled = true
        menu.addItem(switchItem)

        // Move App to Group (submenu built dynamically in menuWillOpen)
        let moveItem = NSMenuItem(title: "Move App to Group", action: nil, keyEquivalent: "")
        moveItem.submenu = NSMenu()
        moveItem.isEnabled = true
        menu.addItem(moveItem)

        menu.addItem(NSMenuItem.separator())

        // Reload Configuration
        let reload = NSMenuItem(
            title: "Reload Configuration", action: #selector(reloadAction), keyEquivalent: "")
        reload.target = self
        reload.isEnabled = true
        menu.addItem(reload)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quit = NSMenuItem(
            title: "Quit MintTab", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateSwitchGroupMenu(menu)
        updateMoveGroupMenu(menu)
    }

    // MARK: - Dynamic Menu Building

    private func updateSwitchGroupMenu(_ menu: NSMenu) {
        guard let switchItem = menu.item(withTitle: "Switch to Group"),
            let submenu = switchItem.submenu
        else { return }
        submenu.removeAllItems()

        for g in 1...9 {
            let item = NSMenuItem(
                title: groupNames[g - 1],
                action: #selector(switchGroupAction(_:)),
                keyEquivalent: "")
            item.target = self
            item.tag = g
            item.state = (g == currentGroup) ? .on : .off
            item.isEnabled = true
            submenu.addItem(item)
        }
    }

    private func updateMoveGroupMenu(_ menu: NSMenu) {
        guard let moveItem = menu.item(withTitle: "Move App to Group"),
            let submenu = moveItem.submenu
        else { return }
        submenu.removeAllItems()

        for g in 1...9 {
            let item = NSMenuItem(
                title: groupNames[g - 1],
                action: #selector(moveToGroupAction(_:)),
                keyEquivalent: "")
            item.target = self
            item.tag = g
            item.isEnabled = true
            submenu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func showAllAction() { onShowAll?() }
    @objc private func reloadAction() { onReloadConfig?() }
    @objc private func quitAction() { onQuit?() }

    @objc private func switchGroupAction(_ sender: NSMenuItem) {
        onSwitchToGroup?(sender.tag)
    }

    @objc private func moveToGroupAction(_ sender: NSMenuItem) {
        onMoveToGroup?(sender.tag)
    }
}

private extension NSFont {
    func boldVersion() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}
