import AppKit
import Carbon
import Darwin
import IOKit

// ============================================================
// MARK: - Constants
// ============================================================

/// Four-character signature for our Carbon hotkeys.
private let hotkeySignature: FourCharCode = {
    "MTab".utf16.reduce(0) { ($0 << 8) + OSType($1) }
}()

/// Our hotkey IDs.
private enum HotkeyID {
    static let switchTab: UInt32 = 1
    static let switchShiftTab: UInt32 = 2
    static let showAll: UInt32 = 3
    static let nextGroup: UInt32 = 4
    static let prevGroup: UInt32 = 5
    static let groupSwitchBase: UInt32 = 10   // 10–18 → group 1–9
    static let groupAssignBase: UInt32 = 20   // 20–28 → assign 1–9
}

// ============================================================
// MARK: - Global State
// ============================================================

/// Active configuration loaded from ~/.config/minttab/config.toml
private var activeConfig: MintTabConfig = .default

/// True while the switcher panel is visible.
private var panelVisible = false

/// True when the panel is showing the grouped "show all" view.
private var isShowingAll = false

/// The entries currently displayed in the panel.
private var currentEntries: [AppEntry] = []

/// Section start indices for show-all grouped mode (cached at display time).
private var sectionStarts: [Int] = []

/// Sections data for drag/drop group reassignment.
private var cachedSections: [(group: Int, label: String, entries: [AppEntry])] = []

/// The index currently selected in the panel.
private var selectedIndex = 0

/// Whether the trigger modifier (from config) is currently held down,
/// as tracked by the CGEvent tap flagsChanged callback.
private var triggerModifierHeld = false

/// The NSEvent modifier flag derived from the switch keybinding.
private var triggerModifierFlag: NSEvent.ModifierFlags = .option

/// Stored hotkey refs for cleanup on exit.
private var hotkeyRefs: [UInt32: EventHotKeyRef?] = [:]

/// Carbon event handler refs.
private var hotkeyPressHandler: EventHandlerRef?
private var hotkeyReleaseHandler: EventHandlerRef?

/// CGEvent tap ref for flagsChanged monitoring.
private var eventTap: CFMachPort?

/// Whether the CGEvent tap was created successfully. When false, we fall back
/// to polling the modifier state to detect when the switch modifier is released.
private var eventTapAvailable = false

/// Fallback timer for detecting modifier release when the CGEvent tap is unavailable.
private var modifierPollTimer: Timer?

/// Local event monitor for key events while panel is shown.
private var localEventMonitor: Any?

/// Last key event handled by any of the key handlers (CGEvent tap, local
/// monitor, or the panel's content view). Used to suppress duplicate handling
/// of the same physical key press.
private var lastHandledKey: (keyCode: Int64, timestamp: Date) = (0, Date.distantPast)
private let keyDedupInterval: TimeInterval = 0.05

/// Mark a key event as handled and return whether this handler should process
/// it (false if it was already handled very recently).
func markKeyEventHandled(_ keyCode: Int64) -> Bool {
    let now = Date()
    if lastHandledKey.keyCode == keyCode,
       now.timeIntervalSince(lastHandledKey.timestamp) < keyDedupInterval {
        return false
    }
    lastHandledKey = (keyCode, now)
    return true
}

// ============================================================
// MARK: - CGEvent Tap Callback
// ============================================================

