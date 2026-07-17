# Ask Codex to Install the App

This app is designed to be installed from source. Clone or download the repository from GitHub, then ask Codex to build and configure it for your Mac. The project does not assume that a prebuilt binary is available.

## Requirements

- macOS 14 or later
- Xcode
- Codex CLI with an active login
- An Apple Development Team that can be selected in Xcode

The Codex CLI may be installed in different locations on different Macs. The app searches the current `PATH`, common Homebrew and npm locations, nvm, mise, asdf, and Volta. You can also provide an explicit path with the `CODEX_EXECUTABLE` environment variable.

## Prompt for Codex

Open this repository in Codex and send the following prompt:

```text
Read README.md and INSTALL_WITH_CODEX.md, then build and configure Codex Rate Widget so that it is ready to use on this Mac.

1. First, check the current Xcode, Codex CLI, and Apple Development Team configuration.
2. Ask me for a unique reverse-DNS Bundle Identifier that I control. Do not sign the repository's com.example placeholder as my app.
3. Run Scripts/configure-local-signing.sh with that Bundle Identifier and, if known, my Team ID. The script must leave the tracked Xcode project and source files unchanged.
4. Run Scripts/verify.sh, which keeps its unsigned test products in isolated DerivedData. Then make the runnable signed artifact with a clean build; Config/Shared.xcconfig includes the ignored Config/Local.xcconfig automatically. Verify that the app ID is the requested value, the extension ID is the app ID plus .Widget, and both targets resolve $(TeamIdentifierPrefix) plus the app ID as their identical App Group.
5. The repository must keep CODEX_RATE_WIDGET_DEVELOPMENT_TEAM empty in Config/Shared.xcconfig; never copy my personal Team ID from the ignored local configuration into a tracked file.
6. After tests succeed, launch exactly one instance of the locally configured app.
7. Verify that the app retrieves the official usage limits, daily token usage, and cumulative token usage.
8. Verify that CodexRateWidget returns to an idle state after refreshing, with no sustained high CPU usage or duplicate processes.
9. Finally, explain how to add the widget and enable Launch at Login.

Always ask for my permission before updating globally installed npm packages, terminating processes, or changing my personal signing configuration.
Do not commit changes or push anything to GitHub unless I explicitly ask you to do so.
```

## Local Identifier Configuration

[Apple requires a unique Bundle Identifier for each app](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution). The checked-in `com.example.*` value is an unsigned placeholder. Choose a reverse-DNS namespace you control, then generate a machine-local configuration:

```sh
Scripts/configure-local-signing.sh \
  --bundle-id com.yourname.CodexRateWidget \
  --team-id "YOUR_TEAM_ID"
```

Omit `--team-id` if the Team ID is not yet known, then rerun the helper after finding it. The helper writes only the ignored `Config/Local.xcconfig`. It does not edit `project.pbxproj`, `Config/Shared.xcconfig`, Info.plists, entitlements, or Swift files, and it does not contact Apple.

The tracked `Config/Shared.xcconfig` includes the local file automatically and derives target-specific settings:

- `com.yourname.CodexRateWidget` for the app
- `com.yourname.CodexRateWidget.Widget` for the WidgetKit extension
- `com.yourname.CodexRateWidget.Tests` for tests
- `$(TeamIdentifierPrefix)com.yourname.CodexRateWidget` for both App Group entitlements and both `CodexRateWidgetAppGroup` Info.plist values

`$(TeamIdentifierPrefix)` is resolved by signing. Do not replace it with a hardcoded Team ID or with `$(AppIdentifierPrefix)`: Apple validates this non-provisioned macOS form against the team that signed the process. [Apple supports this `<team identifier>.<group name>` App Group form on macOS without separate registration](https://developer.apple.com/documentation/xcode/accessing-app-group-containers); the app and extension must still resolve exactly the same value.

Run the repository checks and unit tests in their isolated build directory:

```sh
Scripts/verify.sh
```

Then create the signed runnable artifact from a clean standard build directory. Cleaning matters because an incremental app build can otherwise retain a unit-test bundle produced by an earlier test action:

```sh
xcodebuild clean build \
  -project CodexRateWidget.xcodeproj \
  -scheme CodexRateWidget \
  -configuration Debug \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates
```

The same local configuration is applied when using Xcode's Run button. If tests were run from Xcode, use Product > Clean Build Folder before the final Run.

Do not select a Team by editing tracked project settings. If a Team ID changes, rerun the helper so both targets continue to inherit the same ignored local value. You can inspect the resolved build settings with `xcodebuild -showBuildSettings` before allowing Xcode to register identifiers with Apple.

## Verification Checklist for Codex

- `codex --version` succeeds
- The signed build does not use the `com.example.*` placeholder Bundle Identifiers
- The widget extension Bundle Identifier is the app Bundle Identifier plus `.Widget`
- `CodexRateWidget` and `CodexRateWidgetExtension` use the same App Group
- No personal Team ID, signing certificate, private key, or provisioning profile is staged for commit
- `xcodebuild test` succeeds
- The final clean app contains the widget extension but no `.xctest` plug-in
- Exactly one `CodexRateWidget` process is running
- CPU usage returns to idle after data retrieval finishes
- The App Group's `usage-snapshot-v1.json` contains an updated timestamp
- The large widget clearly distinguishes official figures from unofficial local estimates

## Troubleshooting

### `env: node: No such file or directory` / exit code 127

Check that the app can detect the Node executable installed alongside Codex CLI. For a nonstandard installation, set `CODEX_EXECUTABLE` at runtime to the absolute path of the Codex CLI executable.

### Multiple icons appear in the menu bar

Before launching the app, run `pgrep -x CodexRateWidget` to find only exact process-name matches. Identify the relevant PID explicitly, then make sure only one instance is launched.

### The widget remains visible after quitting the app

This is expected. macOS manages the WidgetKit extension, which continues to display the saved snapshot. The main app must run periodically to retrieve fresh usage data.

For the exact local data and Codex CLI communication boundaries, see [PRIVACY.md](./PRIVACY.md).
