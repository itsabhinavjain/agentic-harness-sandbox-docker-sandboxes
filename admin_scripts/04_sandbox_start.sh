#!/usr/bin/env bash
set -euo pipefail

# Starts a stopped sandbox without attaching.
# `sbx start` on an already-running sandbox is treated as a no-op by sbx —
# we let it through rather than pre-checking state, and rely on ensure_ports_published
# to log "Already published" for the idempotent case (T13).

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

log_info "Starting sandbox '$NAME'"
sbx start "$NAME" || die "sbx start failed for sandbox '$NAME'"

validate_sandbox_env_vars "$NAME"
ensure_ports_published "$NAME"

log_info "Sandbox '$NAME' started. "
log_info " Run: ./admin_scripts/02_sandbox_shell.sh $NAME"
log_info " Run: ./admin_scripts/03_sandbox_run.sh $NAME"