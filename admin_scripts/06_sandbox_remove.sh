#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
PROJECT_ROOT="$(resolve_project_root)"
export PROJECT_ROOT
load_env

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [SANDBOX_NAME] [-y|--yes]

Permanently delete a sandbox. Only host-mounted workspace files survive.
EOF
}

ASSUME_YES=0
NAME=""

# Flags accepted in any position; the first non-flag positional becomes NAME.
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; die "Unknown flag: $arg" ;;
    *)
      if [[ -z "$NAME" ]]; then
        NAME="$arg"
      else
        usage
        die "Unexpected extra argument: $arg"
      fi
      ;;
  esac
done

NAME="${NAME:-${SANDBOX_NAME:-}}"
[[ -z "$NAME" ]] && { usage; die "SANDBOX_NAME not provided (arg 1 or .env)"; }

validate_sbx_installed
validate_sandbox_exists "$NAME"

if [[ "$ASSUME_YES" -ne 1 ]]; then
  # Read from /dev/tty so piped `echo y | ...` does NOT bypass the prompt —
  # the user must deliberately type "yes" into the terminal.
  read -r -p "Remove sandbox '$NAME'? All sandbox-internal state will be lost. Type 'yes' to confirm: " confirm < /dev/tty
  [[ "$confirm" == "yes" ]] || die "Aborted."
fi

log_info "Removing sandbox '$NAME'"
sbx rm "$NAME" || die "sbx rm failed for sandbox '$NAME'"
log_info "Sandbox '$NAME' removed."
