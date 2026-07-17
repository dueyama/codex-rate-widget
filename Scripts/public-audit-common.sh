#!/bin/bash

# Shared constants and fail-closed helpers for the public tree and history
# audits. This file is sourced; it is not an entry point.

# Legacy grep implementations still honor this variable. An inherited
# --exclude option could otherwise skip the temporary materialized blobs.
unset GREP_OPTIONS

PUBLIC_AUDIT_REQUIRED_IGNORES=(
  '.DS_Store'
  'DerivedData/'
  'build/'
  '.build/'
  '*.app'
  '*.appex'
  '*.xctest'
  '*.xcarchive'
  '*.dSYM'
  '*.dSYM.zip'
  '*.xcuserstate'
  'xcuserdata/'
  'Config/Local.xcconfig'
  'Config/Local.xcconfig.tmp.*'
  '*.p12'
  '*.p8'
  '*.pem'
  '*.key'
  '*.cer'
  '*.crt'
  '*.pfx'
  '*.jks'
  '*.keystore'
  '*.mobileprovision'
  '*.provisionprofile'
  '.env'
  '.env.*'
  '.netrc'
  '.npmrc'
  '.git-credentials'
  '.aws/'
  '.ssh/'
  '.codex/'
  '.agents/'
  '.local/'
  '.swiftpm/'
  '.idea/'
  '.vscode/'
  'state_5.sqlite*'
  'usage-snapshot-v1.json'
  '*.log'
  '*.orig'
  '*.bak'
  '*.swp'
  '*.swo'
  '*~'
  '*.dmg'
  '*.pkg'
  '*.zip'
  '*.tar'
  '*.tar.gz'
  '*.tgz'
  '*.7z'
  '*.rar'
)

PUBLIC_AUDIT_SENSITIVE_PATH_PATTERN='(^|/)(\.DS_Store|DerivedData|build|\.build|xcuserdata|\.codex|\.agents|\.local|\.swiftpm|\.idea|\.vscode|\.aws|\.ssh|[^/]+\.(app|appex|xctest|xcarchive|dSYM))(/|$)|\.xcuserstate$|^Config/Local\.xcconfig($|\.tmp\.)|\.(p12|p8|pem|key|cer|crt|pfx|jks|keystore|mobileprovision|provisionprofile|dSYM\.zip|moved-aside|xccheckout|xcscmblueprint|log|orig|bak|swp|swo|dmg|pkg|zip|tar|tar\.gz|tgz|7z|rar)$|~$|(^|/)(\.env($|\.)|\.netrc$|\.npmrc$|\.git-credentials$)|(^|/)state_5\.sqlite|(^|/)usage-snapshot-v1\.json$'
PUBLIC_AUDIT_RAW_BUNDLE_PATTERN='([A-Za-z0-9-]+\.){2,}CodexRateWidget'
PUBLIC_AUDIT_ALLOWED_BUNDLE_PATTERN='com\.(example|yourname)\.CodexRateWidget'

# Repository-selection overrides can make an audit inspect a different index,
# object store, namespace, or history boundary than a later ordinary push.
# Fail instead of silently auditing that alternate view. GIT_NO_REPLACE_OBJECTS
# is intentionally absent because each entry point sets it to 1 itself.
public_audit_git_environment_is_clean() {
  local variable

  for variable in \
    GIT_DIR \
    GIT_WORK_TREE \
    GIT_COMMON_DIR \
    GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_NAMESPACE \
    GIT_CEILING_DIRECTORIES \
    GIT_SHALLOW_FILE \
    GIT_REPLACE_REF_BASE; do
    if printenv "$variable" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

# The ignored repository-local pattern file is always included when present.
# An explicit environment path is additive, never a replacement that could
# silently disable the local privacy rules.
public_audit_prepare_extra_pattern_file() {
  local default_source="$1"
  local additional_source="$2"
  local destination="$3"

  : > "$destination" || return 2
  if [[ -e "$default_source" || -L "$default_source" ]]; then
    [[ -f "$default_source" && -r "$default_source" ]] || return 2
    cat "$default_source" >> "$destination" 2>/dev/null || return 2
  fi
  if [[ -n "$additional_source" ]]; then
    [[ -f "$additional_source" && -r "$additional_source" ]] || return 2
    cat "$additional_source" >> "$destination" 2>/dev/null || return 2
  fi
  return 0
}

public_audit_build_pattern_file() {
  local pattern_source="$1"
  local extra_pattern_source="$2"
  local destination="$3"
  local result

  sed -E '/^[[:space:]]*(#|$)/d' "$pattern_source" > "$destination" 2>/dev/null || return 2
  if [[ -f "$extra_pattern_source" ]]; then
    sed -E '/^[[:space:]]*(#|$)/d' "$extra_pattern_source" >> "$destination" 2>/dev/null || return 2
  fi
  [[ -s "$destination" ]] || return 2

  if grep -aE -f "$destination" /dev/null >/dev/null 2>&1; then
    return 0
  else
    result=$?
    [[ "$result" -eq 1 ]] && return 0
    return 2
  fi
}

# Returns 0 when private-looking content is found, 1 when clean, and 2 when
# the scan itself fails. Callers must treat 2 as a fatal audit error.
public_audit_file_has_private_content() {
  local content_path="$1"
  local pattern_file="$2"
  local raw_matches_path="$3"
  local result

  if grep -aE -f "$pattern_file" "$content_path" >/dev/null 2>&1; then
    return 0
  else
    result=$?
    [[ "$result" -eq 1 ]] || return 2
  fi

  if grep -aoE "$PUBLIC_AUDIT_RAW_BUNDLE_PATTERN" "$content_path" > "$raw_matches_path" 2>/dev/null; then
    if grep -aEv "^${PUBLIC_AUDIT_ALLOWED_BUNDLE_PATTERN}$" "$raw_matches_path" >/dev/null 2>&1; then
      return 0
    else
      result=$?
      [[ "$result" -eq 1 ]] || return 2
    fi
  else
    result=$?
    [[ "$result" -eq 1 ]] || return 2
  fi

  return 1
}

# Applies both fixed sensitive-path rules and user-supplied private patterns
# to a path or ref name. It never prints the supplied value.
public_audit_path_is_private() {
  local candidate_path="$1"
  local pattern_file="$2"
  local scan_path="$3"
  local raw_matches_path="$4"
  local result

  printf '%s\n' "$candidate_path" > "$scan_path" || return 2
  if grep -aEi "$PUBLIC_AUDIT_SENSITIVE_PATH_PATTERN" "$scan_path" >/dev/null 2>&1; then
    return 0
  else
    result=$?
    [[ "$result" -eq 1 ]] || return 2
  fi

  if public_audit_file_has_private_content "$scan_path" "$pattern_file" "$raw_matches_path"; then
    return 0
  else
    result=$?
    [[ "$result" -eq 1 ]] && return 1
    return 2
  fi
}

# A public source symlink may stay within the checkout. Absolute targets and
# any parent-directory traversal are rejected without printing the target.
public_audit_symlink_target_is_unsafe() {
  local target="$1"

  case "$target" in
    /*)
      return 0
      ;;
  esac
  case "/$target/" in
    */../*)
      return 0
      ;;
  esac
  return 1
}
