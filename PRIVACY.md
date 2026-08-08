# Privacy

Codex Rate Widget is a local, source-distributed macOS app. It contains no analytics, advertising, crash-reporting SDK, or update tracker.

## Data the App Reads

The host app launches the locally installed `codex app-server --stdio` process and requests:

- current account usage-limit windows;
- daily token buckets; and
- the lifetime token total, when available.

Codex CLI may contact Codex services using its existing login as part of these account requests. Codex Rate Widget does not inspect or persist the CLI's login files or credential values. The child process inherits the host app's environment, with `PATH` adjusted for CLI discovery, so any credentials already supplied to Codex through environment variables remain available to that child process.

For optional local project estimates, the app opens `$CODEX_HOME/state_5.sqlite` read-only, or `~/.codex/state_5.sqlite` when `CODEX_HOME` is unset, and aggregates only `cwd`, `updated_at`, `tokens_used`, and `thread_source` values from recent top-level thread rows. It does not enumerate project directories or read source files.

## Data the App Stores

The app overwrites one latest usage snapshot in the configured App Group container shared by the signed app and widget, and mirrors that snapshot in App Group preferences for compatibility with cached widget extensions. The snapshot contains:

- usage-limit percentages and reset times;
- official daily and lifetime token totals;
- locally estimated project totals and their original `cwd` paths; and
- the last successful update time.

The app also stores a separate bounded remaining-capacity history in the App Group container. After each successful refresh, it records the observation time and the available five-hour and weekly remaining percentages. Samples are grouped into 15-minute buckets and observations older than seven days are deleted. The history contains no project paths and is atomically rewritten rather than appended without limit.

The selected large-widget chart, remaining-history time scale, and display language are stored in App Group preferences. The latest error message is stored there as well.

Launch at Login is registered through macOS `SMAppService`; macOS owns that registration.

## Data the App Sends

Codex Rate Widget has no direct networking client and sends no telemetry, analytics, project paths, or project estimates. The child Codex CLI process may communicate with Codex services for the account methods described above. Local project-attribution data is not included in those requests by this app.

## Removing Local Data

Disable Launch at Login from the menu-bar app, quit it, remove the app, and remove its App Group container if you also want to delete the saved snapshot, remaining-capacity history, and widget preferences. The resolved App Group identifier is the signing Team identifier followed by the locally configured app Bundle Identifier; it is not the public `com.example` placeholder.

Do not attach `state_5.sqlite`, App Group snapshots, `Config/Local.xcconfig`, or unredacted logs to a public issue.
