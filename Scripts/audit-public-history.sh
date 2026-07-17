#!/bin/bash

set -euo pipefail
export LC_ALL=C
export GIT_NO_REPLACE_OBJECTS=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/public-audit-common.sh"

fail() {
  echo "error: $*" >&2
  exit 1
}

public_audit_git_environment_is_clean \
  || fail "unset Git repository-selection environment overrides before running the public audit"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "Git metadata is required for a history audit; run Scripts/audit-public-tree.sh before the first commit"
GIT_ROOT="$(git rev-parse --show-toplevel)"
[[ "$(cd "$GIT_ROOT" && pwd -P)" == "$(pwd -P)" ]] \
  || fail "Git metadata belongs to a parent or different working tree"
[[ "$(git rev-parse --is-shallow-repository)" == "false" ]] \
  || fail "a shallow repository does not contain enough history for a public audit"
GRAFTS_PATH="$(git rev-parse --git-path info/grafts)"
[[ ! -s "$GRAFTS_PATH" ]] \
  || fail "legacy Git grafts can hide publishable ancestors; remove them before auditing"

PATTERN_SOURCE="$ROOT/Scripts/public-secret-patterns.txt"
[[ -f "$PATTERN_SOURCE" ]] || fail "missing Scripts/public-secret-patterns.txt"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-rate-widget-history-audit.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
ACTIVE_PATTERNS="$TEMP_DIR/patterns.txt"
COMMITS="$TEMP_DIR/commits.txt"
TAGS="$TEMP_DIR/tags.txt"
REFS="$TEMP_DIR/refs.txt"
ENTRIES="$TEMP_DIR/entries.bin"
SCAN_FILE="$TEMP_DIR/content.bin"
RAW_OBJECT="$TEMP_DIR/raw-object.bin"
RAW_MATCHES="$TEMP_DIR/raw-bundle-matches.txt"
FINDINGS="$TEMP_DIR/findings.txt"
EXTRA_PATTERN_SOURCE="$TEMP_DIR/extra-patterns.txt"
DEFAULT_EXTRA_PATTERN_SOURCE="$ROOT/.local/public-secret-patterns.txt"
ADDITIONAL_EXTRA_PATTERN_SOURCE="${CODEX_RATE_WIDGET_AUDIT_EXTRA_PATTERNS:-}"

public_audit_prepare_extra_pattern_file \
  "$DEFAULT_EXTRA_PATTERN_SOURCE" "$ADDITIONAL_EXTRA_PATTERN_SOURCE" "$EXTRA_PATTERN_SOURCE" \
  || fail "private public-audit patterns are missing, unreadable, or not regular files"
public_audit_build_pattern_file "$PATTERN_SOURCE" "$EXTRA_PATTERN_SOURCE" "$ACTIVE_PATTERNS" \
  || fail "public audit patterns are empty, unreadable, or invalid extended regular expressions"
git rev-list --all > "$COMMITS"
git for-each-ref --format='%(refname)' refs/tags > "$TAGS" \
  || fail "tag references could not be enumerated for auditing"
git for-each-ref --format='%(refname)%09%(objecttype)' > "$REFS" \
  || fail "Git references could not be enumerated for auditing"

if [[ ! -s "$COMMITS" && ! -s "$TAGS" && ! -s "$REFS" ]]; then
  echo "No commits, tags, or refs exist yet; there is no history to audit. Run Scripts/audit-public-tree.sh before the first commit."
  exit 0
fi

record_content_finding() {
  local source_label="$1"
  local safe_path="$2"
  printf '%s %s\n' "$source_label" "$safe_path" >> "$FINDINGS"
}

audit_path_name() {
  local source_label="$1"
  local candidate_path="$2"
  local result

  if public_audit_path_is_private "$candidate_path" "$ACTIVE_PATTERNS" "$SCAN_FILE" "$RAW_MATCHES"; then
    printf '%s <redacted sensitive path>\n' "$source_label" >> "$FINDINGS"
    return 1
  else
    result=$?
    [[ "$result" -eq 1 ]] && return 0
    fail "a historical path or ref could not be audited"
  fi
}

audit_materialized_content() {
  local source_label="$1"
  local safe_path="$2"
  local result

  if public_audit_file_has_private_content "$SCAN_FILE" "$ACTIVE_PATTERNS" "$RAW_MATCHES"; then
    record_content_finding "$source_label" "$safe_path"
  else
    result=$?
    [[ "$result" -eq 1 ]] || fail "historical content could not be audited"
  fi
}

