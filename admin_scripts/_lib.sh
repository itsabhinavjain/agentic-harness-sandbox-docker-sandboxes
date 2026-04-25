# shellcheck shell=bash
# Shared library for sandbox lifecycle scripts.
# Source this in every admin_scripts/*.sh script.
# Not executable; sourced only.

# ANSI color codes
_COLOR_RESET=$'\033[0m'
_COLOR_CYAN=$'\033[36m'
_COLOR_YELLOW=$'\033[33m'
_COLOR_RED=$'\033[31m'

# Check if stderr is a TTY to determine whether to use colors
if [[ -t 2 ]]; then
  _USE_COLOR=1
else
  _USE_COLOR=0
fi

log_info() {
  if [[ "$_USE_COLOR" == 1 ]]; then
    printf '%s[INFO]%s %s\n' "$_COLOR_CYAN" "$_COLOR_RESET" "$*" >&2
  else
    printf '[INFO] %s\n' "$*" >&2
  fi
}

log_warn() {
  if [[ "$_USE_COLOR" == 1 ]]; then
    printf '%s[WARN]%s %s\n' "$_COLOR_YELLOW" "$_COLOR_RESET" "$*" >&2
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}

log_error() {
  if [[ "$_USE_COLOR" == 1 ]]; then
    printf '%s[ERROR]%s %s\n' "$_COLOR_RED" "$_COLOR_RESET" "$*" >&2
  else
    printf '[ERROR] %s\n' "$*" >&2
  fi
}

die() {
  log_error "$@"
  exit 1
}

resolve_project_root() {
  local root
  # Try git first
  if root=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "$root"
    return 0
  fi

  # Fallback: parent of admin_scripts/ derived from this file's location
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || \
    die "Cannot determine project root: not in a git repo and BASH_SOURCE path resolution failed"
  dirname "$script_dir"
}

load_env() {
  local env_file="$PROJECT_ROOT/.env"
  [[ ! -f "$env_file" ]] && return 0

  # Parse KEY=VALUE pairs, skip comments/blank lines, respect existing env.
  # Strip surrounding single or double quotes from values.
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    # Must contain '='
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    val="${line#*=}"

    # Trim whitespace around key
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"

    # Validate key format
    [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && continue

    # Strip surrounding quotes from value (double or single)
    if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi

    # Only set if not already in environment
    if [[ -z "${!key:-}" ]]; then
      export "$key=$val"
    fi
  done < "$env_file"
}

validate_sbx_installed() {
  log_info "[1/4] Checking sbx CLI is installed"
  command -v sbx >/dev/null 2>&1 || \
    die "sbx CLI not found on PATH. Install Docker Desktop 4.58+."
}

validate_sandbox_exists() {
  local name="$1"
  [[ -z "$name" ]] && die "validate_sandbox_exists: name argument required"

  log_info "[2/4] Verifying sandbox '$name' exists"
  # Use sbx ls to list sandboxes. Match the name as a whole word to avoid
  # substring false positives (e.g. "foo" matching "foo-bar").
  local listing
  listing=$(sbx ls 2>/dev/null) || die "Failed to run 'sbx ls' — is Docker running?"

  if ! echo "$listing" | awk '{print $1}' | grep -qx "$name"; then
    die "Sandbox '$name' does not exist."
  fi
  log_info "      sandbox '$name' found"
}

validate_sandbox_env_vars() {
  local name="$1"
  [[ -z "$name" ]] && die "validate_sandbox_env_vars: name argument required"

  log_info "[3/4] Validating env vars and mounts inside sandbox (sbx may take a few seconds to attach)"
  # Do all validation in a SINGLE sbx exec call. Multiple round-trips
  # pay sbx's per-call attach cost and visibly print "Starting Docker daemon"
  # each time; one call is fast enough that users won't Ctrl+C it.
  local output exit_code=0
  # Use a distinctive marker (__SBXV__) so we can ignore sbx's own informational
  # lines (e.g. "Sandbox … started successfully") that come back on stdout/stderr.
  # shellcheck disable=SC2016  # intentional: single quotes so $var expands in sandbox, not host
  output=$(sbx exec "$name" bash -lc '
    for var in SANDBOX_WORKING_DIRECTORY_FOLDER_PATH SANDBOX_SCRIPTS_FOLDER_PATH SANDBOX_HOME_MOUNT_FOLDER_PATH; do
      val="${!var:-}"
      if [[ -z "$val" ]]; then
        printf "__SBXV__\tMISSING\t%s\t\n" "$var"
      elif [[ ! -d "$val" ]]; then
        printf "__SBXV__\tNODIR\t%s\t%s\n" "$var" "$val"
      else
        printf "__SBXV__\tOK\t%s\t%s\n" "$var" "$val"
      fi
    done
  ' 2>&1) || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    die "Failed to validate env vars in sandbox '$name' (sbx exec exit=$exit_code). Is the sandbox running? Try: sbx ls
Output: $output"
  fi

  # Extract only our marker lines; sbx itself prints unrelated status text.
  local marker_lines
  marker_lines=$(echo "$output" | tr -d '\r' | grep '^__SBXV__	' || true)

  if [[ -z "$marker_lines" ]]; then
    die "No validation output from sandbox '$name'. Raw output was:
$output"
  fi

  local tag status var val
  while IFS=$'\t' read -r tag status var val; do
    [[ "$tag" != "__SBXV__" ]] && continue
    case "$status" in
      OK)      log_info "      ok: $var = $val" ;;
      MISSING) die "$var not set in sandbox $name (was init run?)" ;;
      NODIR)   die "$var points to '$val' which does not exist inside sandbox $name (mount failure?)" ;;
      *)       die "Unexpected validation status from sandbox $name: '$status' (var=$var val=$val)" ;;
    esac
  done <<< "$marker_lines"
}

ensure_ports_published() {
  local name="$1"
  [[ -z "$name" ]] && die "ensure_ports_published: name argument required"

  # No ports configured — nothing to do
  if [[ -z "${SANDBOX_PORTS:-}" ]]; then
    log_info "[4/4] No SANDBOX_PORTS configured; skipping port publish"
    return 0
  fi

  log_info "[4/4] Publishing ports: $SANDBOX_PORTS"
  local any_processed=0
  local mapping output exit_code current
  for mapping in $SANDBOX_PORTS; do
    # Validate format
    if ! [[ "$mapping" =~ ^[0-9]+:[0-9]+$ ]]; then
      die "Invalid port mapping in SANDBOX_PORTS: '$mapping' (expected HOST:SANDBOX)"
    fi

    # Attempt publish — capture stdout+stderr, don't fail the script
    exit_code=0
    output=$(sbx ports "$name" --publish "$mapping" 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      log_info "Published $mapping"
      any_processed=1
      continue
    fi

    # Non-zero: verify via list whether the mapping is already in place.
    current=$(sbx ports "$name" 2>/dev/null) || current=""
    if echo "$current" | grep -qF "$mapping"; then
      log_info "Already published: $mapping"
      any_processed=1
    else
      die "Failed to publish port mapping: $mapping
$output"
    fi
  done

  if [[ $any_processed -eq 1 ]]; then
    log_info "Reminder: services inside the sandbox must bind to 0.0.0.0 to be reachable through published ports"
  fi
}

ensure_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    log_info "Directory not found: $dir — creating it"
    mkdir -p "$dir" || die "Failed to create directory: $dir"
  fi
}