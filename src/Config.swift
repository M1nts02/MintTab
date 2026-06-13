import AppKit

// ============================================================
// MARK: - Carbon Key Code Constants
// ============================================================

enum KeyCode {
    // ANSI letters (physical US keyboard positions)
    static let a: UInt32 = 0x00; static let s: UInt32 = 0x01; static let d: UInt32 = 0x02
    static let f: UInt32 = 0x03; static let h: UInt32 = 0x04; static let g: UInt32 = 0x05
    static let z: UInt32 = 0x06; static let x: UInt32 = 0x07; static let c: UInt32 = 0x08
    static let v: UInt32 = 0x09; static let b: UInt32 = 0x0B; static let q: UInt32 = 0x0C
    static let w: UInt32 = 0x0D; static let e: UInt32 = 0x0E; static let r: UInt32 = 0x0F
    static let y: UInt32 = 0x10; static let t: UInt32 = 0x11; static let o: UInt32 = 0x1F
    static let u: UInt32 = 0x20; static let i: UInt32 = 0x22; static let p: UInt32 = 0x23
    static let l: UInt32 = 0x25; static let j: UInt32 = 0x26; static let k: UInt32 = 0x28
    static let n: UInt32 = 0x2D; static let m: UInt32 = 0x2E

    // Digits
    static let grave: UInt32 = 0x32  // backtick `
    static let ansi0: UInt32 = 0x1D; static let ansi1: UInt32 = 0x12
    static let ansi2: UInt32 = 0x13; static let ansi3: UInt32 = 0x14
    static let ansi4: UInt32 = 0x15; static let ansi5: UInt32 = 0x17
    static let ansi6: UInt32 = 0x16; static let ansi7: UInt32 = 0x1A
    static let ansi8: UInt32 = 0x1C; static let ansi9: UInt32 = 0x19

    // Special keys
    static let tab: UInt32 = 0x30
    static let space: UInt32 = 0x31
    static let escape: UInt32 = 0x35
    static let `return`: UInt32 = 0x24
    static let delete: UInt32 = 0x33
    static let forwardDelete: UInt32 = 0x75

    // Arrow keys
    static let upArrow: UInt32 = 0x7E
    static let downArrow: UInt32 = 0x7D
    static let leftArrow: UInt32 = 0x7B
    static let rightArrow: UInt32 = 0x7C

    // Function keys
    static let f1: UInt32 = 0x7A; static let f2: UInt32 = 0x78; static let f3: UInt32 = 0x63
    static let f4: UInt32 = 0x76; static let f5: UInt32 = 0x60; static let f6: UInt32 = 0x61
    static let f7: UInt32 = 0x62; static let f8: UInt32 = 0x64; static let f9: UInt32 = 0x65
    static let f10: UInt32 = 0x6D; static let f11: UInt32 = 0x67; static let f12: UInt32 = 0x6F

    static func forDigit(_ digit: Int) -> UInt32 {
        switch digit {
        case 0: return ansi0; case 1: return ansi1; case 2: return ansi2
        case 3: return ansi3; case 4: return ansi4; case 5: return ansi5
        case 6: return ansi6; case 7: return ansi7; case 8: return ansi8
        case 9: return ansi9
        default: return ansi0
        }
    }
}

// ============================================================
// MARK: - Carbon Modifier Constants
// ============================================================

enum CarbonMod {
    static let command: UInt32 = 0x0100
    static let shift: UInt32 = 0x0200
    static let option: UInt32 = 0x0800
    static let control: UInt32 = 0x1000

    /// Parse a modifier name like "alt", "cmd", "ctrl".
    static func parse(_ name: String) -> UInt32 {
        switch name.lowercased() {
        case "alt", "option": return option
        case "cmd", "command": return command
        case "ctrl", "control": return control
        case "shift": return shift
        default: return 0
        }
    }

    /// Carbon modifier flags → NSEvent.ModifierFlags for event tap tracking.
    static func nsEventFlag(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & option != 0 { flags.insert(.option) }
        if carbon & control != 0 { flags.insert(.control) }
        if carbon & command != 0 { flags.insert(.command) }
        if carbon & shift != 0 { flags.insert(.shift) }
        return flags
    }
}

extension CGEventFlags {
    /// Convert CGEventFlags to Carbon modifier mask.
    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        if contains(.maskShift) { mods |= CarbonMod.shift }
        if contains(.maskControl) { mods |= CarbonMod.control }
        if contains(.maskAlternate) { mods |= CarbonMod.option }
        if contains(.maskCommand) { mods |= CarbonMod.command }
        return mods
    }
}

