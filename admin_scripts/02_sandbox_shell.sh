#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
PROJECT_ROOT="$(resolve_project_root)"
export PROJECT_ROOT
load_env

NAME="${1:-${SANDBOX_NAME:-}}"
[[ -z "$NAME" ]] && die "SANDBOX_NAME not provided (arg 1 or .env)"

validate_sbx_installed
validate_sandbox_exists "$NAME"
validate_sandbox_env_vars "$NAME"
ensure_ports_published "$NAME"

# `sbx exec -it` allocates a PTY but does not propagate the host terminal
# size, so readline wraps at column 80 on wide terminals. Forward the host
# stty size and apply it inside the sandbox before bash starts.
HOST_LINES=24
HOST_COLS=80
if [[ -r /dev/tty ]]; then
  read -r HOST_LINES HOST_COLS < <(stty size </dev/tty 2>/dev/null) || true
fi

exec sbx exec -it \
  -e TERM="${TERM:-xterm-256color}" \
  -e HOST_LINES="$HOST_LINES" \
  -e HOST_COLS="$HOST_COLS" \
  "$NAME" bash -c 'stty rows "$HOST_LINES" cols "$HOST_COLS" 2>/dev/null; shopt -s checkwinsize; exec bash'
