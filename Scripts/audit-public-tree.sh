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

command -v git >/dev/null || fail "git is required for the public tree audit"

PATTERN_SOURCE="$ROOT/Scripts/public-secret-patterns.txt"
[[ -f "$PATTERN_SOURCE" ]] || fail "missing Scripts/public-secret-patterns.txt"

validate_public_gitignore() {
  local file_path="$1"
  local source_label="$2"
  local ignore_pattern

  [[ -f "$file_path" && ! -L "$file_path" ]] \
    || fail "$source_label .gitignore must be a regular file"
  for ignore_pattern in "${PUBLIC_AUDIT_REQUIRED_IGNORES[@]}"; do
    grep -Fxq "$ignore_pattern" "$file_path" 2>/dev/null \
      || fail "$source_label .gitignore is missing a required public exclusion"
  done
}

validate_public_shared_config() {
  local file_path="$1"
  local source_label="$2"

  [[ -f "$file_path" && ! -L "$file_path" ]] \
    || fail "$source_label Config/Shared.xcconfig must be a regular file"
  [[ "$(grep -Ec '^[[:space:]]*CODEX_RATE_WIDGET_BUNDLE_ID([[:space:]]*\[[^]]+\])*[[:space:]]*=' "$file_path" 2>/dev/null)" -eq 1 ]] \
    || fail "$source_label public bundle identifier must have exactly one assignment"
  [[ "$(grep -Ec '^CODEX_RATE_WIDGET_BUNDLE_ID[[:space:]]*=[[:space:]]*com\.example\.CodexRateWidget[[:space:]]*$' "$file_path" 2>/dev/null)" -eq 1 ]] \
    || fail "$source_label public bundle identifier must be com.example.CodexRateWidget"
  [[ "$(grep -Ec '^[[:space:]]*CODEX_RATE_WIDGET_DEVELOPMENT_TEAM([[:space:]]*\[[^]]+\])*[[:space:]]*=' "$file_path" 2>/dev/null)" -eq 1 ]] \
    || fail "$source_label public development Team setting must have exactly one assignment"
  [[ "$(grep -Ec '^CODEX_RATE_WIDGET_DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*$' "$file_path" 2>/dev/null)" -eq 1 ]] \
    || fail "$source_label public development Team setting must remain empty"
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-rate-widget-public-audit.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
ACTIVE_PATTERNS="$TEMP_DIR/patterns.txt"
INDEX_ENTRIES="$TEMP_DIR/index-entries.bin"
WORKTREE_CANDIDATES="$TEMP_DIR/worktree-candidates.bin"
SCAN_FILE="$TEMP_DIR/content.bin"
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

HAS_GIT=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_ROOT="$(git rev-parse --show-toplevel)"
  [[ "$(cd "$GIT_ROOT" && pwd -P)" == "$(pwd -P)" ]] \
    || fail "Git metadata belongs to a parent or different working tree"
  HAS_GIT=1
  git ls-files --cached --stage -z > "$INDEX_ENTRIES"
  git ls-files --cached --others --exclude-standard -z > "$WORKTREE_CANDIDATES"
else
  echo "No Git metadata found; auditing source candidates through an isolated Git ignore index."
  DISCOVERY_REPOSITORY="$TEMP_DIR/discovery"
  git init -q "$DISCOVERY_REPOSITORY"
  GIT_DIR="$DISCOVERY_REPOSITORY/.git" GIT_WORK_TREE="$ROOT" \
    git ls-files --others --exclude-standard -z > "$WORKTREE_CANDIDATES"
  : > "$INDEX_ENTRIES"
fi

validate_public_gitignore "$ROOT/.gitignore" "working-tree"
validate_public_shared_config "$ROOT/Config/Shared.xcconfig" "working-tree"

materialize_required_index_file() {
  local required_path="$1"
  local destination="$2"
  local expected_mode="$3"
  local entry metadata candidate_path mode object_and_stage object_id stage
  local found=0

  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    candidate_path="${entry#*$'\t'}"
    [[ "$candidate_path" == "$required_path" ]] || continue
    found=$((found + 1))
    mode="${metadata%% *}"
    object_and_stage="${metadata#* }"
    object_id="${object_and_stage%% *}"
    stage="${metadata##* }"
    [[ "$entry" != "$metadata" && -n "$object_id" && "$stage" == "0" ]] \
      || fail "a required staged public-audit file is unresolved or malformed"
    [[ "$mode" == "$expected_mode" ]] \
      || fail "a required staged public-audit file has an unsafe Git mode"
    git cat-file blob "$object_id" > "$destination" 2>/dev/null \
      || fail "a required staged public-audit file could not be materialized"
  done < "$INDEX_ENTRIES"

  [[ "$found" -eq 1 ]] \
    || fail "a required public-audit file is absent from or duplicated in the index"
}

if [[ "$HAS_GIT" -eq 1 ]]; then
  ENFORCEMENT_FILES=(
    '.gitignore:100644'
    'Config/Shared.xcconfig:100644'
    'Scripts/public-secret-patterns.txt:100644'
    'Scripts/public-audit-common.sh:100644'
    'Scripts/audit-public-tree.sh:100755'
    'Scripts/audit-public-history.sh:100755'
  )
  for enforcement_spec in "${ENFORCEMENT_FILES[@]}"; do
    enforcement_path="${enforcement_spec%:*}"
    enforcement_mode="${enforcement_spec##*:}"
    enforcement_copy="$TEMP_DIR/enforcement-$enforcement_mode-$(basename "$enforcement_path")"
    materialize_required_index_file "$enforcement_path" "$enforcement_copy" "$enforcement_mode"
    cmp -s "$enforcement_copy" "$ROOT/$enforcement_path" \
      || fail "staged and working-tree public-audit enforcement files must match exactly"
  done
  validate_public_gitignore "$TEMP_DIR/enforcement-100644-.gitignore" "staged"
  validate_public_shared_config "$TEMP_DIR/enforcement-100644-Shared.xcconfig" "staged"
fi

record_private_path() {
  local source_label="$1"
  printf '%s <redacted sensitive path>\n' "$source_label" >> "$FINDINGS"
}

audit_path_name() {
  local source_label="$1"
  local candidate_path="$2"
  local result

  if public_audit_path_is_private "$candidate_path" "$ACTIVE_PATTERNS" "$SCAN_FILE" "$RAW_MATCHES"; then
    record_private_path "$source_label"
    return 1
  else
    result=$?
    [[ "$result" -eq 1 ]] && return 0
    fail "a candidate path could not be audited"
  fi
}

audit_materialized_content() {
  local source_label="$1"
  local safe_path="$2"
  local result

  if public_audit_file_has_private_content "$SCAN_FILE" "$ACTIVE_PATTERNS" "$RAW_MATCHES"; then
    printf '%s %s\n' "$source_label" "$safe_path" >> "$FINDINGS"
  else
    result=$?
    [[ "$result" -eq 1 ]] || fail "candidate content could not be audited"
  fi
}

audit_materialized_symlink() {
  local source_label="$1"
  local safe_path="$2"
  local target

  target="$(<"$SCAN_FILE")"
  if public_audit_symlink_target_is_unsafe "$target"; then
    printf '%s %s (unsafe symlink target)\n' "$source_label" "$safe_path" >> "$FINDINGS"
    return
  fi
  audit_materialized_content "$source_label" "$safe_path"
}

while IFS= read -r -d '' entry; do
  metadata="${entry%%$'\t'*}"
  candidate_path="${entry#*$'\t'}"
  mode="${metadata%% *}"
  object_and_stage="${metadata#* }"
  object_id="${object_and_stage%% *}"
  stage="${metadata##* }"

  [[ "$entry" != "$metadata" && -n "$candidate_path" && -n "$object_id" ]] \
    || fail "a staged Git entry could not be parsed for auditing"
  [[ "$stage" == "0" ]] \
    || fail "an unresolved staged Git entry cannot be published or audited safely"

  path_is_safe=1
  if ! audit_path_name "index" "$candidate_path"; then
    path_is_safe=0
  fi

  case "$mode" in
    100*)
      git cat-file blob "$object_id" > "$SCAN_FILE" 2>/dev/null \
        || fail "a staged file could not be materialized for auditing"
      [[ "$path_is_safe" -eq 0 ]] || audit_materialized_content "index" "$candidate_path"
      ;;
    120000)
      git cat-file blob "$object_id" > "$SCAN_FILE" 2>/dev/null \
        || fail "a staged symlink could not be materialized for auditing"
      [[ "$path_is_safe" -eq 0 ]] || audit_materialized_symlink "index" "$candidate_path"
      ;;
    160000)
      [[ "$path_is_safe" -eq 0 ]] \
        || printf 'index %s (gitlink content is outside this audit)\n' "$candidate_path" >> "$FINDINGS"
      ;;
    *)
      fail "an unsupported staged Git entry could not be audited"
      ;;
  esac