/// File-level closure stored so it can be safely bridged to a C function pointer.
/// Tracks modifier flag changes AND Tab key events for cycling while panel is open.
private let eventTapCallback: CGEventTapCallBack = {
    (_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?)
        -> Unmanaged<CGEvent>? in
    switch type {
    case .flagsChanged:
        let flags = event.flags
        DispatchQueue.main.async {
            flagsChanged(modifiers: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
        }
    case .keyDown:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        DispatchQueue.main.async {
            handleKeyEvent(keyCode: keyCode, flags: flags)
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

enum DirectionKeyAction {
    case up, down, left, right
}

/// Resolve a key event to a direction action.
/// - Switcher panel: arrow keys and switch-modifier + Vim keys (h/j/k/l).
/// - Show-all panel: arrow keys, Ctrl+Emacs keys (n/p/f/b), and custom show-all-* keys.
func directionAction(forCarbonKeyCode keyCode: UInt32, modifiers: UInt32, isShowingAll: Bool = false) -> DirectionKeyAction? {
    // Arrow keys work everywhere without modifiers, and in the switcher panel
    // they also work while holding the switch modifier (since the user is
    // already keeping that modifier held).
    if modifiers == 0 || (!isShowingAll && modifiers == activeConfig.switchCarbonMod) {
        switch keyCode {
        case KeyCode.upArrow: return .up
        case KeyCode.downArrow: return .down
        case KeyCode.leftArrow: return .left
        case KeyCode.rightArrow: return .right
        default: break
        }
    }

    if isShowingAll {
        // Show-all panel: plain Vim direction keys.
        if modifiers == 0 {
            switch keyCode {
            case KeyCode.h: return .left
            case KeyCode.j: return .down
            case KeyCode.k: return .up
            case KeyCode.l: return .right
            default: break
            }
        }
    } else {
        // Switcher panel: Vim direction keys while holding the switch modifier.
        if modifiers == activeConfig.switchCarbonMod {
            switch keyCode {
            case KeyCode.h: return .left
            case KeyCode.j: return .down
            case KeyCode.k: return .up
            case KeyCode.l: return .right
            default: break
            }
        }
    }

    return nil
}

private func handleKeyEvent(keyCode: Int64, flags: CGEventFlags) {
    guard panelVisible else { return }
    guard markKeyEventHandled(keyCode) else { return }

    if let action = directionAction(forCarbonKeyCode: UInt32(keyCode), modifiers: flags.carbonModifiers, isShowingAll: isShowingAll) {
        switch action {
        case .up: cycleRow(forward: false)
        case .down: cycleRow(forward: true)
        case .left: cycleSelection(forward: false)
        case .right: cycleSelection(forward: true)
        }
        return
    }

    // Tab / Shift+Tab cycling is handled by the Carbon global hotkey so it
    // works reliably even when the CGEvent tap does not see repeated key events.
    switch keyCode {
    case Int64(KeyCode.escape):
        dismissPanel(select: false)
    case Int64(KeyCode.return):
        dismissPanel(select: true)
    default:
        break
    }
}

// ============================================================
// MARK: - Carbon Hotkey Event Handler Callback
// ============================================================

private func hotkeyEventCallback(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _: UnsafeMutableRawPointer?,
    pressed: Bool
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr else { return status }

    DispatchQueue.main.async {
        handleHotkey(id: Int(hotkeyID.id), pressed: pressed)
    }
    return noErr
}

/// Press handler. Must be a stored closure so it can be passed to InstallEventHandler.
private let hotkeyPressCallback: EventHandlerUPP = { (ref, event, ctx) in
    hotkeyEventCallback(ref, event, ctx, pressed: true)
}

/// Release handler.
private let hotkeyReleaseCallback: EventHandlerUPP = { (ref, event, ctx) in
    hotkeyEventCallback(ref, event, ctx, pressed: false)
}

// ============================================================
// MARK: - Keyboard Setup
// ============================================================

/// Register all Carbon global hotkeys and install event handlers.
private func setupCarbonHotkeys() {
    let target = GetEventDispatcherTarget()

    // --- Install event handlers ---
    var pressedSpec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: OSType(kEventHotKeyPressed)
    )
    var releasedSpec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: OSType(kEventHotKeyReleased)
    )

    InstallEventHandler(
        target,
        hotkeyPressCallback,
        1, &pressedSpec,
        nil,
        &hotkeyPressHandler
    )

    InstallEventHandler(
        target,
        hotkeyReleaseCallback,
        1, &releasedSpec,
        nil,
        &hotkeyReleaseHandler
    )

    // --- Register switch hotkey (mod + Tab) ---
    let switchMod = activeConfig.switchCarbonMod
    registerHotkey(id: HotkeyID.switchTab, keyCode: KeyCode.tab, modifiers: switchMod)
    registerHotkey(
        id: HotkeyID.switchShiftTab, keyCode: KeyCode.tab,
        modifiers: switchMod | CarbonMod.shift)

    // --- Register show-all hotkey ---
    let sk = activeConfig.showAllKey
    registerHotkey(id: HotkeyID.showAll, keyCode: sk.keyCode, modifiers: sk.modifiers)

    // --- Register group hotkeys ---
    for i in 0..<9 {
        if let key = activeConfig.groupSwitchKeys[i] {
            registerHotkey(
                id: HotkeyID.groupSwitchBase + UInt32(i),
                keyCode: key.keyCode, modifiers: key.modifiers)
        }
        if let key = activeConfig.groupAssignKeys[i] {
            registerHotkey(
                id: HotkeyID.groupAssignBase + UInt32(i),
                keyCode: key.keyCode, modifiers: key.modifiers)
        }
    }

    if let nk = activeConfig.nextGroupKey {
        registerHotkey(id: HotkeyID.nextGroup, keyCode: nk.keyCode, modifiers: nk.modifiers)
    }
    if let pk = activeConfig.prevGroupKey {
        registerHotkey(id: HotkeyID.prevGroup, keyCode: pk.keyCode, modifiers: pk.modifiers)
    }
}

/// Wrapper around Carbon's RegisterEventHotKey.
private func registerHotkey(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
    let hid = EventHotKeyID(signature: hotkeySignature, id: id)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
        keyCode, modifiers, hid,
        GetEventDispatcherTarget(),
        0, /* kEventHotKeyNoOptions */
        &ref)
    if status == noErr {
        hotkeyRefs[id] = ref
    } else {
        print(
            "[MintTab] Failed to register hotkey id=\(id) code=\(keyCode) mods=\(modifiers) err=\(status)"
        )
    }
}

/// Create a CGEvent tap that monitors flagsChanged (modifier release) and
/// keyDown (Tab/Esc/arrows while panel is open). Uses .cghidEventTap for
/// earliest possible event interception.
private func setupEventTap() {
    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
             | CGEventMask(1 << CGEventType.keyDown.rawValue)

    eventTap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: eventTapCallback,
        userInfo: nil
    )

    if let tap = eventTap {
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTapAvailable = true
        print("[MintTab] CGEvent tap active.")
    } else {
        eventTapAvailable = false
        print(
            "[MintTab] Warning: could not create event tap. Falling back to polling for modifier release (accessibility/input-monitoring permission may be needed)."
        )
    }
}

