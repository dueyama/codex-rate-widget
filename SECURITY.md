# Security Policy

## Supported Versions

Security fixes are made on the latest source version. Older source snapshots are not maintained separately.

## Reporting a Vulnerability

Use GitHub's private vulnerability-reporting flow under the repository's **Security** tab. Do not disclose a vulnerability in a public issue before a fix is available.

Do not include Apple signing identities, Team IDs, private keys, provisioning profiles, Codex credentials, `Config/Local.xcconfig`, App Group snapshots, or unredacted logs in a report. Reduce any diagnostic material to the smallest sanitized reproduction.

If private vulnerability reporting has not yet been enabled, contact the maintainer through a private channel listed on the maintainer's GitHub profile and include only a high-level description initially.

## Security Boundaries

- The public repository must retain an empty development Team and the `com.example.CodexRateWidget` Bundle Identifier placeholder.
- Personal signing values belong only in ignored `Config/Local.xcconfig`.
- The SQLite analyzer is read-only and must never inspect project directory contents.
- The widget renders saved snapshots; process and account access stays in the host app.
- `Scripts/audit-public-tree.sh` and `Scripts/audit-public-history.sh` must pass before publication.
