# Barik

A lightweight macOS menu bar replacement for use with [yabai](https://github.com/koekeishiya/yabai) or [AeroSpace](https://github.com/nikitabobko/AeroSpace).

> **Note:** This is a personal fork of [mocki-toki/barik](https://github.com/mocki-toki/barik) tailored to my needs. Not accepting contributions. No promises of support or maintenance.

## Features

### Widgets

| Widget | Description |
|--------|-------------|
| `default.system` | Apple logo; Option-click toggles Do Not Disturb, Command-click turns on closed-lid Keep Awake mode |
| `default.spaces` | Current spaces with individual window icons |
| `default.caffeinate` | Keep Awake toggle; Option-click toggles the idle mouse jiggler |
| `default.iterm` | iTerm2 session tracker with Claude Code integration |
| `default.nextmeeting` | Shows next calendar event with attendees/meeting links |
| `default.nowplaying` | Currently playing track with scrolling text |
| `default.audiooutput` | Audio output device selector |
| `default.network` | Event-driven network status indicator |
| `default.battery` | Battery level with percentage |
| `default.weather` | Current conditions, temperature, and six-hour popup forecast |
| `default.codexlimits` | Codex weekly quota, daily pace budget, reset countdown, and selectable bar or pie style |
| `default.codexactivity` | All running chats, with recent completions filling up to three dots; expands for additional running chats |
| `default.time` | Configurable clock with month and detailed agenda popups |
| `divider` | Visual separator |
| `spacer` | Flexible space |

Keep Awake uses the system-wide `pmset disablesleep` switch so it also covers a
closed MacBook when an external display disconnects. The first state change asks
for administrator approval to install a persistent current-user rule limited to
the SHA-256-pinned `pmset disablesleep 0` and `1` commands. Later toggles do not
prompt. Removing Barik does not remove that rule from `/private/etc/sudoers.d`.

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
style = "bar" # "bar", "pie", or "pie-number"
bar-width = 64
bar-height = 8
pie-diameter = 21 # compact pie, aligned to the two-line quota label height
diameter = 21 # legacy large pie used by "pie-number"
today-color = "#35E875"
spacing = 8
show-percentage = true

[widgets.default.codexactivity]
refresh-interval-seconds = 2
stale-after-minutes = 480 # Before 10:00, extends back to 17:00 the previous day
show-read-completed = false
dot-diameter = 8
dot-spacing = 4
# All running chats are shown; recent completions fill up to three total dots.
color = "#E59B3A"
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

### Mouse jiggler

Option-click the coffee cup to toggle the mouse jiggler. A mouse icon appears next to the cup while enabled. After 30 seconds without input, it moves the pointer one point and back; it skips dragging, held modifiers, and locked sessions. Option-click again to stop just the jiggler, or click normally to turn off Keep Awake and the jiggler together. The jiggler starts off after every Barik restart.

macOS may ask for Accessibility permission on first use. Allow Barik in System Settings > Privacy & Security > Accessibility, then Option-click again. Website session timeouts may still apply.

For an explicit local launch with the jiggler enabled, quit Barik and run `open /Applications/Barik.app --args --mouse-jiggler`. Normal launches still start with the jiggler off. The running app reports its PID, permission state, and observed nudge count in `~/Library/Application Support/Barik/jiggler-status.json`; check the PID and timestamp before relying on that file.

The Codex daily allowance uses the server's full weekly window (100% over seven
24-hour days), reserving quota from the next local midnight until reset. Partial
days are prorated and the reserve is rounded up. Savings carry forward; a negative
`today` percentage means usage is ahead of that plan. The minus sits outside the
number's layout, so it does not shift the digits. Resets before 06:00 belong to the
preceding evening. The countdown includes remaining hours and the popup shows the
exact local reset date, time, and timezone.
