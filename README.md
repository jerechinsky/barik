# Barik

A lightweight macOS menu bar replacement for use with [yabai](https://github.com/koekeishiya/yabai) or [AeroSpace](https://github.com/nikitabobko/AeroSpace).

> **Note:** This is a personal fork of [mocki-toki/barik](https://github.com/mocki-toki/barik) tailored to my needs. Not accepting contributions. No promises of support or maintenance.

## Features

### Widgets

| Widget | Description |
|--------|-------------|
| `default.system` | Apple logo, Option-click toggles Do Not Disturb |
| `default.spaces` | Current spaces with individual window icons |
| `default.caffeinate` | Toggle sleep prevention (allows display sleep) |
| `default.iterm` | iTerm2 session tracker with Claude Code integration |
| `default.nextmeeting` | Shows next calendar event with attendees/meeting links |
| `default.nowplaying` | Currently playing track with scrolling text |
| `default.audiooutput` | Audio output device selector |
| `default.tailscale` | Personal Tailscale home-subnet status and path overview |
| `default.network` | Event-driven network status indicator |
| `default.battery` | Battery level with percentage |
| `default.weather` | Current conditions, temperature, and six-hour popup forecast |
| `default.codexlimits` | Available Codex limit rings, nearest reset countdown, and percentages |
| `default.codexactivity` | Black dots for running Codex tasks and green dots for completed unread tasks; hidden at zero |
| `default.time` | Configurable clock with month and detailed agenda popups |
| `divider` | Visual separator |
| `spacer` | Flexible space |

### Improvements over upstream

- Event-driven updates via Darwin notifications
- Sleep/wake handling for background services
- Per-widget calendar configuration
- Light theme support with proper colors
- Refined typography matching macOS system style
- Drag-and-drop widget reordering, persisted to the config
- Right-click menu for toggling widgets and opening the config

## Configuration

Config file: `~/.barik-config.toml`

```toml
theme = "light" # system, light, dark

[widgets]
displayed = [
    "default.system",
    "divider",
    "default.spaces",
    "divider",
    "default.caffeinate",
    "spacer",
    "default.nextmeeting",
    "default.nowplaying",
    "default.audiooutput",
    "default.tailscale",
    "default.network",
    "default.weather",
    "default.codexlimits",
    "default.codexactivity",
    "default.battery",
    "divider",
    { "default.time" = { label = "PST", time-zone = "America/Los_Angeles", format = "hh:mm" } },
    { "default.time" = { label = "BRT", time-zone = "America/Sao_Paulo", format = "hh:mm" } },
    "divider",
    { "default.time" = { format = "E d, jjmm" } },
]

[widgets.default.spaces]
space.show-key = true
window.show-title = true
window.title.max-length = 50

[widgets.default.nextmeeting]
max-title-length = 25
only-meetings = true  # only events with attendees or meeting links

[widgets.default.battery]
show-percentage = true
warning-level = 30
critical-level = 10

[widgets.default.codexlimits]
refresh-interval-seconds = 15
diameter = 18
spacing = 8
show-percentage = true

[widgets.default.codexactivity]
refresh-interval-seconds = 2
stale-after-minutes = 30
dot-diameter = 7
dot-spacing = 4
color = "#000000"
unread-color = "#3D755D"

[widgets.default.time.popup]
view-variant = "dayView"

# Authenticate once in Terminal with:
# /Applications/Codex.app/Contents/Resources/codex login
# Then run one Codex task so ~/.codex/sessions contains a usage snapshot.

[experimental.background]
displayed = true
height = 35
blur = 2

[experimental.foreground]
height = 35
horizontal-padding = 16
spacing = 10
```

## Building

Requires Xcode. Open `Barik.xcodeproj` and build, or:

```sh
xcodebuild -scheme Barik -configuration Release build
```

## Credits

- [mocki-toki/barik](https://github.com/mocki-toki/barik) - Original project
- [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) by Marcel Dierkes - Inspiration for caffeinate widget IOKit implementation

## License

[MIT](LICENSE)