extension NSEvent.ModifierFlags {
    /// Convert NSEvent.ModifierFlags to Carbon modifier mask.
    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        if contains(.shift) { mods |= CarbonMod.shift }
        if contains(.control) { mods |= CarbonMod.control }
        if contains(.option) { mods |= CarbonMod.option }
        if contains(.command) { mods |= CarbonMod.command }
        return mods
    }
}

// ============================================================
// MARK: - Parsed Keybinding
// ============================================================

struct ParsedKeybinding: Equatable {
    let modifiers: UInt32
    let keyCode: UInt32

    static let none = ParsedKeybinding(modifiers: 0, keyCode: 0)
}

// ============================================================
// MARK: - Keybinding Parser
// ============================================================

enum KeybindingParser {
    private static let keyNameMap: [String: UInt32] = [
        "tab": KeyCode.tab, "space": KeyCode.space,
        "escape": KeyCode.escape, "esc": KeyCode.escape,
        "return": KeyCode.return, "enter": KeyCode.return,
        "delete": KeyCode.delete, "backspace": KeyCode.delete,
        "up": KeyCode.upArrow, "down": KeyCode.downArrow,
        "left": KeyCode.leftArrow, "right": KeyCode.rightArrow,
        "f1": KeyCode.f1, "f2": KeyCode.f2, "f3": KeyCode.f3,
        "f4": KeyCode.f4, "f5": KeyCode.f5, "f6": KeyCode.f6,
        "f7": KeyCode.f7, "f8": KeyCode.f8, "f9": KeyCode.f9,
        "f10": KeyCode.f10, "f11": KeyCode.f11, "f12": KeyCode.f12,
        "a": KeyCode.a, "b": KeyCode.b, "c": KeyCode.c, "d": KeyCode.d,
        "e": KeyCode.e, "f": KeyCode.f, "g": KeyCode.g, "h": KeyCode.h,
        "i": KeyCode.i, "j": KeyCode.j, "k": KeyCode.k, "l": KeyCode.l,
        "m": KeyCode.m, "n": KeyCode.n, "o": KeyCode.o, "p": KeyCode.p,
        "q": KeyCode.q, "r": KeyCode.r, "s": KeyCode.s, "t": KeyCode.t,
        "u": KeyCode.u, "v": KeyCode.v, "w": KeyCode.w, "x": KeyCode.x,
        "y": KeyCode.y, "z": KeyCode.z,
        "`": KeyCode.grave, "grave": KeyCode.grave,
        "0": KeyCode.ansi0, "1": KeyCode.ansi1, "2": KeyCode.ansi2,
        "3": KeyCode.ansi3, "4": KeyCode.ansi4, "5": KeyCode.ansi5,
        "6": KeyCode.ansi6, "7": KeyCode.ansi7, "8": KeyCode.ansi8,
        "9": KeyCode.ansi9,
    ]

    /// Parse "mod+key" → ParsedKeybinding. Returns nil for empty or invalid.
    static func parse(_ raw: String?) -> ParsedKeybinding? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        let parts = raw.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let keyPart = parts.last, !keyPart.isEmpty else { return nil }

        var mods: UInt32 = 0
        for part in parts.dropLast() {
            mods |= CarbonMod.parse(part)
        }

        guard let keyCode = keyNameMap[keyPart] else { return nil }
        return ParsedKeybinding(modifiers: mods, keyCode: keyCode)
    }
}

// ============================================================
// MARK: - Config Model
// ============================================================

struct MintTabConfig {
    enum SwitchingLogic: String { case app, window }
    enum UIStyle: String { case icons, list }
    enum UISize: String { case small, medium, large }
    enum SwitchMod: String { case alt, cmd, ctrl }

    let switchingLogic: SwitchingLogic
    let uiStyle: UIStyle
    let uiSize: UISize
    let blur: Bool
    let mouse: Bool
    let mouseSwitch: Bool
    let showHidden: Bool
    let showWindowless: Bool
    let assignSwitch: Bool
    let autoGroup: Bool
    let showAllCrossGroup: Bool
    let switchGroupFocus: Bool
    let groupHideOthers: Bool
    let switchMod: SwitchMod
    let menuBar: Bool
    let menuBarIconFormat: String
    let showAllKey: ParsedKeybinding
    let groupNames: [String]  // [0] = group 1, ..., [8] = group 9
    let groupSwitchKeys: [ParsedKeybinding?]  // [0] = group 1, ..., [8] = group 9
    let groupAssignKeys: [ParsedKeybinding?]  // same indexing
    let nextGroupKey: ParsedKeybinding?
    let prevGroupKey: ParsedKeybinding?