/// Tear down all registered hotkeys, the event tap, and the local monitor.
private func teardownInput() {
    for (_, ref) in hotkeyRefs {
        if let r = ref { UnregisterEventHotKey(r) }
    }
    hotkeyRefs.removeAll()

    if let tap = eventTap {
        CGEvent.tapEnable(tap: tap, enable: false)
        eventTap = nil
    }
    eventTapAvailable = false

    modifierPollTimer?.invalidate()
    modifierPollTimer = nil

    if let mon = localEventMonitor {
        NSEvent.removeMonitor(mon)
        localEventMonitor = nil
    }
}

/// Reload configuration from disk and re-apply all settings.
private func reloadConfig() {
    teardownInput()
    setNativeCommandTabEnabled(true)  // restore before reload

    activeConfig = ConfigLoader.load()
    triggerModifierFlag = activeConfig.triggerModifierFlag
    WindowsManager.shared.switchingLogic = activeConfig.switchingLogic
    WindowsManager.shared.showHidden = activeConfig.showHidden
    WindowsManager.shared.showWindowless = activeConfig.showWindowless
    SwitcherPanel.shared.setBlur(activeConfig.blur)
    SwitcherPanel.shared.setMouse(activeConfig.mouse)

    MenuBarManager.shared.setup(
        enabled: activeConfig.menuBar,
        groupNames: activeConfig.groupNames,
        iconFormat: activeConfig.menuBarIconFormat)

    if panelVisible {
        dismissPanel(select: false)
    }

    WindowsManager.shared.currentGroup = 1
    MenuBarManager.shared.updateIcon(group: 1)

    if activeConfig.switchMod == .cmd {
        setNativeCommandTabEnabled(false)
    }

    setupCarbonHotkeys()
    setupEventTap()
    setupLocalEventMonitor()

    print("[MintTab] Configuration reloaded.")
}

/// Local event monitor: lightweight fallback for when the panel has key focus.
/// Key events (Tab/arrows) are handled by the CGEvent tap to avoid double-firing.
private func setupLocalEventMonitor() {
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
        guard panelVisible else { return event }
        // CGEvent tap and the panel's content view handle most keys. This
        // monitor is a fallback for Esc/Enter, deduplicated with markKeyEventHandled.
        let keyCode = Int64(event.keyCode)
        guard markKeyEventHandled(keyCode) else { return event }
        switch Int(event.keyCode) {
        case Int(KeyCode.escape):
            dismissPanel(select: false)
        case Int(KeyCode.return):
            dismissPanel(select: true)
        default:
            break
        }
        return event
    }
}

private func handlePanelKey(_ action: String?) {
    guard panelVisible else { return }
    if let action {
        switch action {
        case "escape":  dismissPanel(select: false)
        case "enter":   dismissPanel(select: true)
        case "up":      cycleRow(forward: false)
        case "down":    cycleRow(forward: true)
        case "left":    cycleSelection(forward: false)
        case "right":   cycleSelection(forward: true)
        default: break
        }
    }
}

