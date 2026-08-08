# Repository guidance

## Purpose

Codex Rate Widget is a source-distributed macOS menu-bar app and WidgetKit extension. Keep changes small, testable, privacy-preserving, and safe to build with a developer's local Apple signing identity.

## Non-negotiable invariants

- Never commit an Apple Team ID, signing certificate, private key, provisioning profile, or `xcuserdata`.
- Public commits and annotated tags must use a GitHub-provided no-reply email; identity names and every ref name remain subject to the configured private-pattern audit.
- Keep `CODEX_RATE_WIDGET_DEVELOPMENT_TEAM` empty in tracked `Config/Shared.xcconfig`. Store a Team ID only in ignored `Config/Local.xcconfig` or pass a command-line override; never paste a literal ID into the project.
- Keep the main app and widget extension App Group identical. It is derived from `$(TeamIdentifierPrefix)$(CODEX_RATE_WIDGET_BUNDLE_ID)` and read at runtime from `CodexRateWidgetAppGroup` in each built Info.plist. Do not substitute `AppIdentifierPrefix`; macOS validates this group form against the signing Team ID.
- Official limits, daily buckets, and lifetime tokens come from Codex `account/*` methods. Never label locally derived project attribution as official.
- Project figures are estimates. The analyzer may read `~/.codex/state_5.sqlite` read-only, but it must not scan or load project directories. Without a positive official seven-day total, it must return no project figures rather than expose cumulative local counters.
- The short-lived `codex app-server --stdio` process must be terminated after each refresh. Clear both `FileHandle.readabilityHandler` callbacks at EOF and on every finish path; leaving them installed causes sustained high CPU.
- Keep every mutable `RequestState` field behind its lock and allow exactly one finish path to resume the continuation.
- English is the development and fallback language. Japanese belongs in `Localizable.xcstrings`; all non-Japanese locales fall back to English.
- The widget extension only renders saved snapshots. Network/process work belongs in the host app.
- Unit tests must not start the live refresh loop. Live Codex account access is opt-in through `RUN_LIVE_CODEX_TEST=1`.
- Publish only Git-selected source files. Never upload or archive the working folder itself because ignored signing, Xcode user state, and build products can still exist locally.
- Do not commit, push, publish, update global packages, change personal signing, or terminate processes unless the user explicitly authorizes that action.

## Source map

- `CodexRateWidget/App/CodexRateLimitClient.swift`: CLI discovery, app-server RPC, process lifecycle.
- `CodexRateWidget/App/ProjectUsageAnalyzer.swift`: read-only local SQLite aggregation.
- `CodexRateWidget/App/UsageController.swift`: 15-minute refresh loop and WidgetKit reload.
- `CodexRateWidget/Shared/BuildVersionInfo.swift`: bundle version parsing and the shared compact label.
- `CodexRateWidget/Shared/DisplayLanguage.swift`: shared system/English/Japanese preference and explicit-locale string lookup.
- `CodexRateWidget/Shared/RemainingUsageHistory.swift`: bounded 15-minute remaining-capacity observations and chart segmentation.
- `CodexRateWidget/Shared/UsageSnapshot.swift`: shared models and App Group persistence.
- `CodexRateWidget/Shared/WidgetDisplayPreferences.swift`: App Group chart preferences and interactive widget App Intents.
- `CodexRateWidget/Widget/CodexUsageWidget.swift`: small, medium, and large widget UI.
- `CodexRateWidget/Shared/Localizable.xcstrings`: English source keys and Japanese translations.
- `Config/Shared.xcconfig`: public defaults, shared app/widget version, and the optional include for ignored local signing values.
- `Scripts/configure-local-signing.sh`: safe generator for `Config/Local.xcconfig`.
- `Scripts/audit-public-tree.sh`: current public-candidate filename and content audit.
- `Scripts/audit-public-history.sh`: all-reachable-commit audit without secret-value output.
- `Scripts/public-audit-common.sh`: shared public-audit path rules and pattern preparation.
- `Scripts/public-secret-patterns.txt`: generic public audit patterns; never add personal identifiers.
- `Scripts/test-public-audits.sh`: adversarial regression fixtures for fail-closed audit behavior.
- `docs/ARCHITECTURE.md`: data flow, trust boundaries, and failure modes.
- `docs/PUBLISHING.md`: sanitized initial-history and source-release checklist.

## Required workflow

1. Read `README.md`, this file, and the relevant source files before editing.
2. Inspect `git status --short`; preserve unrelated user changes.
3. Keep user-visible source strings in English and add/update Japanese translations.
4. Run `Scripts/verify.sh` after code, project, resource, signing, or localization changes.
5. Keep tests in the isolated `DerivedData/Verification` path used by `Scripts/verify.sh`. Before launching or packaging, use a signed `xcodebuild clean build` and confirm the app contains the widget extension but no stale `.xctest` plug-in.
6. For process-lifecycle changes, refresh once and verify that the host returns to approximately 0% CPU and that no child app-server remains.
7. Run `Scripts/audit-public-tree.sh` before staging a public commit. Inspect `git add -n .`, the complete staged file list, and the public Git author identity.
8. Before any public push, run `Scripts/audit-public-history.sh`. A clean working tree does not remove identifiers from earlier commits; the first public version must use a fresh sanitized history rather than restoring retired metadata containing signing identities.

## Unstable dependencies

The `account/rateLimits/read`, `account/usage/read`, `state_5.sqlite`, and `threads` schema are Codex implementation interfaces, not stable public APIs. Decode defensively, preserve partial functionality when detailed usage is unavailable, and document behavior changes.