    static let `default` = MintTabConfig(
        switchingLogic: .app,
        uiStyle: .icons,
        uiSize: .medium,
        blur: true,
        mouse: true,
        mouseSwitch: true,
        showHidden: false,
        showWindowless: false,
        assignSwitch: false,
        autoGroup: true,
        showAllCrossGroup: true,
        switchGroupFocus: false,
        groupHideOthers: false,
        switchMod: .alt,
        menuBar: true,
        menuBarIconFormat: "{index}",
        showAllKey: ParsedKeybinding(modifiers: CarbonMod.option, keyCode: KeyCode.grave),
        groupNames: (1...9).map { "Group \($0)" },
        groupSwitchKeys: Array(repeating: nil, count: 9),
        groupAssignKeys: Array(repeating: nil, count: 9),
        nextGroupKey: nil,
        prevGroupKey: nil
    )

    /// Convert SwitchMod to Carbon modifier flags.
    var switchCarbonMod: UInt32 {
        switch switchMod {
        case .alt: return CarbonMod.option
        case .cmd: return CarbonMod.command
        case .ctrl: return CarbonMod.control
        }
    }

    /// Trigger modifier flag for event tap (the modifier that keeps panel open).
    var triggerModifierFlag: NSEvent.ModifierFlags {
        CarbonMod.nsEventFlag(from: switchCarbonMod)
    }
}

// ============================================================
// MARK: - Config Parser (Ghostty-style flat key=value)
// ============================================================

enum ConfigParser {
    /// Parse Ghostty-style config: flat `key = value` lines, # comments.
    static func parse(_ content: String) -> [String: String] {
        var result: [String: String] = [:]

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = stripComment(line.trimmingCharacters(in: .whitespaces))
            if trimmed.isEmpty { continue }

            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }

            let key = trimmed[..<eqIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIndex)...]
                .trimmingCharacters(in: .whitespaces)

            if !key.isEmpty { result[key] = value }
        }

        return result
    }

    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        for (i, ch) in line.enumerated() {
            if ch == "\"" { inQuotes.toggle() }
            else if ch == "#" && !inQuotes {
                return String(line[..<line.index(line.startIndex, offsetBy: i)])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return line
    }
}

// ============================================================
// MARK: - Config Loader
// ============================================================

enum ConfigLoader {
    static func load() -> MintTabConfig {
        let configDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/minttab")
        let configFile = configDir.appendingPathComponent("config")

        guard let content = try? String(contentsOf: configFile, encoding: .utf8) else {
            writeDefaultConfig(at: configFile, directory: configDir)
            return .default
        }

        let kv = ConfigParser.parse(content)
        let d = MintTabConfig.default

        let switchingLogic = MintTabConfig.SwitchingLogic(
            rawValue: kv["switching"] ?? "") ?? d.switchingLogic
        let uiStyle = MintTabConfig.UIStyle(
            rawValue: kv["ui-style"] ?? "") ?? d.uiStyle
        let uiSize = MintTabConfig.UISize(
            rawValue: kv["ui-size"] ?? "") ?? d.uiSize
        let blur = kv["blur"] != "false"  // default true
        let mouse = kv["mouse"] != "false"
        let mouseSwitch = kv["mouse-switch"] != "false"
        let showHidden = kv["show-hidden"] == "true"
        let showWindowless = kv["show-windowless"] == "true"
        let assignSwitch = kv["assign-switch"] == "true"
        let autoGroup = kv["auto-group"] != "false"
        let showAllCrossGroup = kv["show-all-cross-group"] != "false"
        let switchGroupFocus = kv["switch-group-focus"] == "true"
        let groupHideOthers = kv["group-hide-others"] == "true"
        let switchMod = MintTabConfig.SwitchMod(
            rawValue: kv["switch-mod"] ?? "") ?? d.switchMod
        let menuBar = kv["menu-bar"] != "false"
        let menuBarIconFormat = kv["menu-bar-icon-format"] ?? d.menuBarIconFormat
        let showAllKey = KeybindingParser.parse(kv["show-all"]) ?? d.showAllKey

        // Group names: group-name-1 through group-name-9
        var groupNames: [String] = (1...9).map { "Group \($0)" }
        for i in 1...9 {
            if let name = kv["group-name-\(i)"] {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { groupNames[i - 1] = trimmed }
            }
        }

        // Group switch keys: group-switch-1 through group-switch-9
        var groupSwitchKeys: [ParsedKeybinding?] = Array(repeating: nil, count: 9)
        for i in 1...9 {
            groupSwitchKeys[i - 1] = KeybindingParser.parse(kv["group-switch-\(i)"])
        }

        // Group assign keys: group-assign-1 through group-assign-9
        var groupAssignKeys: [ParsedKeybinding?] = Array(repeating: nil, count: 9)
        for i in 1...9 {
            groupAssignKeys[i - 1] = KeybindingParser.parse(kv["group-assign-\(i)"])
        }

        let nextGroupKey = KeybindingParser.parse(kv["next-group"])
        let prevGroupKey = KeybindingParser.parse(kv["prev-group"])

        return MintTabConfig(
            switchingLogic: switchingLogic,
            uiStyle: uiStyle,
            uiSize: uiSize,
            blur: blur,
            mouse: mouse,
            mouseSwitch: mouseSwitch,
            showHidden: showHidden,
            showWindowless: showWindowless,
            assignSwitch: assignSwitch,
            autoGroup: autoGroup,
            showAllCrossGroup: showAllCrossGroup,
            switchGroupFocus: switchGroupFocus,
            groupHideOthers: groupHideOthers,
            switchMod: switchMod,
            menuBar: menuBar,
            menuBarIconFormat: menuBarIconFormat,
            showAllKey: showAllKey,
            groupNames: groupNames,
            groupSwitchKeys: groupSwitchKeys,
            groupAssignKeys: groupAssignKeys,
            nextGroupKey: nextGroupKey,
            prevGroupKey: prevGroupKey
        )
    }

