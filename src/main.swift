import AppKit
import Carbon

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

/// Local event monitor for key events while panel is shown.
private var localEventMonitor: Any?

// ============================================================
// MARK: - CGEvent Tap Callback
// ============================================================

/// File-level closure stored so it can be safely bridged to a C function pointer.
/// Tracks changes to the modifier flags and posts them to the main queue.
private let flagsChangedCallback: CGEventTapCallBack = {
    (_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?)
        -> Unmanaged<CGEvent>? in
    if type == .flagsChanged {
        let flags = event.flags
        DispatchQueue.main.async {
            flagsChanged(modifiers: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
        }
    }
    return Unmanaged.passUnretained(event)
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

    // --- Register group hotkeys (only when grouping enabled) ---
    if activeConfig.grouping {
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

/// Create a CGEvent tap that listens *only* for flagsChanged so we know
/// when the Option key is released regardless of Tab state.
private func setupEventTap() {
    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

    eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: flagsChangedCallback,
        userInfo: nil
    )

    if let tap = eventTap {
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    } else {
        print(
            "[MintTab] Warning: could not create event tap. Option-release detection may be unreliable (accessibility permission may be needed)."
        )
    }
}

/// Local event monitor: fallback for key events when panel is key.
private func setupLocalEventMonitor() {
    localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
        guard panelVisible else { return event }
        handlePanelKey(nil)  // fallback — also try the view's handler
        return event
    }
}

private func handlePanelKey(_ action: String?) {
    guard panelVisible else { return }
    if let action {
        switch action {
        case "tab":     cycleSelection(forward: true)
        case "shiftTab": cycleSelection(forward: false)
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
            if !panelVisible {
                showPanel()
            } else {
                cycleSelection(forward: true)
            }
        } else {
            if panelVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard panelVisible else { return }
                    if !triggerModifierHeld {
                        dismissPanel(select: true)
                    }
                }
            }
        }

    case HotkeyID.switchShiftTab:
        if pressed && panelVisible {
            cycleSelection(forward: false)
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
        if panelVisible { showPanel() }

    case HotkeyID.prevGroup:
        guard pressed else { break }
        WindowsManager.shared.previousGroup()
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

// ============================================================
// MARK: - Panel Show / Hide / Cycle
// ============================================================

private func showPanel() {
    // Auto-switch to frontmost app's group
    if activeConfig.autoGroup, activeConfig.grouping {
        if let frontBid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let group = GroupManager.shared.getGroup(for: frontBid) {
            WindowsManager.shared.currentGroup = group
        } else {
            WindowsManager.shared.currentGroup = 1
        }
    }
    WindowsManager.shared.refresh()
    let entries = WindowsManager.shared.appEntries
    guard !entries.isEmpty else { return }

    currentEntries = entries
    isShowingAll = false
    selectedIndex = min(1, entries.count - 1)
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
}

/// Show-all: grouped display with all windows, ignoring current group filter.
private func showAllPanel() {
    WindowsManager.shared.refresh()
    let sections = WindowsManager.shared.groupedEntries()
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
        guard dragIdx < currentEntries.count, targetIdx < currentEntries.count else { return }
        let draggedBundle = currentEntries[dragIdx].bundleIdentifier
        let targetBundle = currentEntries[targetIdx].bundleIdentifier
        var targetGroup = 1
        for s in sections {
            if s.entries.contains(where: { $0.bundleIdentifier == targetBundle }) {
                targetGroup = s.group
                break
            }
        }
        GroupManager.shared.setGroup(targetGroup, for: draggedBundle)
        showAllPanel()
    }
    SwitcherPanel.shared.showGrouped(
        sections: sections, selectedIndex: selectedIndex, size: activeConfig.uiSize)
}

private func dismissPanel(select: Bool) {
    guard panelVisible else { return }

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
    guard let frontApp = NSWorkspace.shared.frontmostApplication,
        let bundleID = frontApp.bundleIdentifier
    else { return }

    // Toggle: if already in this group, remove. Otherwise assign.
    if GroupManager.shared.getGroup(for: bundleID) == group {
        GroupManager.shared.setGroup(0, for: bundleID)
        print("[MintTab] \(frontApp.localizedName ?? bundleID) removed from group \(group)")
    } else {
        GroupManager.shared.setGroup(group, for: bundleID)
        if activeConfig.assignSwitch {
            WindowsManager.shared.currentGroup = group
        }
        print("[MintTab] \(frontApp.localizedName ?? bundleID) → Group \(group)")
    }

    if panelVisible {
        showPanel()
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

        setupIPCListener()
        setupCarbonHotkeys()
        setupEventTap()
        setupLocalEventMonitor()

        let logicLabel = activeConfig.switchingLogic == .app ? "app" : "window"
        let styleLabel = activeConfig.uiStyle == .icons ? "icons" : "list"
        let switchMod = activeConfig.switchMod.rawValue
        print(
            "MintTab ready.  Mode: \(logicLabel)  |  Style: \(styleLabel)  |  Switch: \(switchMod)+tab  |  Config: ~/.config/minttab/config"
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            }
        case "show-all":
            if !panelVisible { showAllPanel() }
        case "show-panel":
            if !panelVisible { showPanel() }
        default:
            print("[MintTab] Unknown IPC command: \(action)")
        }
    }
}

// ============================================================
// MARK: - Entry Point
// ============================================================

autoreleasepool {
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
