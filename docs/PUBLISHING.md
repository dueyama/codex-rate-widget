# Publishing Checklist

This project is intended for source distribution. The working folder can contain ignored personal signing settings, Xcode user state, and build products, so never upload the folder itself or publish a Finder-created archive. Publish only files selected by a fresh Git history.

## Recommended Repository Metadata

- **Name:** `codex-rate-widget`
- **Description:** `An unofficial macOS menu bar app and WidgetKit extension for Codex usage limits, official token totals, and local usage history.`
- **Topics:** `macos`, `swift`, `swiftui`, `widgetkit`, `codex`, `codex-cli`, `menu-bar`, `usage-monitor`
- **License:** MIT

`codex-rate-widget` matches the product name and leaves room for all three widget sizes plus the menu-bar app. If a more search-oriented name is preferred, use `codex-usage-widget-macos`; avoid a name that implies an official OpenAI product.

## Create the GitHub Repository

Create an empty repository in GitHub. Do not ask GitHub to add a README, `.gitignore`, or license because this source tree already contains them. Do not restore retired Git metadata: a clean source tree does not sanitize identifiers stored in old commits.

Before the first local commit:

1. Confirm whether the real name in `LICENSE` is the intended public copyright attribution.
2. Configure the repository-local Git author name and a GitHub-provided no-reply email. The history audit rejects other author, committer, and tagger email addresses so a personal address cannot be published accidentally.
3. Add any known machine-specific names, paths, or identifiers as one extended regular expression per line in ignored `.local/public-secret-patterns.txt`.
4. Run `Scripts/audit-public-tree.sh` and `Scripts/verify.sh`.
5. Initialize a new `main` history only after those checks pass.

Initialize the local history without importing any retired metadata, then inspect the repository-local author identity before staging:

```sh
git init -b main
git config --local user.name
git config --local user.email
```

If either identity is blank or not intended for public history, set an intentional public value before committing.

Review exactly what Git would publish before staging:

```sh
git add -n .
git status --short --ignored
```

Then stage intentionally and inspect every path:

```sh
git add .
Scripts/audit-public-tree.sh
git status --short
git diff --cached --check
git diff --cached --stat
git ls-files
```

The staged set must not include `Config/Local.xcconfig`, its temporary files, `DerivedData`, `xcuserdata`, `.xcuserstate`, `.DS_Store`, local databases, snapshots, logs, credentials, signing files, apps, test bundles, archives, or dSYMs.

After the first commit, run:

```sh
Scripts/audit-public-history.sh
git log --all --format='%h author=%an <%ae> committer=%cn <%ce> %s'
git for-each-ref refs/tags --format='%(refname:short) tagger=%(taggername) %(taggeremail)'
```

The history audit reports only commit, tag, ref, and file names, never the rejected value. It requires GitHub no-reply email addresses and scans identity names for configured private patterns. Review the remaining public author, committer, and tagger names separately. Verify the committed source once more from a separate clean clone that has no `Config/Local.xcconfig` or prior DerivedData.

Add the GitHub remote and push only after the repository owner explicitly authorizes publication.

## GitHub Settings

Before announcing the repository:

- enable secret scanning and push protection where available;
- enable private vulnerability reporting;
- keep default Actions workflow permissions read-only;
- require the `CI` workflow on protected branches; and
- keep Dependabot updates enabled for GitHub Actions.

Add repository-specific CI and license badges only after the final owner and repository URL are known.

## Source Release Checklist

1. Move the `CHANGELOG.md` entries from Unreleased to the release version and date.
2. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` together in `Config/Shared.xcconfig`.
3. Run `Scripts/verify.sh` and `Scripts/audit-public-history.sh`.
4. Make one signed `xcodebuild clean build` with ignored local signing settings.
5. Confirm the app and extension versions, Bundle Identifiers, matching App Group, valid signatures, embedded widget extension, and absence of `.xctest` plug-ins.
6. Perform one live refresh, then confirm the host returns to idle and no child `codex app-server` remains.
7. Reinspect the tag's file list, commit author identity, and history audit.

For the initial release, publish source only. Do not attach a locally signed development build. A distributable binary requires a deliberate Developer ID signing, hardened-runtime, notarization, and update strategy that is outside this source-only workflow.
