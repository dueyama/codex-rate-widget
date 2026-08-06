#!/bin/bash

set -euo pipefail
export LC_ALL=C
unset GREP_OPTIONS

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "error: $*" >&2
  exit 1
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-rate-widget-audit-tests.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
audit_email='public-audit@''users.noreply.github.com'
private_token='sk-''AAAAAAAAAAAAAAAAAAAAAAAA'
private_bundle='private.example.''CodexRateWidget'
private_absolute_path='/Users/''private/secret'
private_email='private@''example.test'
github_support_email='support@''github.com'
assertion_counter=0

new_fixture() {
  local name="$1"
  local fixture="$TEMP_DIR/$name"

  mkdir -p "$fixture/Scripts" "$fixture/Config"
  cp .gitignore "$fixture/.gitignore"
  cp Config/Shared.xcconfig "$fixture/Config/Shared.xcconfig"
  cp \
    Scripts/audit-public-tree.sh \
    Scripts/audit-public-history.sh \
    Scripts/public-audit-common.sh \
    Scripts/public-secret-patterns.txt \
    "$fixture/Scripts/"
  git -C "$fixture" init -q
  git -C "$fixture" add .
  git -C "$fixture" \
    -c user.name='Public Audit' \
    -c user.email="$audit_email" \
    commit -qm 'Clean fixture'
  printf '%s\n' "$fixture"
}

expect_success() {
  local label="$1"
  local fixture="$2"
  shift 2
  assertion_counter=$((assertion_counter + 1))
  if ! (cd "$fixture" && "$@") > "$TEMP_DIR/result-$assertion_counter.txt" 2>&1; then
    echo "Audit test unexpectedly failed: $label" >&2
    sed -n '1,80p' "$TEMP_DIR/result-$assertion_counter.txt" >&2
    exit 1
  fi
}

expect_failure() {
  local label="$1"
  local fixture="$2"
  shift 2
  assertion_counter=$((assertion_counter + 1))
  if (cd "$fixture" && "$@") > "$TEMP_DIR/result-$assertion_counter.txt" 2>&1; then
    fail "audit test unexpectedly passed: $label"
  fi
}

expect_failure_without_value() {
  local label="$1"
  local fixture="$2"
  local forbidden_value="$3"
  local result
  shift 3
  assertion_counter=$((assertion_counter + 1))
  result="$TEMP_DIR/result-$assertion_counter.txt"

  if (cd "$fixture" && "$@") > "$result" 2>&1; then
    fail "audit test unexpectedly passed: $label"
  fi
  if grep -aF "$forbidden_value" "$result" >/dev/null 2>&1; then
    fail "audit test exposed the matched value: $label"
  fi
}

fixture="$(new_fixture clean)"
expect_success "clean tree" "$fixture" Scripts/audit-public-tree.sh
expect_success "clean history" "$fixture" Scripts/audit-public-history.sh

fixture="$(new_fixture staged-mismatch)"
printf '%s\n' "$private_token" > "$fixture/staged.txt"
git -C "$fixture" add staged.txt
printf '%s\n' 'safe working-tree replacement' > "$fixture/staged.txt"
expect_failure_without_value \
  "staged content differs from the working tree" "$fixture" "$private_token" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture index-revspec-path)"
printf '%s\n' 'safe decoy' > "$fixture/decoy.txt"
printf '%s\n' "$private_token" > "$fixture/0:decoy.txt"
git -C "$fixture" add decoy.txt '0:decoy.txt'
printf '%s\n' 'safe working-tree replacement' > "$fixture/0:decoy.txt"
expect_failure_without_value \
  "staged path resembling a Git index revspec" "$fixture" "$private_token" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture alternate-index-environment)"
printf '%s\n' "$private_token" > "$fixture/environment-index.txt"
git -C "$fixture" add environment-index.txt
printf '%s\n' 'safe working-tree replacement' > "$fixture/environment-index.txt"
alternate_index="$fixture/.git/public-audit-alternate-index"
GIT_INDEX_FILE="$alternate_index" git -C "$fixture" read-tree HEAD
expect_failure_without_value \
  "alternate Git index environment" "$fixture" "$private_token" \
  env GIT_INDEX_FILE="$alternate_index" Scripts/audit-public-tree.sh

