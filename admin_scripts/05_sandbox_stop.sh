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

log_info "Stopping sandbox '$NAME'"
sbx stop "$NAME" || die "sbx stop failed for sandbox '$NAME'"
log_info "Sandbox '$NAME' stopped. Ports are released; re-published on next start/shell/run."
