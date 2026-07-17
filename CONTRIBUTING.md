# Contributing

Thank you for improving Codex Rate Widget. Keep changes focused, testable, and safe for source distribution.

## Development Setup

1. Read [README.md](./README.md), [AGENTS.md](./AGENTS.md), and [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md).
2. Keep the tracked `Config/Shared.xcconfig` on the public `com.example` Bundle Identifier and an empty development Team.
3. Put any personal Bundle Identifier and Team ID in ignored `Config/Local.xcconfig` by running `Scripts/configure-local-signing.sh`.
4. Run `Scripts/verify.sh` before submitting a change.

Unit tests do not access a live Codex account. The live integration test runs only when `RUN_LIVE_CODEX_TEST=1` is explicitly supplied.

## Design Rules

- Treat Codex `account/*` methods and the local SQLite schema as unstable implementation interfaces. Decode defensively and preserve partial functionality.
- Label account totals and limits as official only when they came from Codex account methods. Project attribution is always a local estimate.
- Do not scan project directories. Read only the minimal local thread metadata needed for aggregation.
- Keep process and account work in the host app. The widget extension only reads a saved snapshot.
- Keep Swift source strings in English and add Japanese translations to `Localizable.xcstrings` for user-visible changes.
- Preserve the shared App Group derivation and process-lifecycle invariants described in `AGENTS.md`.

## Privacy and Public Hygiene

Never commit Apple signing material, credentials, private paths, local databases, snapshots, Xcode user state, or build products. Before opening a pull request, run:

```sh
Scripts/audit-public-tree.sh
Scripts/verify.sh
```

Use a GitHub-provided no-reply email for commit and annotated-tag identities. The public-history audit intentionally rejects other email domains to prevent accidental disclosure in immutable Git metadata.

Sanitize screenshots and diagnostics so they contain no account usage, real project names, local paths, machine identifiers, or credentials. See [PRIVACY.md](./PRIVACY.md) and [SECURITY.md](./SECURITY.md).