fixture="$(new_fixture grep-options-tree)"
printf '%s\n' "$private_token" > "$fixture/grep-options-tree.txt"
expect_failure_without_value \
  "GREP_OPTIONS cannot exclude a working-tree scan" "$fixture" "$private_token" \
  env GREP_OPTIONS='--exclude=content.bin' Scripts/audit-public-tree.sh

fixture="$(new_fixture binary-content)"
printf '\0%s\0' "$private_token" > "$fixture/binary.bin"
expect_failure_without_value \
  "binary working-tree content" "$fixture" "$private_token" \
  Scripts/audit-public-tree.sh
git -C "$fixture" add binary.bin
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit -qm 'Binary fixture'
expect_failure_without_value \
  "binary historical content" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture malformed-pattern)"
mkdir -p "$fixture/.local"
printf '%s\n' '([unterminated' > "$fixture/.local/public-secret-patterns.txt"
expect_failure_without_value \
  "malformed private pattern" "$fixture" '([unterminated' \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture additive-extra-pattern)"
mkdir -p "$fixture/.local"
printf '%s\n' 'privateuser' > "$fixture/.local/public-secret-patterns.txt"
printf '%s\n' '^safe-extra-pattern$' > "$fixture/.local/additional-patterns.txt"
printf '%s\n' 'safe content' > "$fixture/privateuser-notes.txt"
expect_failure_without_value \
  "an additional pattern file cannot replace repository-local privacy rules" "$fixture" 'privateuser' \
  env CODEX_RATE_WIDGET_AUDIT_EXTRA_PATTERNS="$fixture/.local/additional-patterns.txt" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture dangling-local-pattern)"
mkdir -p "$fixture/.local"
ln -s missing-patterns.txt "$fixture/.local/public-secret-patterns.txt"
printf '%s\n' 'safe content' > "$fixture/privateuser-notes.txt"
expect_failure \
  "a dangling repository-local pattern link cannot disable privacy rules" "$fixture" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture duplicate-bundle-setting)"
printf '%s\n' '  CODEX_RATE_WIDGET_BUNDLE_ID[sdk=macosx*][arch=arm64] = private.example.$(PRODUCT_NAME)' >> "$fixture/Config/Shared.xcconfig"
expect_failure \
  "duplicate public bundle identifier assignment" "$fixture" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture duplicate-team-setting)"
printf '%s\n' '  CODEX_RATE_WIDGET_DEVELOPMENT_TEAM[sdk=macosx*][arch=arm64] = $(PRIVATE_TEAM)' >> "$fixture/Config/Shared.xcconfig"
expect_failure \
  "duplicate public development Team assignment" "$fixture" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture staged-gitignore-policy)"
printf '%s\n' '.DS_Store' > "$fixture/.gitignore"
git -C "$fixture" add .gitignore
cp "$ROOT/.gitignore" "$fixture/.gitignore"
expect_failure \
  "staged public exclusions differ from the safe working tree" "$fixture" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture staged-shared-config-policy)"
printf '%s\n' 'CODEX_RATE_WIDGET_BUNDLE_ID = private.example.$(PRODUCT_NAME)' >> "$fixture/Config/Shared.xcconfig"
git -C "$fixture" add Config/Shared.xcconfig
cp "$ROOT/Config/Shared.xcconfig" "$fixture/Config/Shared.xcconfig"
expect_failure \
  "staged public signing defaults differ from the safe working tree" "$fixture" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture absolute-symlink)"
ln -s "$private_absolute_path" "$fixture/private-link"
expect_failure_without_value \
  "absolute symlink" "$fixture" "$private_absolute_path" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture pattern-source)"
printf '%s\n' "$private_token" >> "$fixture/Scripts/public-secret-patterns.txt"
git -C "$fixture" add Scripts/public-secret-patterns.txt
expect_failure_without_value \
  "private value in the public pattern source" "$fixture" "$private_token" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture commit-message)"
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit --allow-empty -qm "message fixture $private_token"
expect_failure_without_value \
  "private value in a commit message" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture github-support-trailer)"
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit --allow-empty -q \
    -m 'GitHub-maintained dependency fixture' \
    -m "Signed-off-by: dependabot[bot] <$github_support_email>"
expect_success \
  "public GitHub support mailbox in a commit trailer" "$fixture" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture private-email-trailer)"
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit --allow-empty -q \
    -m 'Private trailer fixture' \
    -m "Signed-off-by: Example <$private_email>"
