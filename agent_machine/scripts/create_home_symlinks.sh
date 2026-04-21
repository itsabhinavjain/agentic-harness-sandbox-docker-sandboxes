#!/usr/bin/env bash
set -euo pipefail

# Runs INSIDE the sandbox, as user `agent`, cwd typically /home/agent.
# Migrates directories in $HOME into $SANDBOX_HOME_MOUNT_FOLDER_PATH and
# replaces them with symlinks. Idempotent — safe after sbx rm / recreate.

log_info()  { printf '[INFO] %s\n'  "$*" >&2; }
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
  die "SANDBOX_HOME_MOUNT_FOLDER_PATH is unset (must be injected by 01_sandbox_init.sh)"
[[ -n "${HOME:-}" ]] || die "HOME is unset"

# Gather directories from args or env
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
  # Reject any '..' segment (leading, trailing, or middle)
  if [[ "$d" == ".." || "$d" == "../"* || "$d" == *"/.." || "$d" == *"/../"* ]]; then
    die "path traversal not allowed: $d"
  fi
}

process_dir() {
  local dir="$1"
  validate_dir_arg "$dir"

  local link="$HOME/$dir"
  local target="$SANDBOX_HOME_MOUNT_FOLDER_PATH/$dir"

  # Case: LINK is a symlink
  if [[ -L "$link" ]]; then
    local resolved
    resolved="$(readlink "$link")"
    if [[ "$resolved" == "$target" ]]; then
      log_info "[OK] already linked: $dir"
      return 0
    fi
    die "$link is a symlink but not to $target; refusing to clobber"
  fi

  # Case: LINK exists as regular file (not dir, not symlink)
  if [[ -e "$link" && ! -d "$link" ]]; then
    die "$link is a file, not a directory; refusing to clobber"
  fi

  # Case: LINK is a real directory
  if [[ -d "$link" ]]; then
    if [[ -e "$target" ]]; then
      # TARGET exists = persisted state is the source of truth.
      # LINK is typically a template-provided default dir that must be displaced
      # so the home folder ends up as a symlink into home_mounts.
      if [[ -z "$(ls -A "$link" 2>/dev/null)" ]]; then
        # Empty template dir — just remove and relink, no backup needed.
        rmdir "$link"
        mkdir -p "$(dirname "$link")"
        ln -s "$target" "$link"
        log_info "[OVERRIDDEN] $dir -> $target (displaced empty template dir)"
      else
        # Non-empty: back up before overriding so nothing is silently lost.
        local backup
        backup="${link}.template-backup.$(date +%s)"
        mv "$link" "$backup"
        mkdir -p "$(dirname "$link")"
        ln -s "$target" "$link"
        log_info "[OVERRIDDEN] $dir -> $target (template contents preserved at $backup)"
      fi
      return 0
    fi
    # TARGET missing: first-time migration.
    mkdir -p "$(dirname "$target")"
    mv "$link" "$target"
    mkdir -p "$(dirname "$link")"
    ln -s "$target" "$link"
    log_info "[MIGRATED] $dir -> $target"
    return 0
  fi

  # Case: LINK does not exist, TARGET exists
  if [[ -e "$target" ]]; then
    mkdir -p "$(dirname "$link")"
    ln -s "$target" "$link"
    log_info "[RELINKED] $dir -> $target"
    return 0
  fi

  # Case: neither exists
  mkdir -p "$target"
  mkdir -p "$(dirname "$link")"
  ln -s "$target" "$link"
  log_info "[CREATED] $dir -> $target"
}

EXIT_CODE=0
for d in "${DIRS[@]}"; do
  if ! process_dir "$d"; then
    EXIT_CODE=1
  fi
done

exit "$EXIT_CODE"
