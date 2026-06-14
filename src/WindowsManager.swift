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

/// A group section used by the "show all" grouped display.
struct AppGroupSection {
    let group: Int
    let label: String
    let entries: [AppEntry]
}

/// Stable identifier for command-line GUI apps that have no bundle ID.
/// Grouping uses this instead of `cli.<pid>` so all instances of the same
/// CLI app (e.g. mpv) share the same group assignment.
func cliBundleIdentifier(forProcessName name: String) -> String {
    return "cli.\(name)"
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

/// Enumerates on-screen windows and filters them by the active group.
class WindowsManager {
    static let shared = WindowsManager()

    /// The current list of app entries (one per unique app), after
    /// group filtering and recency sorting.
    private(set) var appEntries: [AppEntry] = []

    /// Last focus timestamp per window ID. Used to order windows by most
    /// recent switch time.
    private var windowLastFocusTime: [CGWindowID: Date] = [:]

    /// The currently active group. 0 = all apps (no filter).
    var currentGroup: Int = GroupManager.shared.lastUsedGroup {
        didSet {
            if currentGroup != oldValue {
                GroupManager.shared.lastUsedGroup = currentGroup
            }
        }
    }

    /// Show windows from Cmd+H hidden apps.
    var showHidden: Bool = false

    // MARK: - Window Focus Time

    /// Record that a window was just focused.
    func touchWindowFocus(_ windowID: CGWindowID) {
        windowLastFocusTime[windowID] = Date()
    }

    /// Find the frontmost visible window ID of the given app, skipping
    /// invisible / zero-size helper windows.
    private func activeWindowID(forPID pid: pid_t) -> CGWindowID? {
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

            infos.append(AXWindowInfo(title: title, bounds: bounds))
        }
        return infos
    }

    private func axTitleMatching(
        cgBounds: CGRect,
        axInfos: [AXWindowInfo],
        tolerance: CGFloat = 2
    ) -> String? {
        for info in axInfos {
            if axBoundsMatch(cgBounds: cgBounds, axBounds: info.bounds, tolerance: tolerance) {
                return info.title
            }
        }
        return nil
    }

    private func axBoundsMatch(
        cgBounds: CGRect,
        axBounds: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        let closeOrigin = abs(axBounds.origin.x - cgBounds.origin.x) < tolerance
            && abs(axBounds.origin.y - cgBounds.origin.y) < tolerance
        let closeSize = abs(axBounds.size.width - cgBounds.size.width) < tolerance
            && abs(axBounds.size.height - cgBounds.size.height) < tolerance
        return closeOrigin && closeSize
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

    // MARK: - Workspace Monitoring

    func startMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        if let windowID = activeWindowID(forPID: app.processIdentifier) {
            touchWindowFocus(windowID)
        }
        sortAppEntries()
    }

    private func sortAppEntries() {
        reorderWindowsByTime(&appEntries)
    }

    /// Refresh the window list using the `showHidden` config value.
    func refresh() {
        refresh(includeHidden: showHidden, ignoreGroupFilter: false)
    }

    /// Refresh the window list by calling CGWindowListCopyWindowInfo and
    /// applying the group filter.
    /// - Parameters:
    ///   - includeHidden: include windows from Cmd+H hidden apps.
    ///   - ignoreGroupFilter: skip the current-group filter (used by show-all).
    func refresh(includeHidden: Bool, ignoreGroupFilter: Bool = false) {
        // Build a lookup of running apps by PID for icons and bundle IDs.
        let runningApps = NSWorkspace.shared.runningApplications
        let appsByPID: [pid_t: NSRunningApplication] = Dictionary(
            uniqueKeysWithValues: runningApps.map { ($0.processIdentifier, $0) }
        )

        // 1. Visible windows only (this is the baseline for normal switching).
        let visibleWindows = fetchCGWindows(
            options: [.excludeDesktopElements, .optionOnScreenOnly],
            appsByPID: appsByPID
        )

        // 2. Convert visible windows to entries: one entry per window.
        var entries = visibleWindows.map { window in
            let runningApp = appsByPID[window.ownerPID]
            let bid = runningApp?.bundleIdentifier
                ?? cliBundleIdentifier(forProcessName: window.ownerName)
            return AppEntry(
                bundleIdentifier: bid,
                appName: window.ownerName,
                pid: window.ownerPID,
                windows: [window],
                icon: runningApp?.icon
            )
        }

        // 3. If requested, also include Cmd+H hidden apps as a single collapsed
        // entry per app (app name only), so hidden apps like Ghostty do not
        // expose their individual tabs/panes in the switcher.
        if includeHidden {
            let ourPID = ProcessInfo.processInfo.processIdentifier
            let hiddenApps = runningApps.filter {
                $0.processIdentifier != ourPID &&
                $0.isHidden &&
                $0.activationPolicy == .regular
            }
            let visibleBundleIDs = Set(entries.map { $0.bundleIdentifier })
            for app in hiddenApps {
                let bid = app.bundleIdentifier
                    ?? cliBundleIdentifier(forProcessName: app.localizedName ?? "unknown")
                guard !visibleBundleIDs.contains(bid) else { continue }
                entries.append(AppEntry(
                    bundleIdentifier: bid,
                    appName: app.localizedName ?? bid,
                    pid: app.processIdentifier,
                    windows: [],
                    icon: app.icon
                ))
            }
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
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontBid = frontApp?.bundleIdentifier ?? frontApp.flatMap {
            $0.processIdentifier != ourPID
                ? cliBundleIdentifier(forProcessName: $0.localizedName ?? "")
                : nil
        }
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

        // Group filtering (skip when requested)
        if !ignoreGroupFilter, currentGroup > 0 {
            let groupBundleIDs = Set(GroupManager.shared.getAppsInGroup(currentGroup))
            let allGroupedIDs = Set((1...9).flatMap { GroupManager.shared.getAppsInGroup($0) })
            // The active group shows its assigned apps plus all ungrouped apps,
            // so ungrouped apps behave as if they belong to the current group.
            entries = entries.filter {
                groupBundleIDs.contains($0.bundleIdentifier) || !allGroupedIDs.contains($0.bundleIdentifier)
            }
        }

        appEntries = entries
    }

    /// Fetch layer-0 windows from CGWindowList and convert to AppWindows,
    /// skipping background agents and MintTab itself.
    private func fetchCGWindows(
        options: CGWindowListOption,
        appsByPID: [pid_t: NSRunningApplication]
    ) -> [AppWindow] {
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }

        var axTitleCache: [pid_t: [AXWindowInfo]] = [:]
        var seenWindowIDs = Set<CGWindowID>()
        var result: [AppWindow] = []

        for windowDict in windowList {
            guard let layer = windowDict[kCGWindowLayer] as? Int32, layer == 0,
                  let ownerPID = windowDict[kCGWindowOwnerPID] as? pid_t,
                  let ownerName = windowDict[kCGWindowOwnerName] as? String,
                  let windowID = windowDict[kCGWindowNumber] as? CGWindowID,
                  !seenWindowIDs.contains(windowID)
            else { continue }
            seenWindowIDs.insert(windowID)

            if let alpha = windowDict[kCGWindowAlpha] as? Double, alpha <= 0 { continue }
            if let isOnScreen = windowDict[kCGWindowIsOnscreen] as? Bool, !isOnScreen { continue }

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

            // Skip background agents / helper processes (e.g. CursorUIService)
            // and MintTab itself. Use PID for self-exclusion because command-line
            // binaries may not have a bundle identifier, and comparing nil bundle
            // IDs would also exclude other CLI GUI apps like mpv.
            let ourPID = ProcessInfo.processInfo.processIdentifier
            guard let runningApp = appsByPID[ownerPID],
                  runningApp.activationPolicy == .regular,
                  runningApp.processIdentifier != ourPID
            else { continue }

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

            result.append(AppWindow(
                cgWindowId: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: title
            ))
        }

        return result
    }


    /// Update recency order when an app is activated via the switcher.
    func recordActivation(_ bundleID: String, windowID: CGWindowID? = nil) {
        print("[MintTab] recordActivation bundle=\(bundleID) window=\(windowID?.description ?? "nil")")
        if let windowID {
            touchWindowFocus(windowID)
            print("[MintTab]   -> touched window \(windowID), time=\(windowLastFocusTime[windowID] ?? Date.distantPast)")
        }
        sortAppEntries()
        print("[MintTab]   -> appEntries order: \(appEntries.prefix(5).map { "\($0.appName):\($0.windows.first?.cgWindowId ?? 0)" })")
    }

    /// Returns entries organized by group for the "show all" display.
    func groupedEntries(includeHidden: Bool = false, groupNames: [String]? = nil) -> [AppGroupSection] {
        let names = groupNames ?? (1...9).map { "Group \($0)" }

        // Temporarily get all entries without group filter
        let savedGroup = currentGroup
        currentGroup = 0
        refresh(includeHidden: includeHidden, ignoreGroupFilter: true)
        let all = appEntries
        currentGroup = savedGroup

        var sections: [AppGroupSection] = []

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
                sections.append(AppGroupSection(group: g, label: names[g - 1], entries: groupEntries))
            }
        }

        return sections
    }
}
