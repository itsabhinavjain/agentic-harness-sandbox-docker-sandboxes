#!/usr/bin/env bash
set -euo pipefail

# Runs INSIDE the sandbox. Inverse of create_home_symlinks.sh.
# Moves content from home_mounts/ back into $HOME, replacing the symlink
# with the real directory. Content no longer persists across sandbox recreation.

log_info()  { printf '[INFO] %s\n'  "$*" >&2; }
log_warn()  { printf '[WARN] %s\n'  "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$@"; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [DIR...]

DIR must be relative to \$HOME (e.g. .claude, .config/claude).
If no args, reads space-separated SANDBOX_HOME_MOUNT_DIRS env var.
EOF
}

[[ -n "${SANDBOX_HOME_MOUNT_FOLDER_PATH:-}" ]] || \
  die "SANDBOX_HOME_MOUNT_FOLDER_PATH is unset"
[[ -n "${HOME:-}" ]] || die "HOME is unset"

DIRS=()
if [[ $# -gt 0 ]]; then
  DIRS=("$@")
elif [[ -n "${SANDBOX_HOME_MOUNT_DIRS:-}" ]]; then
  # shellcheck disable=SC2206
  DIRS=( ${SANDBOX_HOME_MOUNT_DIRS} )
fi

if [[ ${#DIRS[@]} -eq 0 ]]; then
  usage
  die "no directories to process (no args and SANDBOX_HOME_MOUNT_DIRS empty)"
fi

validate_dir_arg() {
  local d="$1"
  [[ -z "$d" ]] && die "empty directory argument not allowed"
  [[ "$d" == /* ]] && die "absolute path not allowed: $d"
  if [[ "$d" == ".." || "$d" == "../"* || "$d" == *"/.." || "$d" == *"/../"* ]]; then
    die "path traversal not allowed: $d"
  fi
}

process_dir() {
  local dir="$1"
  validate_dir_arg "$dir"

  local link="$HOME/$dir"
  local target="$SANDBOX_HOME_MOUNT_FOLDER_PATH/$dir"

  if [[ ! -e "$link" && ! -L "$link" ]]; then
    log_warn "[SKIP] $link does not exist"
    return 0
  fi

  if [[ ! -L "$link" ]]; then
    log_warn "[SKIP] $link is not a symlink"
    return 0
  fi

  local resolved
  resolved="$(readlink "$link")"
  if [[ "$resolved" != "$target" ]]; then
    log_warn "[SKIP] $link points elsewhere ($resolved)"
    return 0
  fi

  rm "$link"
  mv "$target" "$link"
  log_info "[UNLINKED] $dir"
}

for d in "${DIRS[@]}"; do
  process_dir "$d"
done
