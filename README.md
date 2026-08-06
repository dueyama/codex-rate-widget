# Codex Rate Widget

Codex Rate Widget is a SwiftUI and WidgetKit app that displays your currently available Codex usage allowance in macOS desktop widgets and the menu bar.

![Codex Rate Widget app icon](./CodexRateWidget/App/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

## Requirements

- macOS 14 or later
- A recent Xcode release with Swift 6 support
- Codex CLI with an active login
- An Apple Development Team for a signed local build

## What It Shows

- Small: the remaining capacity of the primary active usage window
- Medium: the remaining capacity of the five-hour and weekly usage windows, plus the official weekly reset date and time remaining
- Large: the remaining capacity, official weekly reset schedule, official cumulative and daily token usage for the past seven days, and local estimated token usage by project on this Mac

The app does not assume that a five-hour window always exists. If Codex does not return a window with `windowDurationMins = 300`, the app shows it as currently unavailable. If the window is restored in a future response, the ring appears again automatically.

## Data Sources

- Remaining capacity: the installed Codex CLI app server's `account/rateLimits/read` method
- Daily token usage: `account/usage/read`
- Official token usage: cumulative totals and daily buckets returned by Codex's `account/usage/read` method
- Per-project usage: a read-only aggregation of top-level local sessions in `$CODEX_HOME/state_5.sqlite`, or `~/.codex/state_5.sqlite` when `CODEX_HOME` is unset, that were updated during the seven-day period including today, grouped by `cwd`; this can include user sessions, automations, and legacy rows with an unknown source. The app uses those proportions to estimate how the official seven-day token total is distributed among projects. Subagents are excluded to avoid counting inherited parent context twice.

The per-project figures are estimates that distribute the official seven-day total according to locally observed proportions. A thread's `tokens_used` value is cumulative, so the app uses it only to calculate the proportions between projects; the displayed total comes from Codex's official aggregate. If that official total is unavailable or zero, the app does not display raw local counters as project usage. Cloud runs and activity on other Macs cannot be attributed to a local project, so this is not an exact breakdown.

The app sends no local project-attribution data or analytics. It launches the locally installed Codex CLI, which may contact Codex services to retrieve account usage as part of its normal operation. See [PRIVACY.md](./PRIVACY.md) for the precise data and storage boundaries.

## Build and Install

The recommended approach is to ask Codex to set up the app. Open this repository in Codex and ask it to follow [INSTALL_WITH_CODEX.md](./INSTALL_WITH_CODEX.md).

Because [Apple bundle identifiers must be unique](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution), replace the repository's unsigned `com.example.*` placeholder before making a signed build. Generate an ignored local configuration with a reverse-DNS identifier that you control:

```sh
Scripts/configure-local-signing.sh \
  --bundle-id com.yourname.CodexRateWidget \
  --team-id "YOUR_TEAM_ID"
```

The helper does not edit the Xcode project or tracked files. It writes only `Config/Local.xcconfig`, which is gitignored and included automatically by the tracked `Config/Shared.xcconfig`. The shared build settings derive every related identifier from that one local value:

- App: `com.yourname.CodexRateWidget`
- Widget extension: `com.yourname.CodexRateWidget.Widget`
- App Group: `$(TeamIdentifierPrefix)com.yourname.CodexRateWidget` in both targets

The Team ID is optional in the helper. If supplied, it is written only to the ignored local configuration. `$(TeamIdentifierPrefix)` is resolved from the signing team so the non-provisioned macOS App Group has the required `<Developer team identifier>.<group name>` form. Xcode and `xcodebuild` apply the local configuration automatically, with no extra command-line option.

The menu app and every widget size show the same compact version label, such as `v1.0.2`. The visible version and internal monotonically increasing build number both come from `Config/Shared.xcconfig`, so the app and embedded extension cannot drift when either value is updated.

To install it manually:

1. Find the Team ID for the Apple Development Team you intend to use.
2. Run `Scripts/configure-local-signing.sh` with a Bundle Identifier in your namespace and that Team ID.
3. Open [CodexRateWidget.xcodeproj](./CodexRateWidget.xcodeproj) in Xcode.
4. Run the `CodexRateWidget` scheme on My Mac. The app and widget automatically use the same local signing configuration.
5. Confirm the first successful refresh in the menu bar, then open Edit Widgets on the desktop and add the localized `Codex Remaining Capacity` widget.
6. To keep the data synchronized automatically, enable Launch at Login from the app's menu.

The app detects Codex CLI through the current `PATH`, common Homebrew and npm locations, nvm, mise, asdf, Volta, or the `CODEX_EXECUTABLE` environment variable. The app refreshes every 15 minutes, and the widget reads the snapshot stored in the App Group container.

The repository intentionally does not contain an Apple Development Team ID, certificate, private key, or provisioning profile. Keep personal values in `Config/Local.xcconfig`; do not copy them into `project.pbxproj`, `Config/Shared.xcconfig`, or another tracked file. The local file can be deleted and regenerated at any time.

## Localization

English is the development and fallback language. Japanese translations are used when the system language is Japanese; all other language settings use English.

## Resource Use

The app queries the Codex app server briefly every 15 minutes and then returns to idle. It does not scan project directories or load project contents. Per-project estimates come from a read-only SQL aggregation of `$CODEX_HOME/state_5.sqlite`, or `~/.codex/state_5.sqlite` when `CODEX_HOME` is unset.

## Privacy and Stability

The app reads a narrow set of local Codex thread metadata and invokes the locally installed Codex CLI. It does not scan project directories, upload project attribution, or include telemetry. The latest snapshot remains in the configured App Group container shared by the app and widget; it includes the local project paths used for display. The account methods and local database schema used here are Codex implementation interfaces and may change in future Codex CLI releases.

This is an independent, unofficial project and is not endorsed by or affiliated with OpenAI.

## Verification

Run the complete repository hygiene, localization, asset, build, and test checks with:

```sh
Scripts/verify.sh
```

The verification build uses an isolated DerivedData directory. Before launching or packaging a signed app after testing, use Xcode's Clean Build Folder command or run a signed `xcodebuild clean build`; this prevents a stale unit-test bundle from remaining inside the app.

Architecture and maintenance invariants are documented in [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) and [AGENTS.md](./AGENTS.md). Contributions must follow [CONTRIBUTING.md](./CONTRIBUTING.md), and security reports must follow [SECURITY.md](./SECURITY.md).

Before the first commit, run `Scripts/audit-public-tree.sh`. After commits exist, run `Scripts/audit-public-history.sh`; it scans every reachable commit and ref, including raw commit and tag metadata, while reporting only safe object and path labels, never the matched values. The complete source-only publication checklist is in [docs/PUBLISHING.md](./docs/PUBLISHING.md).

## License

Released under the [MIT License](./LICENSE).
