import AppKit
import ApplicationServices

// ============================================================
// MARK: - Data Models
// ============================================================

/// Represents a single window from CGWindowList
struct AppWindow {
    let cgWindowId: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String?
}

/// Represents an app entry in the switcher — one entry per unique app
struct AppEntry {
    let bundleIdentifier: String
    let appName: String
    let pid: pid_t
    let windows: [AppWindow]
    let icon: NSImage?
}

// ============================================================
// MARK: - Group Manager
// ============================================================

/// Persists which apps belong to which groups (1–9, 0→group 10).
/// Stored in UserDefaults as [bundleID: groupNumber].
class GroupManager {
    static let shared = GroupManager()
    private let defaultsKey = "MintTabGroups_v1"
    private let lastGroupKey = "MintTabLastGroup"

    /// Persisted last used group. Defaults to 1 on first launch.
    var lastUsedGroup: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: lastGroupKey)
            return v == 0 ? 1 : v
        }
        set { UserDefaults.standard.set(newValue, forKey: lastGroupKey) }
    }

    /// Returns the group number for a given app, or nil if unassigned.
    func getGroup(for bundleID: String) -> Int? {
        let groups = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        return groups[bundleID]
    }

    /// Assigns an app to a group. Pass 0 to remove the assignment.
    func setGroup(_ group: Int, for bundleID: String) {
        var groups = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        if group <= 0 {
            groups.removeValue(forKey: bundleID)
        } else {
            groups[bundleID] = group
        }
        UserDefaults.standard.set(groups, forKey: defaultsKey)
    }

    /// Returns all bundle IDs assigned to the given group.
    func getAppsInGroup(_ group: Int) -> [String] {
        let groups = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
        return groups.filter { $0.value == group }.map { $0.key }
    }
}

// ============================================================
// MARK: - Windows Manager
// ============================================================

/// Enumerates on-screen windows, groups them by app, and filters by
/// the active group.
class WindowsManager {
    static let shared = WindowsManager()

    /// The current list of app entries (one per unique app), after
    /// group filtering and recency sorting.
    private(set) var appEntries: [AppEntry] = []

    /// Recency stack of bundle IDs. Index 0 = most recently focused.
    private var focusStack: [String] = []

    /// Last focus timestamp per window ID. Used in window-based switching mode
    /// to order windows by most recent switch time.
    private var windowLastFocusTime: [CGWindowID: Date] = [:]

    /// The currently active group. 0 = all apps (no filter).
    var currentGroup: Int = GroupManager.shared.lastUsedGroup {
        didSet {
            if currentGroup != oldValue {
                GroupManager.shared.lastUsedGroup = currentGroup
            }
        }
    }

    /// Switching mode: app-based or window-based.
    var switchingLogic: MintTabConfig.SwitchingLogic = .app

    /// Show Cmd+H hidden apps.
    var showHidden: Bool = false

    /// Show apps with no windows.
    var showWindowless: Bool = false

    // MARK: - Focus Stack

    /// Move bundleID to the front of the recency stack.
    func moveToFront(_ bundleID: String) {
        focusStack.removeAll { $0 == bundleID }
        focusStack.insert(bundleID, at: 0)
    }

    /// Append a new bundle ID to the end of the stack if not already present.
    private func appendToStack(_ bundleID: String) {
        if !focusStack.contains(bundleID) {
            focusStack.append(bundleID)
        }
    }

    private func removeFromStack(_ bundleID: String) {
        focusStack.removeAll { $0 == bundleID }
    }

    // MARK: - Window Focus Time (window mode)

    /// Record that a window was just focused.
    func touchWindowFocus(_ windowID: CGWindowID) {
        windowLastFocusTime[windowID] = Date()
    }

    private func removeWindowFocusTime(_ windowID: CGWindowID) {
        windowLastFocusTime.removeValue(forKey: windowID)
    }

