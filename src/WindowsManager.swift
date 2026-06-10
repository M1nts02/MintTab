import AppKit

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
    /// group filtering and z-order sorting.
    private(set) var appEntries: [AppEntry] = []

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

    /// Refresh the window list by calling CGWindowListCopyWindowInfo,
    /// grouping by bundle identifier, and applying the group filter.
    func refresh() {
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.excludeDesktopElements, .optionOnScreenOnly],
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

        for windowDict in windowList {
            guard let layer = windowDict[kCGWindowLayer] as? Int32, layer == 0,
                let ownerPID = windowDict[kCGWindowOwnerPID] as? pid_t,
                let ownerName = windowDict[kCGWindowOwnerName] as? String,
                let windowID = windowDict[kCGWindowNumber] as? CGWindowID
            else { continue }

            let title = windowDict[kCGWindowName] as? String
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

        // Convert to AppEntry array, preserving z-order from windowList.
        var entries: [AppEntry]
        if switchingLogic == .window {
            // Window-based: one entry per window, already in z-order
            entries = validWindows.map { window in
                let runningApp = appsByPID[window.ownerPID]
                return AppEntry(
                    bundleIdentifier: runningApp?.bundleIdentifier ?? "pid.\(window.ownerPID)",
                    appName: window.ownerName,
                    pid: window.ownerPID,
                    windows: [window],
                    icon: runningApp?.icon
                )
            }
        } else {
            // App-based: group by bundle ID, sort by topmost window z-order
            // Build z-position lookup from validWindows order (front-to-back)
            var zOrder: [String: Int] = [:]
            for (idx, w) in validWindows.enumerated() {
                let bid = appsByPID[w.ownerPID]?.bundleIdentifier ?? "pid.\(w.ownerPID)"
                if zOrder[bid] == nil { zOrder[bid] = idx }
            }
            entries = windowGroups.map { (bundleID, group) in
                AppEntry(
                    bundleIdentifier: bundleID,
                    appName: group.name,
                    pid: group.pid,
                    windows: group.windows.sorted { $0.cgWindowId > $1.cgWindowId },
                    icon: group.icon
                )
            }
            entries.sort {
                (zOrder[$0.bundleIdentifier] ?? Int.max) < (zOrder[$1.bundleIdentifier] ?? Int.max)
            }
        }

        // Group filtering
        if currentGroup > 0 {
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

        // Add hidden/windowless apps if enabled
        if showHidden || showWindowless {
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
    /// Section 0 = ungrouped, sections 1-9 = groups.
    func groupedEntries() -> [(group: Int, label: String, entries: [AppEntry])] {
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
                sections.append((g, "Group \(g)", groupEntries))
            }
        }

        return sections
    }
}