private func cycleRow(forward: Bool) {
    guard isShowingAll, !sectionStarts.isEmpty else {
        cycleSelection(forward: forward)
        return
    }
    guard let currentSection = sectionStarts.lastIndex(where: { $0 <= selectedIndex }) else { return }
    let newSection: Int
    if forward {
        newSection = (currentSection + 1) % sectionStarts.count
    } else {
        newSection = (currentSection - 1 + sectionStarts.count) % sectionStarts.count
    }
    let offset = selectedIndex - sectionStarts[currentSection]
    let newCount = newSection + 1 < sectionStarts.count
        ? sectionStarts[newSection + 1] - sectionStarts[newSection]
        : currentEntries.count - sectionStarts[newSection]
    selectedIndex = sectionStarts[newSection] + min(offset, newCount - 1)
    SwitcherPanel.shared.markKbSelection(selectedIndex)
    SwitcherPanel.shared.highlight(index: selectedIndex)
}

// ============================================================
// MARK: - Event Handlers
// ============================================================

/// Called on the main thread for every Carbon hotkey press / release.
private func handleHotkey(id: Int, pressed: Bool) {
    let uid = UInt32(id)

    switch uid {
    case HotkeyID.switchTab:
        if pressed {
            if panelVisible {
                // Always cycle via the Carbon hotkey; it is more reliable than the
                // CGEvent tap for repeated Tab presses while the modifier is held.
                cycleSelection(forward: true)
                markKeyEventHandled(Int64(KeyCode.tab))
            } else {
                showPanel()
            }
        } else {
            // Safety net: if the CGEvent tap missed the modifier release or the
            // polling fallback is not active, check the real modifier state after
            // the Tab key is released and dismiss if the trigger modifier is up.
            if panelVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard panelVisible else { return }
                    if !NSEvent.modifierFlags.contains(triggerModifierFlag) {
                        dismissPanel(select: true)
                    }
                }
            }
        }

    case HotkeyID.switchShiftTab:
        if pressed {
            if panelVisible {
                cycleSelection(forward: false)
                markKeyEventHandled(Int64(KeyCode.tab))
            } else {
                showPanel(backward: true)
            }
        }

    case HotkeyID.showAll:
        guard pressed else { break }
        if panelVisible {
            dismissPanel(select: false)
        }
        showAllPanel()

    case HotkeyID.nextGroup:
        guard pressed else { break }
        WindowsManager.shared.nextGroup()
        MenuBarManager.shared.updateIcon(group: WindowsManager.shared.currentGroup)
        if panelVisible { showPanel() }

    case HotkeyID.prevGroup:
        guard pressed else { break }
        WindowsManager.shared.previousGroup()
        MenuBarManager.shared.updateIcon(group: WindowsManager.shared.currentGroup)
        if panelVisible { showPanel() }

    case HotkeyID.groupSwitchBase..<HotkeyID.groupSwitchBase + 9:
        guard pressed else { break }
        let group = Int(uid - HotkeyID.groupSwitchBase) + 1  // 1–9
        switchToGroup(group)

    case HotkeyID.groupAssignBase..<HotkeyID.groupAssignBase + 9:
        guard pressed else { break }
        let group = Int(uid - HotkeyID.groupAssignBase) + 1  // 1–9
        assignCurrentAppToGroup(group)

    default:
        break
    }
}

/// Called from the CGEvent tap when modifier flags change.
private func flagsChanged(modifiers: NSEvent.ModifierFlags) {
    let held = modifiers.contains(triggerModifierFlag)
    guard held != triggerModifierHeld else { return }
    triggerModifierHeld = held

    if !held && panelVisible {
        // Trigger modifier was released — dismiss and select.
        dismissPanel(select: true)
    }
}

/// Fallback for environments where the CGEvent tap cannot be created (e.g.
/// launchd / brew services without Input Monitoring permission). Poll the
/// current modifier flags while the panel is open and dismiss when the trigger
/// modifier is released.
private func startModifierPoll() {
    guard !eventTapAvailable else { return }
    modifierPollTimer?.invalidate()
    modifierPollTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
        guard panelVisible else {
            stopModifierPoll()
            return
        }
        if !NSEvent.modifierFlags.contains(triggerModifierFlag) {
            dismissPanel(select: true)
        }
    }
}

private func stopModifierPoll() {
    modifierPollTimer?.invalidate()
    modifierPollTimer = nil
}

// ============================================================
// MARK: - Panel Show / Hide / Cycle
// ============================================================

/// Compute the initial selection for a quick "switch to recent" action.
/// - App mode: select the entry right after the frontmost app. If the
///   frontmost app is not visible (e.g. it has no windows), select the first
///   visible entry instead of skipping it.
/// - Window mode: entries are in z-order with the current window first, so the
///   recent window is the one right behind it at index 1.
private func initialSelectionIndex(
    entries: [AppEntry], frontmostBundleID: String?
) -> Int {
    guard entries.count > 1 else { return 0 }

    if activeConfig.switchingLogic == .window {
        return 1
    }

    guard let frontmostBundleID else {
        return min(1, entries.count - 1)
    }
    return entries.first?.bundleIdentifier == frontmostBundleID
        ? 1
        : 0
}