    /// Find the frontmost visible window ID of the given app, skipping
    /// invisible / zero-size helper windows.
    private func activeWindowID(for bundleID: String) -> CGWindowID? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).first else { return nil }
        let pid = app.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements, .optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }
        for dict in windowList {
            guard let ownerPID = dict[kCGWindowOwnerPID] as? pid_t,
                  ownerPID == pid,
                  let layer = dict[kCGWindowLayer] as? Int32, layer == 0,
                  let windowID = dict[kCGWindowNumber] as? CGWindowID
            else { continue }

            if let alpha = dict[kCGWindowAlpha] as? Double, alpha <= 0 {
                continue
            }
            if let isOnScreen = dict[kCGWindowIsOnscreen] as? Bool, !isOnScreen {
                continue
            }
            if let boundsDict = dict[kCGWindowBounds] as? [String: Any],
               let width = boundsDict["Width"] as? Double,
               let height = boundsDict["Height"] as? Double,
               width <= 0 || height <= 0 {
                continue
            }

            return windowID
        }
        return nil
    }

    // MARK: - Accessibility-based window title fallback

    /// Describes an Accessibility API window for title matching.
    private struct AXWindowInfo {
        let title: String
        let bounds: CGRect
    }

    /// Try to obtain window titles via the Accessibility API. CGWindowList often
    /// returns empty kCGWindowName for background agents (e.g. brew services) that
    /// do not have Screen Recording permission, but Accessibility can still read
    /// window titles if it is granted.
    private func fetchAXWindowInfos(forPID pid: pid_t) -> [AXWindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard err == .success else { return [] }

        guard let windows = value as? [AXUIElement] else { return [] }
        var infos: [AXWindowInfo] = []
        infos.reserveCapacity(windows.count)

        for window in windows {
            var titleValue: CFTypeRef?
            var title = ""
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success {
                if let t = titleValue as? String { title = t }
            }

            var bounds = CGRect.null
            var posValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success {
                var point = CGPoint.zero
                if let pv = posValue,
                   AXValueGetValue(pv as! AXValue, .cgPoint, &point) {
                    bounds.origin = point
                }
            }

            var sizeValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success {
                var size = CGSize.zero
                if let sv = sizeValue,
                   AXValueGetValue(sv as! AXValue, .cgSize, &size) {
                    bounds.size = size
                }
            }

            if !title.isEmpty {
                infos.append(AXWindowInfo(title: title, bounds: bounds))
            }
        }
        return infos
    }

    private func axTitleMatching(
        cgBounds: CGRect,
        axInfos: [AXWindowInfo],
        tolerance: CGFloat = 2
    ) -> String? {
        for info in axInfos {
            let closeOrigin = abs(info.bounds.origin.x - cgBounds.origin.x) < tolerance
                && abs(info.bounds.origin.y - cgBounds.origin.y) < tolerance
            let closeSize = abs(info.bounds.size.width - cgBounds.size.width) < tolerance
                && abs(info.bounds.size.height - cgBounds.size.height) < tolerance
            if closeOrigin && closeSize { return info.title }
        }
        return nil
    }

    /// Reorder entries by most recent focus time. Windows without a recorded
    /// time are treated as oldest and keep their original relative order.
    private func reorderWindowsByTime(_ entries: inout [AppEntry]) {
        let distantPast = Date.distantPast
        entries.sort {
            let t0 = windowLastFocusTime[$0.windows.first?.cgWindowId ?? 0] ?? distantPast
            let t1 = windowLastFocusTime[$1.windows.first?.cgWindowId ?? 0] ?? distantPast
            return t0 > t1
        }
    }

    /// Reorder entries to match focus stack order. New apps go to the end.
    /// Seeds the stack from z-order on first run.
    private func reorderByStack(_ entries: inout [AppEntry]) {
        if focusStack.isEmpty {
            for e in entries where !focusStack.contains(e.bundleIdentifier) {
                focusStack.append(e.bundleIdentifier)
            }
        }
        // Group entries by bundle ID (preserving original order within each group)
        var groups: [String: [AppEntry]] = [:]
        var groupOrder: [String] = []
        for e in entries {
            if groups[e.bundleIdentifier] == nil {
                groups[e.bundleIdentifier] = []
                groupOrder.append(e.bundleIdentifier)
            }
            groups[e.bundleIdentifier]!.append(e)
        }
        // Produce entries in stack order, then append unseen
        var ordered: [AppEntry] = []
        for bid in focusStack {
            if let group = groups[bid] { ordered.append(contentsOf: group) }
        }
        for bid in groupOrder where !focusStack.contains(bid) {
            ordered.append(contentsOf: groups[bid]!)
            focusStack.append(bid)
        }
        entries = ordered
    }

    // MARK: - Workspace Monitoring

    func startMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bid = app.bundleIdentifier,
              bid != Bundle.main.bundleIdentifier
        else { return }
        appendToStack(bid)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bid = app.bundleIdentifier
        else { return }
        removeFromStack(bid)
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bid = app.bundleIdentifier,
              bid != Bundle.main.bundleIdentifier
        else { return }
        moveToFront(bid)
        if switchingLogic == .window, let windowID = activeWindowID(for: bid) {
            touchWindowFocus(windowID)
        }
        sortAppEntries()
    }

    private func sortAppEntries() {
        if switchingLogic == .app {
            reorderByStack(&appEntries)
        } else {
            reorderWindowsByTime(&appEntries)
        }
    }

    /// Refresh the window list by calling CGWindowListCopyWindowInfo,
    /// grouping by bundle identifier, and applying the group filter.
    /// Pass `includeHidden: true` for show-all mode to also include off-screen
    /// / minimized windows and to skip the current-group filter.
    func refresh(includeHidden: Bool = false) {
        let listOptions: CGWindowListOption = includeHidden
            ? [.excludeDesktopElements]
            : [.excludeDesktopElements, .optionOnScreenOnly]
        guard
            let windowList = CGWindowListCopyWindowInfo(
                listOptions,
                kCGNullWindowID
            ) as? [[CFString: Any]]
        else {
            appEntries = []
            return
        }

        // Build a lookup of running apps by PID for icons and bundle IDs.
        let runningApps = NSWorkspace.shared.runningApplications
        let appsByPID: [pid_t: NSRunningApplication] = Dictionary(
            uniqueKeysWithValues: runningApps.map { ($0.processIdentifier, $0) }
        )

        // Group windows by bundle ID (or fallback to "pid.XXXX")
        var windowGroups:
            [String: (name: String, pid: pid_t, windows: [AppWindow], icon: NSImage?)] = [:]
        var validWindows: [AppWindow] = []

        // Cache Accessibility window titles per PID so we only query each app once.
        var axTitleCache: [pid_t: [AXWindowInfo]] = [:]

        for windowDict in windowList {
            guard let layer = windowDict[kCGWindowLayer] as? Int32, layer == 0,
                let ownerPID = windowDict[kCGWindowOwnerPID] as? pid_t,
                let ownerName = windowDict[kCGWindowOwnerName] as? String,
                let windowID = windowDict[kCGWindowNumber] as? CGWindowID
            else { continue }

            // Skip invisible / off-screen / zero-size windows that some apps
            // (e.g. Helium) report as layer-0 windows.
            if let alpha = windowDict[kCGWindowAlpha] as? Double, alpha <= 0 {
                continue
            }
            if !includeHidden,
               let isOnScreen = windowDict[kCGWindowIsOnscreen] as? Bool, !isOnScreen {
                continue
            }
            let cgBounds: CGRect
            if let boundsDict = windowDict[kCGWindowBounds] as? [String: Any],
               let x = boundsDict["X"] as? Double,
               let y = boundsDict["Y"] as? Double,
               let width = boundsDict["Width"] as? Double,
               let height = boundsDict["Height"] as? Double {
                if width <= 0 || height <= 0 { continue }
                cgBounds = CGRect(x: x, y: y, width: width, height: height)
            } else {
                continue
            }

            var title = windowDict[kCGWindowName] as? String
            if title == nil || title?.isEmpty == true {
                var axInfos = axTitleCache[ownerPID]
                if axInfos == nil {
                    axInfos = fetchAXWindowInfos(forPID: ownerPID)
                    axTitleCache[ownerPID] = axInfos
                }
                if let axTitle = axTitleMatching(cgBounds: cgBounds, axInfos: axInfos ?? []) {
                    title = axTitle
                }
            }

            let runningApp = appsByPID[ownerPID]
            let bundleID = runningApp?.bundleIdentifier ?? "pid.\(ownerPID)"

            // Skip our own window
            if bundleID == Bundle.main.bundleIdentifier { continue }

            let window = AppWindow(
                cgWindowId: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: title
            )

            validWindows.append(window)

            if var existing = windowGroups[bundleID] {
                existing.windows.append(window)
                windowGroups[bundleID] = existing
            } else {
                windowGroups[bundleID] = (
                    name: ownerName,
                    pid: ownerPID,
                    windows: [window],
                    icon: runningApp?.icon
                )
            }
        }

        // Convert to AppEntry array.
        var entries: [AppEntry]
        if switchingLogic == .window {
            // Window-based: one entry per window, ordered by window recency.
            // The current active window is kept at index 0; index 1 is the
            // previously focused window.
            entries = validWindows.map { window in
                let runningApp = appsByPID[window.ownerPID]
                let bid = runningApp?.bundleIdentifier ?? "pid.\(window.ownerPID)"
                return AppEntry(
                    bundleIdentifier: bid,
                    appName: window.ownerName,
                    pid: window.ownerPID,
                    windows: [window],
                    icon: runningApp?.icon
                )
            }

            // Prune timestamps of closed windows.
            let visibleWindowIDs = Set(entries.compactMap { $0.windows.first?.cgWindowId })
            for id in windowLastFocusTime.keys where !visibleWindowIDs.contains(id) {
                windowLastFocusTime.removeValue(forKey: id)
            }

            // Seed timestamps from current z-order on first run so the initial
            // order is reasonable until real focus events build up history.
            if windowLastFocusTime.isEmpty {
                let now = Date()
                for (offset, e) in entries.enumerated() {
                    if let id = e.windows.first?.cgWindowId {
                        windowLastFocusTime[id] = now.addingTimeInterval(-Double(offset))
                    }
                }
            }

            // Make sure the currently active window is treated as most recent.
            let frontBid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            print("[MintTab] refresh(window) frontmostApp=\(frontBid ?? "nil") entries=\(entries.count)")
            print("[MintTab]   before sort: \(entries.prefix(5).map { "\($0.appName):\($0.windows.first?.cgWindowId ?? 0)=\(self.windowLastFocusTime[$0.windows.first?.cgWindowId ?? 0]?.timeIntervalSince1970 ?? 0)" })")
            if let frontBid = frontBid,
               let frontEntry = entries.first(where: { $0.bundleIdentifier == frontBid }),
               let frontID = frontEntry.windows.first?.cgWindowId {
                touchWindowFocus(frontID)
                print("[MintTab]   touched current window \(frontID) (\(frontEntry.appName))")
            }

            reorderWindowsByTime(&entries)
            print("[MintTab]   after sort:  \(entries.prefix(5).map { "\($0.appName):\($0.windows.first?.cgWindowId ?? 0)" })")
        } else {
            // App-based: build entries, sort by focus stack order
            entries = windowGroups.map { (bundleID, group) in
                AppEntry(
                    bundleIdentifier: bundleID,
                    appName: group.name,
                    pid: group.pid,
                    windows: group.windows.sorted { $0.cgWindowId > $1.cgWindowId },
                    icon: group.icon
                )
            }
            reorderByStack(&entries)
        }

        // Group filtering (skip in show-all mode)
        if !includeHidden, currentGroup > 0 {
            let groupBundleIDs = Set(GroupManager.shared.getAppsInGroup(currentGroup))
            if currentGroup == 1 {
                // Group 1 includes ungrouped apps
                let allGroupedIDs = Set((1...9).flatMap { GroupManager.shared.getAppsInGroup($0) })
                entries = entries.filter {
                    groupBundleIDs.contains($0.bundleIdentifier) || !allGroupedIDs.contains($0.bundleIdentifier)
                }
            } else {
                entries = entries.filter { groupBundleIDs.contains($0.bundleIdentifier) }
            }
        }

        // Add hidden/windowless apps if enabled (app mode only; window mode
        // shows individual windows, so app-level hidden/windowless entries
        // don't apply and would destroy the recency ordering).
        if switchingLogic == .app && (showHidden || showWindowless) {
            let visibleBundleIDs = Set(entries.map { $0.bundleIdentifier })
            for app in runningApps {
                guard let bid = app.bundleIdentifier,
                      !visibleBundleIDs.contains(bid),
                      bid != Bundle.main.bundleIdentifier,
                      app.activationPolicy == .regular
                else { continue }
                let isHidden = app.isHidden
                let isWindowless = true // no layer-0 windows found
                if (showHidden && isHidden) || (showWindowless && isWindowless) {
                    entries.append(AppEntry(
                        bundleIdentifier: bid,
                        appName: app.localizedName ?? bid,
                        pid: app.processIdentifier,
                        windows: [],
                        icon: app.icon
                    ))
                }
            }
            entries.sort {
                ($0.windows.first?.cgWindowId ?? 0) > ($1.windows.first?.cgWindowId ?? 0)
            }
        }

        appEntries = entries
    }

    /// Update recency order when an app is activated via the switcher.
    func recordActivation(_ bundleID: String, windowID: CGWindowID? = nil) {
        print("[MintTab] recordActivation bundle=\(bundleID) window=\(windowID?.description ?? "nil")")
        moveToFront(bundleID)
        if let windowID {
            touchWindowFocus(windowID)
            print("[MintTab]   -> touched window \(windowID), time=\(windowLastFocusTime[windowID] ?? Date.distantPast)")
        }
        sortAppEntries()
        print("[MintTab]   -> appEntries order: \(appEntries.prefix(5).map { "\($0.appName):\($0.windows.first?.cgWindowId ?? 0)" })")
    }

    /// Cycle to the next non-empty group. Wraps around to 0 (all).
    func nextGroup() {
        let allGroups = allActiveGroups()
        guard !allGroups.isEmpty else { return }
        if let idx = allGroups.firstIndex(of: currentGroup) {
            currentGroup = allGroups[(idx + 1) % allGroups.count]
        } else {
            currentGroup = allGroups[0]
        }
    }

    /// Cycle to the previous non-empty group. Wraps around.
    func previousGroup() {
        let allGroups = allActiveGroups()
        guard !allGroups.isEmpty else { return }
        if let idx = allGroups.firstIndex(of: currentGroup) {
            currentGroup = allGroups[(idx - 1 + allGroups.count) % allGroups.count]
        } else {
            currentGroup = allGroups.last ?? 0
        }
    }

    /// Return all groups (1-9) that have at least one app, plus 0 (all).
    private func allActiveGroups() -> [Int] {
        var groups = Set<Int>()
        for entry in appEntries {
            if let g = GroupManager.shared.getGroup(for: entry.bundleIdentifier) {
                groups.insert(g)
            }
        }
        return [0] + Array(groups).sorted()
    }

    /// Returns entries organized by group for the "show all" display.
    func groupedEntries(groupNames: [String]? = nil) -> [(group: Int, label: String, entries: [AppEntry])] {
        let names = groupNames ?? (1...9).map { "Group \($0)" }

        // Temporarily get all entries without group filter
        let savedGroup = currentGroup
        currentGroup = 0
        refresh()
        let all = appEntries
        currentGroup = savedGroup

        var sections: [(Int, String, [AppEntry])] = []

        // Groups 1-9 (group 1 includes ungrouped apps)
        let allGroupedIDs = Set((1...9).flatMap { GroupManager.shared.getAppsInGroup($0) })
        for g in 1...9 {
            let groupBundleIDs = Set(GroupManager.shared.getAppsInGroup(g))
            var groupEntries = all.filter { groupBundleIDs.contains($0.bundleIdentifier) }
            if g == 1 {
                let ungrouped = all.filter { !allGroupedIDs.contains($0.bundleIdentifier) }
                groupEntries = ungrouped + groupEntries
            }
            if !groupEntries.isEmpty {
                sections.append((g, names[g - 1], groupEntries))
            }
        }

        return sections
    }
}