audit_identity_email() {
  local source_label="$1"
  local safe_label="$2"
  local identity_email
  local github_user_noreply_domain='users.noreply.github.com'
  local github_generic_noreply='noreply@''github.com'

  identity_email="$(tr -d '\r\n<>' < "$SCAN_FILE")"
  case "$identity_email" in
    ?*@"$github_user_noreply_domain"|"$github_generic_noreply")
      return 0
      ;;
    *)
      record_content_finding "$source_label" "$safe_label"
      ;;
  esac
}

audit_raw_git_object() {
  local git_object_type="$1"
  local git_object_name="$2"
  local source_label="$3"
  local safe_label="$4"
  local identity_line_pattern
  local github_user_noreply_suffix='@users\.noreply\.github\.com'
  local github_generic_noreply_pattern='noreply@''github\.com'

  case "$git_object_type" in
    commit)
      identity_line_pattern='^(author|committer) '
      ;;
    tag)
      identity_line_pattern='^tagger '
      ;;
    *)
      fail "an unsupported raw Git object type cannot be audited"
      ;;
  esac

  git cat-file "$git_object_type" "$git_object_name" > "$RAW_OBJECT" 2>/dev/null \
    || fail "a raw Git object could not be materialized for auditing"
  sed -E \
    -e "/${identity_line_pattern}/s#${github_user_noreply_suffix}#<github-no-reply>#g" \
    -e "/${identity_line_pattern}/s#${github_generic_noreply_pattern}#noreply<github-no-reply>#g" \
    "$RAW_OBJECT" > "$SCAN_FILE" 2>/dev/null \
    || fail "a raw Git object could not be normalized for auditing"
  audit_materialized_content "$source_label" "$safe_label"
}

