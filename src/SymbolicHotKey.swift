import AppKit

// ============================================================
// MARK: - SkyLight Symbolic Hotkey (Private API)
// ============================================================

/// Private SkyLight.framework function to enable/disable system-level hotkeys.
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ isEnabled: Bool) -> CGError

/// Disable or re-enable the native system handling for Cmd+Tab and Cmd+Shift+Tab.
func setNativeCommandTabEnabled(_ enabled: Bool) {
    CGSSetSymbolicHotKeyEnabled(1, enabled)  // Cmd+Tab
    CGSSetSymbolicHotKeyEnabled(2, enabled)  // Cmd+Shift+Tab
}
