# Architecture

## Overview

Codex Rate Widget has two executables that share a small JSON snapshot through an App Group. `CODEX_HOME` overrides the default `~/.codex` state location when it is set.

```text
Codex CLI app-server
        |
        | official account data
        |
Host menu-bar app
        |
UsageSnapshot + bounded history
        |
   App Group files
        |
WidgetKit extension
```

Project directories and the local Codex thread database are outside this data path.

## Components

| Component | Responsibility | Lifetime |
| --- | --- | --- |
| `UsageController` | Initial refresh, 15-minute scheduling, persistence, timeline reload | Host lifetime |
| `CodexRateLimitClient` | Find Codex CLI, request account data, stop the child process | One request at a time |
| `SharedUsageStore` | Atomically save/load one Codable snapshot | Short file access |
| `SharedRemainingUsageHistoryStore` | Atomically save/load at most seven days of 15-minute remaining-capacity samples | Short file access |
| `DisplayLanguagePreferences` | Share the system/English/Japanese display choice through App Group preferences | On app and widget rendering |
| Widget extension | Render saved data for three widget sizes and handle chart-selection App Intents | Managed by macOS |

## Data provenance

### Official

- Remaining percentages and reset times: `account/rateLimits/read`
- Daily token buckets and lifetime token total: `account/usage/read`

These values may be shown as official account data because they are returned directly by Codex.

### Locally recorded official observations

Codex returns the current remaining percentage but does not return a historical remaining-capacity series. After each successful refresh, the host records the current official five-hour and weekly values in a 15-minute bucket. The large widget can display those local observations over 24 hours or seven days.

This chart must be labeled as recorded on this Mac. It must not imply that Codex supplied a historical series, interpolate periods when the app was not recording, or invent a five-hour value while that window is absent. An observed increase at a reset remains visible in the recorded series.

### Derived weekly pace guidance

The weekly pace guide is calculated locally from the official weekly reset timestamp and the known 10,080-minute window. The app and large widget show the same past seven-day time domain and repeat the current reset cadence backward as separate straight segments from 100% at each inferred cycle start to 0% at reset. Keeping the segments separate avoids drawing a false dotted connection from 0% to 100% across a reset. The app and widget enter their warning presentation when the current official remaining percentage is at least 10 percentage points below the current-cycle line.

The guide and warning are advisory UI derived from official current values; they are not an account limit, forecast, or historical series returned by Codex. If the weekly window or a valid current reset cycle is unavailable, no pace assessment or warning is shown.

## Process lifecycle

Each refresh launches `codex app-server --stdio`, sends initialize and two account requests, and terminates the process after a result, failure, or 45-second timeout. Both stdout and stderr use `FileHandle.readabilityHandler`.

EOF handlers must be set to `nil` immediately. They must also be cleared in the shared finish path, along with the process termination handler and stdin. This prevents callback retain cycles and an EOF monitoring loop that can otherwise consume two CPU cores indefinitely.

Stdout, stderr, timeout, and process termination can arrive concurrently. `RequestState` keeps all mutable request data in one lock-protected storage value, and `finish` atomically grants one caller the right to clean up and resume the continuation.

## CLI discovery

Discovery checks, in order:

1. `CODEX_EXECUTABLE`
2. The host process `PATH`
3. Homebrew and common npm locations
4. Volta, asdf, mise, and nvm locations

The selected executable's directory is prepended to the child `PATH`, allowing a Node-based launcher to find the matching `node` executable after a GUI or login launch.

## Signing and App Group

`Config/Shared.xcconfig` contains public defaults and optionally includes the ignored `Config/Local.xcconfig`. The local file supplies one `CODEX_RATE_WIDGET_BUNDLE_ID` and one `CODEX_RATE_WIDGET_DEVELOPMENT_TEAM`; target bundle IDs and the shared App Group derive from those values.

The tracked repository stores no Team ID. Xcode expands `$(TeamIdentifierPrefix)$(CODEX_RATE_WIDGET_BUNDLE_ID)` using the local signing identity. This produces Apple's non-provisioned macOS `<Developer team identifier>.<group name>` form. The expanded identifier is present in:

- Both entitlements files
- Both built Info.plist files under `CodexRateWidgetAppGroup`
- The runtime `WidgetConstants.appGroup` value

Never replace this with a committed personal Team ID or with `AppIdentifierPrefix`; older accounts can have an App ID prefix that differs from the signing Team ID macOS validates for this group form.

## Test isolation

The app executable is also the unit-test host. `AppRuntime` detects the XCTest environment and suppresses the automatic refresh loop, so normal tests never launch Codex or access an account. The explicit live test remains disabled unless `RUN_LIVE_CODEX_TEST=1` is set.

## Version identity

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are defined once in `Config/Shared.xcconfig`. Both the app and widget Info.plists expand those values, and `BuildVersionInfo` reads the currently executing bundle to render the compact label. The version is not stored in the usage snapshot: a cached older extension therefore reports its own version instead of the host app's newer version.

## Local persistence

`SharedUsageStore` atomically overwrites one latest JSON snapshot in the App Group container and mirrors it in App Group preferences for compatibility with an older cached extension. It is never sent directly by the app.

`SharedRemainingUsageHistoryStore` uses a separate atomically rewritten JSON file. It replaces repeated observations in the same 15-minute bucket and removes samples older than seven days, keeping storage and rendering cost bounded. Chart selection, time range, display language, and the latest error message use App Group preferences. None of these files are sent by the app.

## Localization

English source strings are the fallback. `Localizable.xcstrings` supplies Japanese translations. The menu app stores System Default, English, or Japanese in App Group preferences and asks WidgetKit to reload after a change. Both executables inject the selected `Locale` into their SwiftUI view trees; strings created outside `Text`, dates, durations, and compact token values receive that locale explicitly. Swift code should not introduce Japanese UI text directly, except the locale-specific Japanese compact-number units used by `tokenCountLabel`.

## Performance expectations

- Host and extension memory should remain in the tens of megabytes, not scale with project size.
- The host should return to idle after each refresh.
- The child app-server should not remain after the refresh completes.
- The snapshot and bounded seven-day history should remain small enough for trivial atomic file reads.

## Failure behavior

- Missing five-hour window: show it as unavailable; do not invent a limit.
- Missing or insufficient local history: preserve the official daily-token view and explain that recording starts after an app refresh.
- Recording gaps and missing windows: split the remaining-capacity line rather than interpolate across them.
- Daily usage unavailable: retain remaining-capacity functionality.
- Missing Codex CLI: show a localized actionable error.
- Invalid App Group: show a localized signing/configuration error.
- Schema or protocol change: fail without modifying the local Codex database.