done < "$INDEX_ENTRIES"

while IFS= read -r -d '' candidate_path; do
  if ! audit_path_name "working-tree" "$candidate_path"; then
    continue
  fi

  full_path="$ROOT/$candidate_path"
  if [[ -L "$full_path" ]]; then
    readlink "$full_path" > "$SCAN_FILE" 2>/dev/null \
      || fail "a working-tree symlink could not be read for auditing"
    audit_materialized_symlink "working-tree" "$candidate_path"
  elif [[ -f "$full_path" ]]; then
    cp "$full_path" "$SCAN_FILE" 2>/dev/null \
      || fail "a working-tree file could not be read for auditing"
    audit_materialized_content "working-tree" "$candidate_path"
  elif [[ "$HAS_GIT" -eq 1 ]] && git ls-files --error-unmatch -- "$candidate_path" >/dev/null 2>&1; then
    # A tracked file deleted only in the working tree was already scanned from
    # the index above. Once its deletion is staged it disappears from both.
    continue
  else
    fail "a public candidate disappeared or has an unsupported file type"
  fi
done < "$WORKTREE_CANDIDATES"

if [[ -s "$FINDINGS" ]]; then
  echo "Public-tree audit found candidates that require review:" >&2
  sort -u "$FINDINGS" >&2
  fail "remove private material or add only an intentionally safe, generic rule"
fi

echo "Public-tree audit succeeded."