private func showPanel(backward: Bool = false) {
    let frontBid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

    // Auto-switch to frontmost app's group.
    // When assign-switch is also enabled, leave the current group unchanged for
    // ungrouped apps so they can be assigned to the active group instead of
    // being forced back to group 1.
    if activeConfig.autoGroup {
        if let frontBid = frontBid,
           let group = GroupManager.shared.getGroup(for: frontBid) {
            WindowsManager.shared.currentGroup = group
        } else if !activeConfig.assignSwitch {
            WindowsManager.shared.currentGroup = 1
        }
        MenuBarManager.shared.updateIcon(group: WindowsManager.shared.currentGroup)
    }

    // assign-switch: auto-assign an ungrouped frontmost app to the current group
    // when the switcher is opened.
    if activeConfig.assignSwitch, let frontBid = frontBid,
       GroupManager.shared.getGroup(for: frontBid) == nil {
        GroupManager.shared.setGroup(WindowsManager.shared.currentGroup, for: frontBid)
        print("[MintTab] auto-assigned \(frontBid) to group \(WindowsManager.shared.currentGroup)")
    }

    // Ensure frontmost app is at the top of the focus stack before refresh.
    if let frontBid = frontBid {
        WindowsManager.shared.moveToFront(frontBid)
    }
    WindowsManager.shared.refresh()
    let entries = WindowsManager.shared.appEntries
    print("[MintTab] showPanel entries=\(entries.count) selected=\(initialSelectionIndex(entries: entries, frontmostBundleID: frontBid))")
    print("[MintTab]   order: \(entries.prefix(5).map { "\($0.appName):\($0.windows.first?.cgWindowId ?? 0)" })")
    guard !entries.isEmpty else { return }

    currentEntries = entries
    isShowingAll = false
    selectedIndex = backward
        ? (entries.count - 1)
        : initialSelectionIndex(entries: entries, frontmostBundleID: frontBid)
    SwitcherPanel.shared.markKbSelection(selectedIndex)
    panelVisible = true

    SwitcherPanel.shared.onIconClick = { index in
        selectedIndex = index
        dismissPanel(select: true)
    }

    SwitcherPanel.shared.onKeyEvent = { action in
        handlePanelKey(action)
    }
    SwitcherPanel.shared.show(
        with: entries, selectedIndex: selectedIndex,
        style: activeConfig.uiStyle, size: activeConfig.uiSize)

    startModifierPoll()
}

/// Show-all: grouped display with all windows, ignoring current group filter.
private func showAllPanel() {
    if let frontBid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
        WindowsManager.shared.moveToFront(frontBid)
    }
    WindowsManager.shared.refresh()
    let sections = WindowsManager.shared.groupedEntries(
        groupNames: activeConfig.groupNames)
    let flatEntries = sections.flatMap { $0.entries }
    guard !flatEntries.isEmpty else { return }

    // Cache section starts for row navigation
    sectionStarts = []
    var idx = 0
    for s in sections {
        sectionStarts.append(idx)
        idx += s.entries.count
    }

    currentEntries = flatEntries
    isShowingAll = true
    // Select focused window with windows; else first in current group; else first overall
    let frontBid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let curGroup = WindowsManager.shared.currentGroup
    if let frontIdx = flatEntries.firstIndex(where: { $0.bundleIdentifier == frontBid && !$0.windows.isEmpty }) {
        selectedIndex = frontIdx
    } else if let groupSection = sections.first(where: { $0.group == curGroup }),
              let groupFirst = groupSection.entries.first(where: { !$0.windows.isEmpty }),
              let idx = flatEntries.firstIndex(where: { $0.bundleIdentifier == groupFirst.bundleIdentifier }) {
        selectedIndex = idx
    } else if let firstWithWindow = flatEntries.firstIndex(where: { !$0.windows.isEmpty }) {
        selectedIndex = firstWithWindow
    } else {
        selectedIndex = 0
    }
    SwitcherPanel.shared.markKbSelection(selectedIndex)
    panelVisible = true

    SwitcherPanel.shared.onIconClick = { index in
        selectedIndex = index
        dismissPanel(select: true)
    }

    SwitcherPanel.shared.onKeyEvent = { action in
        handlePanelKey(action)
    }
    SwitcherPanel.shared.onDropToGroup = { dragIdx, targetIdx in
        guard dragIdx < currentEntries.count, targetIdx < currentEntries.count else {
            print("[MintTab] drop indices out of range drag=\(dragIdx) target=\(targetIdx) count=\(currentEntries.count)")
            return
        }
        let draggedBundle = currentEntries[dragIdx].bundleIdentifier
        let targetBundle = currentEntries[targetIdx].bundleIdentifier
        var targetGroup = 1
        for s in sections {
            if s.entries.contains(where: { $0.bundleIdentifier == targetBundle }) {
                targetGroup = s.group
                break
            }
        }
        print("[MintTab] assign drag=\(draggedBundle) target=\(targetBundle) group=\(targetGroup)")
        GroupManager.shared.setGroup(targetGroup, for: draggedBundle)
        showAllPanel()
    }
    SwitcherPanel.shared.showGrouped(
        sections: sections, selectedIndex: selectedIndex, size: activeConfig.uiSize)

    startModifierPoll()
}

