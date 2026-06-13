# MintTab

A macOS window management tool, vibe coding project, for personal use. Inspired by [alt-tab](https://github.com/lwouis/alt-tab-macos).

## Build

Requires [xmake](https://xmake.io/) and Xcode (or Xcode CLI tools).

```bash
xmake f --target_minver=13.0
xmake
```

## Install

```bash
brew install m1nts02/tap/minttab
```

Default config is generated at `~/.config/minttab/config` on first run.

Requires these permissions in System Settings → Privacy & Security:

- **Accessibility** — global hotkeys and window activation.
- **Input Monitoring** — detecting modifier release; if denied, MintTab falls back to polling.
- **Screen Recording** — reading window titles via `CGWindowList`; if denied, MintTab falls back to Accessibility API for titles.

### Run as a service

```bash
# Start (auto-launches on login)
brew services start m1nts02/tap/minttab

# Stop
brew services stop m1nts02/tap/minttab

# Restart
brew services restart m1nts02/tap/minttab
```

## Config

Config file: `~/.config/minttab/config`

See [config.example](config.example) for all available options. Copy it to `~/.config/minttab/config` and edit.

## Usage

### Basics

| Action | Default shortcut |
|--------|-----------------|
| Switch windows | `switch-mod` + Tab |
| Reverse switch | `switch-mod` + Shift + Tab |
| Show all (grouped view) | Alt + ` |
| Confirm selection | Enter |
| Cancel | Esc |

**Switcher navigation**

| Key | Action |
|-----|--------|
| ← → ↑ ↓ | Move selection |
| `switch-mod` + h / j / k / l | Move left / down / up / right (Vim) |

**Show-all navigation**

| Key | Action |
|-----|--------|
| ← → ↑ ↓ | Move selection |
| h / j / k / l | Move left / down / up / right (Vim) |

### Groups

| Action | Default shortcut |
|--------|-----------------|
| Switch to group 1-9 | Ctrl+1 ~ Ctrl+9 |
| Assign app to group 1-9 | Ctrl+Shift+1 ~ Ctrl+Shift+9 |
| Next group | Unbound by default |
| Previous group | Unbound by default |

### CLI

```bash
minttab switch-group 1     # Switch to group 1
minttab assign-group 3     # Assign current app to group 3
minttab show-all           # Show all windows
minttab show-panel         # Open switch panel
minttab reload             # Reload config from disk
```

## License

MIT