while IFS=$'\t' read -r ref_name ref_object_type; do
  [[ -n "$ref_name" ]] || continue
  if ! audit_path_name "ref" "$ref_name"; then
    continue
  fi
  case "$ref_name" in
    refs/tags/*)
      # Tag refs receive their object and metadata checks below.
      ;;
    refs/replace/*)
      printf 'ref %s (replace refs are not publishable audit inputs)\n' "$ref_name" >> "$FINDINGS"
      ;;
    *)
      if [[ "$ref_object_type" != "commit" ]]; then
        printf 'ref %s (non-tag ref does not reference a commit)\n' "$ref_name" >> "$FINDINGS"
      fi
      ;;
  esac
done < "$REFS"

echo "Scanning every reachable commit without printing matched private values..."
while IFS= read -r commit; do
  short_commit="$(git rev-parse --short=12 "$commit")"

  git log -1 --format=%B "$commit" > "$SCAN_FILE" \
    || fail "a commit message could not be materialized for auditing"
  if public_audit_file_has_private_content "$SCAN_FILE" "$ACTIVE_PATTERNS" "$RAW_MATCHES"; then
    printf '%s <commit message>\n' "$short_commit" >> "$FINDINGS"
  else
    result=$?
    [[ "$result" -eq 1 ]] || fail "a commit message could not be audited"
  fi

  git log -1 --format='%an' "$commit" > "$SCAN_FILE" \
    || fail "an author name could not be materialized for auditing"
  audit_materialized_content "$short_commit" "<author name>"
  git log -1 --format='%ae' "$commit" > "$SCAN_FILE" \
    || fail "an author email could not be materialized for auditing"
  audit_identity_email "$short_commit" "<author email is not GitHub no-reply>"
  git log -1 --format='%cn' "$commit" > "$SCAN_FILE" \
    || fail "a committer name could not be materialized for auditing"
  audit_materialized_content "$short_commit" "<committer name>"
  git log -1 --format='%ce' "$commit" > "$SCAN_FILE" \
    || fail "a committer email could not be materialized for auditing"
  audit_identity_email "$short_commit" "<committer email is not GitHub no-reply>"
  audit_raw_git_object "commit" "$commit" "$short_commit" "<raw commit metadata>"

  git ls-tree -rz "$commit" > "$ENTRIES"
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    candidate_path="${entry#*$'\t'}"
    mode="${metadata%% *}"
    type_and_object="${metadata#* }"
    object_type="${type_and_object%% *}"
    object_id="${metadata##* }"
    [[ "$entry" != "$metadata" && -n "$candidate_path" && -n "$object_id" ]] \
      || fail "a historical Git entry could not be parsed for auditing"
    path_is_safe=1
    if ! audit_path_name "$short_commit" "$candidate_path"; then
      path_is_safe=0
    fi

    case "$mode" in
      100*)
        [[ "$object_type" == "blob" ]] \
          || fail "a historical file has an unexpected Git object type"
        git cat-file blob "$object_id" > "$SCAN_FILE" 2>/dev/null \
          || fail "a historical file could not be materialized for auditing"
        [[ "$path_is_safe" -eq 0 ]] || audit_materialized_content "$short_commit" "$candidate_path"
        ;;
      120000)
        [[ "$object_type" == "blob" ]] \
          || fail "a historical symlink has an unexpected Git object type"
        git cat-file blob "$object_id" > "$SCAN_FILE" 2>/dev/null \
          || fail "a historical symlink could not be materialized for auditing"
        if [[ "$path_is_safe" -eq 1 ]]; then
          target="$(<"$SCAN_FILE")"
          if public_audit_symlink_target_is_unsafe "$target"; then
            printf '%s %s (unsafe symlink target)\n' "$short_commit" "$candidate_path" >> "$FINDINGS"
          else
            audit_materialized_content "$short_commit" "$candidate_path"
          fi
        fi
        ;;
      160000)
        [[ "$object_type" == "commit" ]] \
          || fail "a historical gitlink has an unexpected Git object type"
        [[ "$path_is_safe" -eq 0 ]] \
          || printf '%s %s (gitlink content is outside this audit)\n' "$short_commit" "$candidate_path" >> "$FINDINGS"
        ;;
      *)
        fail "an unsupported historical Git entry could not be audited"
        ;;
    esac
  done < "$ENTRIES"
done < "$COMMITS"

while IFS= read -r tag_ref; do
  [[ -n "$tag_ref" ]] || continue
  if ! audit_path_name "tag" "$tag_ref"; then
    continue
  fi

  git cat-file -t "$tag_ref" > "$SCAN_FILE" 2>/dev/null \
    || fail "a tag target type could not be materialized for auditing"
  tag_object_type="$(tr -d '\r\n' < "$SCAN_FILE")"
  case "$tag_object_type" in
    commit)
      # A lightweight tag must point directly at a commit.
      ;;
    tag)
      # For an annotated tag, %(type) is the direct tagged-object type. Reject
      # blob, tree, and nested-tag targets even if they eventually peel to a
      # commit: every object published through refs/tags must have an audited
      # commit tree as its direct content boundary.
      git for-each-ref --format='%(type)' "$tag_ref" > "$SCAN_FILE" \
        || fail "an annotated tag target type could not be materialized for auditing"
      direct_target_type="$(tr -d '\r\n' < "$SCAN_FILE")"
      if [[ "$direct_target_type" != "commit" ]]; then
        printf 'tag %s (annotated tag does not directly reference a commit)\n' "$tag_ref" >> "$FINDINGS"
      fi

      git for-each-ref --format='%(taggername)' "$tag_ref" > "$SCAN_FILE" \
        || fail "an annotated tagger name could not be materialized for auditing"
      audit_materialized_content "tag" "<tagger name>"
      git for-each-ref --format='%(taggeremail)' "$tag_ref" > "$SCAN_FILE" \
        || fail "an annotated tagger email could not be materialized for auditing"
      audit_identity_email "tag" "<tagger email is not GitHub no-reply>"
      audit_raw_git_object "tag" "$tag_ref" "tag" "<raw annotated tag metadata>"
      ;;
    *)
      printf 'tag %s (lightweight tag does not reference a commit)\n' "$tag_ref" >> "$FINDINGS"
      ;;
  esac

  git for-each-ref --format='%(contents)' "$tag_ref" > "$SCAN_FILE" \
    || fail "an annotated tag message could not be materialized for auditing"
  audit_materialized_content "tag" "<annotated tag message>"
done < "$TAGS"

if [[ -s "$FINDINGS" ]]; then
  echo "Public-history audit found commits or tags that require review:" >&2
  sort -u "$FINDINGS" >&2
  fail "publish from a sanitized new history; do not restore or push a history containing private material"
fi

echo "Public-history audit succeeded."