private func dismissPanel(select: Bool) {
    guard panelVisible else { return }

    stopModifierPoll()

    let effectiveIndex = activeConfig.mouseSwitch
        ? SwitcherPanel.shared.selectedIndex : selectedIndex

    if select, effectiveIndex >= 0, effectiveIndex < currentEntries.count {
        let entry = currentEntries[effectiveIndex]
        activateApp(entry)

        // In show-all mode, also switch to the selected app's group
        if isShowingAll {
            if let group = GroupManager.shared.getGroup(for: entry.bundleIdentifier) {
                WindowsManager.shared.currentGroup = group
            } else {
                WindowsManager.shared.currentGroup = 1
            }
            MenuBarManager.shared.updateIcon(group: WindowsManager.shared.currentGroup)
        }

    }

    panelVisible = false
    isShowingAll = false
    SwitcherPanel.shared.hide()
}

private func cycleSelection(forward: Bool) {
    guard !currentEntries.isEmpty else { return }

    // If show-all and cross-group disabled, stay within current group row
    if isShowingAll && !activeConfig.showAllCrossGroup && !sectionStarts.isEmpty {
        guard let sec = sectionStarts.lastIndex(where: { $0 <= selectedIndex }) else { return }
        let start = sectionStarts[sec]
        let end = sec + 1 < sectionStarts.count ? sectionStarts[sec + 1] - 1 : currentEntries.count - 1
        let count = end - start + 1
        let offset = selectedIndex - start
        if forward {
            selectedIndex = start + (offset + 1) % count
        } else {
            selectedIndex = start + (offset - 1 + count) % count
        }
    } else {
        if forward {
            selectedIndex = (selectedIndex + 1) % currentEntries.count
        } else {
            selectedIndex = (selectedIndex - 1 + currentEntries.count) % currentEntries.count
        }
    }

    SwitcherPanel.shared.markKbSelection(selectedIndex)
    SwitcherPanel.shared.highlight(index: selectedIndex)
}

private func activateApp(_ entry: AppEntry) {
    let targetWindow = entry.windows.first
    let isWindowMode = activeConfig.switchingLogic == .window

    // Activate the app
    if let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: entry.bundleIdentifier
    ).first {
        app.activate(options: isWindowMode
            ? [.activateIgnoringOtherApps]
            : [.activateAllWindows, .activateIgnoringOtherApps])
    } else if let app = NSWorkspace.shared.runningApplications.first(
        where: { $0.processIdentifier == entry.pid }
    ) {
        app.activate(options: isWindowMode
            ? [.activateIgnoringOtherApps]
            : [.activateAllWindows, .activateIgnoringOtherApps])
    }

    // Track activation for recency ordering
    WindowsManager.shared.recordActivation(
        entry.bundleIdentifier,
        windowID: isWindowMode ? entry.windows.first?.cgWindowId : nil
    )

    // In window mode, raise the specific window via Accessibility
    if isWindowMode, let targetWindow {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            focusAXWindow(pid: entry.pid, title: targetWindow.title)
        }
    }
}

/// Use Accessibility API to raise a specific window by title.
private func focusAXWindow(pid: pid_t, title: String?) {
    let appElement = AXUIElementCreateApplication(pid)
    var windowList: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        appElement, kAXWindowsAttribute as CFString, &windowList
    ) == .success,
        let windows = windowList as? [AXUIElement]
    else { return }

    // Match by title first, fall back to the first window
    let target: AXUIElement?
    if let title, !title.isEmpty {
        target = windows.first { axWindow in
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                axWindow, kAXTitleAttribute as CFString, &t
            ) == .success else { return false }
            return (t as? String) == title
        }
    } else {
        target = windows.first
    }

    if let target {
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    }
}

// ============================================================
// MARK: - Group Management
// ============================================================