expect_failure_without_value \
  "other email addresses in commit trailers remain private" "$fixture" "$private_email" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture github-support-author)"
GIT_AUTHOR_NAME='GitHub Support Fixture' \
GIT_AUTHOR_EMAIL="$github_support_email" \
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit --allow-empty -qm 'GitHub support author fixture'
expect_failure_without_value \
  "public GitHub support mailbox is not an allowed author identity" "$fixture" "$github_support_email" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture author-email)"
GIT_AUTHOR_NAME='Public Audit' \
GIT_AUTHOR_EMAIL="$private_email" \
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit --allow-empty -qm 'Author identity fixture'
expect_failure_without_value \
  "author email must use GitHub no-reply" "$fixture" "$private_email" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture committer-email)"
GIT_AUTHOR_NAME='Public Audit' \
GIT_AUTHOR_EMAIL="$audit_email" \
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$private_email" \
  commit --allow-empty -qm 'Committer identity fixture'
expect_failure_without_value \
  "committer email must use GitHub no-reply" "$fixture" "$private_email" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture raw-commit-header)"
raw_commit_oid="$(git -C "$fixture" cat-file commit HEAD | awk -v secret="$private_token" '
  BEGIN { inserted = 0 }
  !inserted && $0 == "" { print "x-private " secret; inserted = 1 }
  { print }
' | git -C "$fixture" hash-object -t commit -w --stdin)"
git -C "$fixture" update-ref refs/heads/raw-header "$raw_commit_oid"
expect_failure_without_value \
  "private value in a nonstandard raw commit header" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture raw-commit-noreply-like-header)"
noreply_wrapped_token="${private_token}@${audit_email#*@}"
raw_commit_oid="$(git -C "$fixture" cat-file commit HEAD | awk -v secret="$noreply_wrapped_token" '
  BEGIN { inserted = 0 }
  !inserted && $0 == "" { print "x-private " secret; inserted = 1 }
  { print }
' | git -C "$fixture" hash-object -t commit -w --stdin)"
git -C "$fixture" update-ref refs/heads/raw-noreply-header "$raw_commit_oid"
expect_failure_without_value \
  "a no-reply-like value in an unknown commit header is not normalized away" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture private-ref-name)"
git -C "$fixture" branch "leak-$private_email"
expect_failure_without_value \
  "private value in a ref name" "$fixture" "$private_email" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture noncommit-ref)"
blob_oid="$(printf '%s\n' "$private_token" | git -C "$fixture" hash-object -w --stdin)"
git -C "$fixture" update-ref refs/public/leak "$blob_oid"
expect_failure_without_value \
  "non-tag ref pointing directly to a blob" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture replaced-commit)"
printf '%s\n' "$private_token" > "$fixture/secret-history.txt"
git -C "$fixture" add secret-history.txt
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit -qm 'Secret history fixture'
secret_commit="$(git -C "$fixture" rev-parse HEAD)"
clean_commit="$(git -C "$fixture" rev-parse HEAD^)"
clean_tree="$(git -C "$fixture" rev-parse "$clean_commit^{tree}")"
safe_replacement="$(printf '%s\n' 'Safe replacement fixture' | git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit-tree "$clean_tree")"
git -C "$fixture" replace "$secret_commit" "$safe_replacement"
expect_failure_without_value \
  "replace refs cannot hide publishable commit content" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture grep-options-history)"
printf '%s\n' "$private_token" > "$fixture/grep-options-history.txt"
git -C "$fixture" add grep-options-history.txt
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit -qm 'Grep options history fixture'
expect_failure_without_value \
  "GREP_OPTIONS cannot exclude a historical scan" "$fixture" "$private_token" \
  env GREP_OPTIONS='--exclude=content.bin' Scripts/audit-public-history.sh

fixture="$(new_fixture grafted-history)"
printf '%s\n' "$private_token" > "$fixture/secret-ancestor.txt"
git -C "$fixture" add secret-ancestor.txt
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit -qm 'Secret ancestor fixture'
git -C "$fixture" rm -q secret-ancestor.txt
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  commit -qm 'Safe descendant fixture'
printf '%s\n' "$(git -C "$fixture" rev-parse HEAD)" > "$fixture/.git/info/grafts"
expect_failure_without_value \
  "legacy graft cannot hide a publishable ancestor" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture tag-message)"
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  tag -a v-test -m "tag fixture $private_token"
expect_failure_without_value \
  "private value in an annotated tag" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture tagger-email)"
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$private_email" \
  tag -a identity-test -m 'Tagger identity fixture'