    private static func writeDefaultConfig(at url: URL, directory dir: URL) {
        let defaultContent = """
            # MintTab configuration (~/.config/minttab/config)

            # Switching mode: app (by application) or window (by window)
            switching = app

            # UI style: icons (icons only) or list (icon + window title)
            ui-style = icons

            # UI size: small, medium, or large
            ui-size = medium

            # Blur background: true or false
            blur = true

            # Mouse: enable mouse selection and hover
            mouse = true

            # Mouse switch: release shortcut switches to hovered window
            mouse-switch = true

            # Show Cmd+H hidden apps
            show-hidden = false

            # Show apps with no windows
            show-windowless = false

            # Switch to group after assign hotkey
            assign-switch = false

            # Auto-switch to frontmost app's group on open
            auto-group = true

            # show-all: allow Tab/Left/Right to cross group boundaries
            show-all-cross-group = true

            # Focus first window when switching groups
            switch-group-focus = false

            # Custom group names (1-9)
            group-name-1 = Group 1
            group-name-2 = Group 2
            group-name-3 = Group 3
            group-name-4 = Group 4
            group-name-5 = Group 5
            group-name-6 = Group 6
            group-name-7 = Group 7
            group-name-8 = Group 8
            group-name-9 = Group 9

            # Show menu bar icon with group indicator
            menu-bar = true

            # Menu bar icon format: {index} = group number, {name} = group name
            menu-bar-icon-format = {index}

            # Switch modifier: alt, cmd, or ctrl (key is always Tab)
            switch-mod = alt

            # Show all windows (no group filter)
            show-all = alt+`

            # Hide apps from other groups when switching groups
            # group-hide-others = true

            # Group switch hotkeys (one per group, unbound by default)
            # group-switch-1 = ctrl+1
            # group-switch-2 = ctrl+2
            # group-switch-3 = ctrl+3
            # group-switch-4 = ctrl+4
            # group-switch-5 = ctrl+5
            # group-switch-6 = ctrl+6
            # group-switch-7 = ctrl+7
            # group-switch-8 = ctrl+8
            # group-switch-9 = ctrl+9

            # Group assign hotkeys (one per group, unbound by default)
            # group-assign-1 = ctrl+shift+1
            # group-assign-2 = ctrl+shift+2
            # group-assign-3 = ctrl+shift+3
            # group-assign-4 = ctrl+shift+4
            # group-assign-5 = ctrl+shift+5
            # group-assign-6 = ctrl+shift+6
            # group-assign-7 = ctrl+shift+7
            # group-assign-8 = ctrl+shift+8
            # group-assign-9 = ctrl+shift+9

            # Next/previous group hotkeys (unbound by default)
            # next-group = ctrl+right
            # prev-group = ctrl+left
            """
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? defaultContent.write(to: url, atomically: true, encoding: .utf8)
    }
}

// ============================================================
// MARK: - AppEntry Extension
// ============================================================

extension AppEntry {
    var displayTitle: String {
        if let title = windows.first?.title, !title.isEmpty {
            return title
        }
        return appName
    }
}