private func switchToGroup(_ group: Int) {
    WindowsManager.shared.currentGroup = group
    MenuBarManager.shared.updateIcon(group: group)

    if panelVisible {
        showPanel()
    }

    // Optionally focus first window in target group
    if activeConfig.switchGroupFocus {
        WindowsManager.shared.refresh()
        if let first = WindowsManager.shared.appEntries.first {
            activateApp(first)
        }
    }

    print("[MintTab] Group \(group)")
}

private func assignCurrentAppToGroup(_ group: Int) {
    let bundleID: String
    if panelVisible, selectedIndex >= 0, selectedIndex < currentEntries.count {
        // When the switcher is open, assign the currently selected entry's app.
        bundleID = currentEntries[selectedIndex].bundleIdentifier
    } else {
        // Otherwise use the frontmost app, but never assign MintTab itself.
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bid = frontApp.bundleIdentifier,
              bid != Bundle.main.bundleIdentifier
        else { return }
        bundleID = bid
    }

    GroupManager.shared.setGroup(group, for: bundleID)
    if activeConfig.assignSwitch {
        WindowsManager.shared.currentGroup = group
        MenuBarManager.shared.updateIcon(group: group)
    }
    print("[MintTab] \(bundleID) → Group \(group)")

    if panelVisible {
        if isShowingAll {
            showAllPanel()
        } else {
            showPanel()
        }
    }
}

// ============================================================
// MARK: - Permissions
// ============================================================

/// Request/check the permissions MintTab needs. This should be called early so
/// the user is prompted before we try to install global input hooks.
private func ensurePermissions() {
    // Accessibility is required for Carbon global hotkeys and window activation.
    let axOptions: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    let axTrusted = AXIsProcessTrustedWithOptions(axOptions as CFDictionary)
    print("[MintTab] Accessibility permission: \(axTrusted ? "granted" : "not granted")")

    // Input Monitoring is required for the CGEvent tap that detects modifier
    // release and extra key presses while the panel is open.
    let inputMonitoringGranted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    print("[MintTab] Input Monitoring permission: \(inputMonitoringGranted ? "granted" : "not granted")")

    // Screen Recording lets CGWindowListCopyWindowInfo return window titles.
    // Without it we fall back to Accessibility-based title reading.
    let screenCaptureGranted = CGRequestScreenCaptureAccess()
    print("[MintTab] Screen Recording permission: \(screenCaptureGranted ? "granted" : "not granted")")

    if !axTrusted {
        print("[MintTab] Warning: Accessibility permission is missing. Global hotkeys may not work and window titles may be unavailable.")
    }
    if !inputMonitoringGranted {
        print("[MintTab] Warning: Input Monitoring permission is missing. Will use fallback polling for modifier release.")
    }
    if !screenCaptureGranted {
        print("[MintTab] Warning: Screen Recording permission is missing. Will use Accessibility API fallback for window titles.")
    }
}

// ============================================================
// MARK: - App Delegate
// ============================================================

private class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load config and wire subsystems
        activeConfig = ConfigLoader.load()
        triggerModifierFlag = activeConfig.triggerModifierFlag
        WindowsManager.shared.switchingLogic = activeConfig.switchingLogic
        WindowsManager.shared.showHidden = activeConfig.showHidden
        WindowsManager.shared.showWindowless = activeConfig.showWindowless

        // Create the panel early so it's ready.
        _ = SwitcherPanel.shared
        SwitcherPanel.shared.setBlur(activeConfig.blur)
        SwitcherPanel.shared.setMouse(activeConfig.mouse)

        // If using Cmd as switch modifier, disable native Cmd+Tab
        if activeConfig.switchMod == .cmd {
            setNativeCommandTabEnabled(false)
            nativeHotkeysWereDisabled = true
            print("[MintTab] Native Cmd+Tab disabled.")
        }

        WindowsManager.shared.startMonitoring()

        ensurePermissions()

        setupIPCListener()
        setupCarbonHotkeys()
        setupEventTap()
        setupLocalEventMonitor()

        // Menu bar
        MenuBarManager.shared.onShowAll = { showAllPanel() }
        MenuBarManager.shared.onSwitchToGroup = { switchToGroup($0) }
        MenuBarManager.shared.onMoveToGroup = { assignCurrentAppToGroup($0) }
        MenuBarManager.shared.onReloadConfig = { reloadConfig() }
        MenuBarManager.shared.onQuit = { NSApplication.shared.terminate(nil) }
        MenuBarManager.shared.setup(
            enabled: activeConfig.menuBar,
            groupNames: activeConfig.groupNames,
            iconFormat: activeConfig.menuBarIconFormat)
        MenuBarManager.shared.updateIcon(
            group: WindowsManager.shared.currentGroup)

        let logicLabel = activeConfig.switchingLogic == .app ? "app" : "window"
        let styleLabel = activeConfig.uiStyle == .icons ? "icons" : "list"
        let switchMod = activeConfig.switchMod.rawValue
        print(
            "MintTab ready.  Mode: \(logicLabel)  |  Style: \(styleLabel)  |  Switch: \(switchMod)+tab  |  Config: ~/.config/minttab/config"
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Restore native Cmd+Tab
        if nativeHotkeysWereDisabled {
            setNativeCommandTabEnabled(true)
            nativeHotkeysWereDisabled = false
        }

        // Unregister all hotkeys
        for (_, ref) in hotkeyRefs {
            if let r = ref { UnregisterEventHotKey(r) }
        }
        // Disable event tap
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        // Remove local monitor
        if let mon = localEventMonitor {
            NSEvent.removeMonitor(mon)
        }
    }
}