expect_failure_without_value \
  "tagger email must use GitHub no-reply" "$fixture" "$private_email" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture raw-tag-header)"
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  tag -a raw-source -m 'Raw tag source fixture'
raw_tag_oid="$(git -C "$fixture" cat-file tag refs/tags/raw-source | awk -v secret="$private_token" '
  BEGIN { inserted = 0 }
  !inserted && $0 == "" { print "x-private " secret; inserted = 1 }
  { print }
' | git -C "$fixture" hash-object -t tag -w --stdin)"
git -C "$fixture" update-ref refs/tags/raw-header "$raw_tag_oid"
expect_failure_without_value \
  "private value in a nonstandard raw tag header" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture raw-tag-noreply-like-header)"
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  tag -a raw-noreply-source -m 'Raw no-reply tag source fixture'
noreply_wrapped_token="${private_token}@${audit_email#*@}"
raw_tag_oid="$(git -C "$fixture" cat-file tag refs/tags/raw-noreply-source | awk -v secret="$noreply_wrapped_token" '
  BEGIN { inserted = 0 }
  !inserted && $0 == "" { print "x-private " secret; inserted = 1 }
  { print }
' | git -C "$fixture" hash-object -t tag -w --stdin)"
git -C "$fixture" update-ref refs/tags/raw-noreply-header "$raw_tag_oid"
expect_failure_without_value \
  "a no-reply-like value in an unknown tag header is not normalized away" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture lightweight-blob-tag)"
blob_oid="$(printf '%s\n' "$private_token" | git -C "$fixture" hash-object -w --stdin)"
git -C "$fixture" update-ref refs/tags/blob-direct "$blob_oid"
expect_failure_without_value \
  "lightweight tag pointing directly to a blob" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture annotated-blob-tag)"
blob_oid="$(printf '%s\n' "$private_token" | git -C "$fixture" hash-object -w --stdin)"
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  tag -a blob-annotated "$blob_oid" -m 'Annotated blob fixture'
expect_failure_without_value \
  "annotated tag pointing directly to a blob" "$fixture" "$private_token" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture lightweight-tree-tag)"
tree_oid="$(git -C "$fixture" rev-parse 'HEAD^{tree}')"
git -C "$fixture" update-ref refs/tags/tree-direct "$tree_oid"
expect_failure \
  "lightweight tag pointing directly to a tree" "$fixture" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture nested-annotated-tag)"
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  tag -a base-annotated -m 'Base annotated tag'
git -C "$fixture" \
  -c user.name='Public Audit' \
  -c user.email="$audit_email" \
  tag -a nested-annotated base-annotated -m 'Nested annotated tag' >/dev/null 2>&1
expect_failure \
  "annotated tag pointing directly to another tag" "$fixture" \
  Scripts/audit-public-history.sh

fixture="$(new_fixture bundle-path)"
mkdir -p "$fixture/Leak.app/Contents/MacOS"
printf '%s\n' 'safe bundle fixture' > "$fixture/Leak.app/Contents/MacOS/Leak"
git -C "$fixture" add -f Leak.app/Contents/MacOS/Leak
expect_failure_without_value \
  "forced tracked build bundle" "$fixture" 'Leak.app' \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture raw-bundle)"
printf '%s\n' "$private_bundle" > "$fixture/raw-bundle.txt"
dd if=/dev/zero bs=1048576 count=20 >> "$fixture/raw-bundle.txt" 2>/dev/null
expect_failure_without_value \
  "large raw private bundle identifier" "$fixture" "$private_bundle" \
  Scripts/audit-public-tree.sh

fixture="$(new_fixture private-filename)"
mkdir -p "$fixture/.local"
printf '%s\n' 'privateuser' > "$fixture/.local/public-secret-patterns.txt"
printf '%s\n' 'safe content' > "$fixture/privateuser-notes.txt"
expect_failure_without_value \
  "private pattern in a filename" "$fixture" 'privateuser' \
  Scripts/audit-public-tree.sh

echo "Public audit regression tests succeeded."