// ============================================================
// MARK: - IPC Commands
// ============================================================

private let ipcNotificationName = NSNotification.Name("com.minttab.command")

/// Parse CLI args and either forward to running instance or start normally.
private func handleCLI() -> Bool {
    let args = CommandLine.arguments.dropFirst()
    guard let cmd = args.first else { return false }  // no args, start normally

    // Check if instance already running
    let myPid = ProcessInfo.processInfo.processIdentifier
    let myPath = Bundle.main.executablePath ?? ""
    let running = NSWorkspace.shared.runningApplications.first {
        $0.executableURL?.path == myPath && $0.processIdentifier != myPid
    }
    if let runningApp = running {
        // Forward command to running instance
        let payload = args.joined(separator: " ")
        DistributedNotificationCenter.default().postNotificationName(
            ipcNotificationName, object: nil, userInfo: ["cmd": payload],
            deliverImmediately: true)
        return true  // exit after forwarding
    }

    // No running instance, report error and exit
    print("[MintTab] Error: no running MintTab instance found. Start MintTab first.")
    return true
}

private func setupIPCListener() {
    DistributedNotificationCenter.default().addObserver(
        forName: ipcNotificationName, object: nil, queue: .main
    ) { notification in
        guard let cmdStr = notification.userInfo?["cmd"] as? String else { return }
        let parts = cmdStr.split(separator: " ").map(String.init)
        guard let action = parts.first else { return }
        switch action {
        case "switch-group":
            if let g = parts.dropFirst().first.flatMap(Int.init), (1...9).contains(g) {
                WindowsManager.shared.currentGroup = g
                MenuBarManager.shared.updateIcon(group: g)
                if activeConfig.switchGroupFocus {
                    WindowsManager.shared.refresh()
                    if let first = WindowsManager.shared.appEntries.first {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            activateApp(first)
                        }
                    }
                }
            }
        case "assign-group":
            if let g = parts.dropFirst().first.flatMap(Int.init), (1...9).contains(g) {
                assignCurrentAppToGroup(g)
                if activeConfig.assignSwitch {
                    MenuBarManager.shared.updateIcon(group: g)
                }
            }
        case "show-all":
            if !panelVisible { showAllPanel() }
        case "show-panel":
            if !panelVisible { showPanel() }
        case "reload":
            reloadConfig()
        default:
            print("[MintTab] Unknown IPC command: \(action)")
        }
    }
}

// ============================================================
// MARK: - Crash-safe Native Hotkey Restoration
// ============================================================

/// Ensure native Cmd+Tab is restored even if the app crashes or is force-quit.
private var nativeHotkeysWereDisabled = false

private func setupCrashSafeRestore() {
    // atexit runs on normal exit
    atexit {
        if nativeHotkeysWereDisabled {
            setNativeCommandTabEnabled(true)
            print("[MintTab] Native Cmd+Tab restored (atexit).")
        }
    }
    // SIGTERM / SIGINT (brew services stop, Ctrl+C)
    signal(SIGTERM) { _ in
        setNativeCommandTabEnabled(true)
        print("[MintTab] Native Cmd+Tab restored (SIGTERM).")
        exit(0)
    }
    signal(SIGINT) { _ in
        setNativeCommandTabEnabled(true)
        print("[MintTab] Native Cmd+Tab restored (SIGINT).")
        exit(0)
    }
}

// ============================================================
// MARK: - Entry Point
// ============================================================

autoreleasepool {
    // Ensure logs are flushed immediately, including when stdout is redirected
    // by launchd / brew services.
    setbuf(stdout, nil)

    setupCrashSafeRestore()

    // If CLI args present and instance running, forward and exit
    if handleCLI() {
        exit(0)
    }

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate

    // Hide from Dock and Cmd+Tab switcher — this is a background utility.
    application.setActivationPolicy(.accessory)

    application.run()
}
