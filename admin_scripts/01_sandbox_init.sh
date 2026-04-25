#!/usr/bin/env bash
set -euo pipefail

# Probe 1 note (auto-sourcing of /etc/sandbox-persistent.sh):
#   The stock Docker Sandbox templates (claude, codex, etc.) source
#   /etc/sandbox-persistent.sh from their entrypoint / shell init so vars
#   injected there are available in both `sbx exec` and `sbx run`. If this
#   assumption breaks on your version of sbx, the bottom of this script
#   contains a commented-out bashrc hook you can enable.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
PROJECT_ROOT="$(resolve_project_root)"
export PROJECT_ROOT
load_env

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [SANDBOX_NAME] [SANDBOX_AGENT] [AGENT_MACHINE_DIR]

Positional args override .env values. Missing values fall back to .env.
Missing in both exits with this message.

Examples:
  $(basename "$0")
  $(basename "$0") my-project
  $(basename "$0") my-project claude ./agent_machine
EOF
}

# Parse positional args — CLI wins over .env
NAME="${1:-${SANDBOX_NAME:-}}"
AGENT="${2:-${SANDBOX_AGENT:-}}"
AM_DIR="${3:-${AGENT_MACHINE_DIR:-}}"

[[ -z "$NAME"   ]] && { usage; die "SANDBOX_NAME not provided (arg 1 or .env)"; }
[[ -z "$AGENT"  ]] && { usage; die "SANDBOX_AGENT not provided (arg 2 or .env)"; }
[[ -z "$AM_DIR" ]] && { usage; die "AGENT_MACHINE_DIR not provided (arg 3 or .env)"; }

# Resolve AGENT_MACHINE_DIR — may be relative to project root
if [[ "$AM_DIR" != /* ]]; then
  AM_DIR="$PROJECT_ROOT/$AM_DIR"
fi
AM_DIR="$(realpath "$AM_DIR" 2>/dev/null)" || \
  die "AGENT_MACHINE_DIR does not exist on host: ${3:-${AGENT_MACHINE_DIR:-}}"
[[ -d "$AM_DIR" ]] || die "AGENT_MACHINE_DIR is not a directory: $AM_DIR"

ABS_WD="$AM_DIR/working_directory"
ABS_SCRIPTS="$AM_DIR/scripts"
ABS_HOME_MOUNTS="$AM_DIR/home_mounts"

ensure_dir "$ABS_WD"
ensure_dir "$ABS_SCRIPTS"
ensure_dir "$ABS_HOME_MOUNTS"

validate_sbx_installed

# Refuse to silently clobber an existing sandbox
if sbx ls 2>/dev/null | awk '{print $1}' | grep -qx "$NAME"; then
  die "sandbox $NAME already exists; use 06_sandbox_remove.sh first"
fi

log_info "Creating sandbox '$NAME' with agent '$AGENT'"
log_info "  working_directory: $ABS_WD"
log_info "  scripts          : $ABS_SCRIPTS"
log_info "  home_mounts      : $ABS_HOME_MOUNTS"

sbx create --name "$NAME" "$AGENT" "$ABS_WD" "$ABS_SCRIPTS" "$ABS_HOME_MOUNTS" || \
  die "sbx create failed for sandbox '$NAME'"

log_info "Sandbox '$NAME' created."
log_info "Configuring sandbox '$NAME' ..."

# Inject the four standard env vars into /etc/sandbox-persistent.sh.
# Single-quoted heredoc delimiter 'ENVEOF' disables shell expansion inside the
# heredoc body on the sandbox side, but we still want host-s expansion of
# our variables, so we use double-escaped interior quoting.
log_info "Injecting sandbox env vars into /etc/sandbox-persistent.sh"
SANDBOX_HOME_MOUNT_DIRS_VAL="${SANDBOX_HOME_MOUNT_DIRS:-}"

# 1) Path exports: unquoted heredoc so host-side $ABS_* expand.
sbx exec "$NAME" bash -c "cat >> /etc/sandbox-persistent.sh <<ENVEOF
export SANDBOX_WORKING_DIRECTORY_FOLDER_PATH=\"$ABS_WD\"
export SANDBOX_SCRIPTS_FOLDER_PATH=\"$ABS_SCRIPTS\"
export SANDBOX_HOME_MOUNT_FOLDER_PATH=\"$ABS_HOME_MOUNTS\"
export SANDBOX_HOME_MOUNT_DIRS=\"$SANDBOX_HOME_MOUNT_DIRS_VAL\"
ENVEOF" || die "Failed to inject sandbox env vars"

# 2) Terminal fixups: single-quoted heredoc so nothing on host or sandbox
#    expands — the body is written to the file verbatim.
sbx exec "$NAME" bash -c "cat >> /etc/sandbox-persistent.sh <<'ENVEOF'
: \"\${TERM:=xterm-256color}\"
export TERM
# Re-probe terminal size each prompt (sbx exec pty may miss SIGWINCH).
# Moves cursor to (9999,9999), terminal clamps to its real max, then queries
# cursor position and pushes that size back into stty.
if [[ \$- == *i* ]] && [[ -t 0 ]]; then
  __sbx_fix_winsize() {
    local IFS='[;' rows cols _
    read -t 0.2 -rsdR -p \$'\\e[s\\e[9999;9999H\\e[6n\\e[u' _ rows cols 2>/dev/null || return 0
    [[ \$cols =~ ^[0-9]+\$ ]] && [[ \$rows =~ ^[0-9]+\$ ]] && stty cols \"\$cols\" rows \"\$rows\" 2>/dev/null
  }
  PROMPT_COMMAND=\"__sbx_fix_winsize\${PROMPT_COMMAND:+; \$PROMPT_COMMAND}\"
  shopt -s checkwinsize 2>/dev/null || true
fi
ENVEOF" || die "Failed to inject terminal fixups"

# Inject any additional env vars from .env that are not in the reserved set.
RESERVED_KEYS=(
  "SANDBOX_NAME"
  "SANDBOX_AGENT"
  "AGENT_MACHINE_DIR"
  "SANDBOX_HOME_MOUNT_DIRS"
  "SANDBOX_PORTS"
)

is_reserved() {
  local k="$1" r
  for r in "${RESERVED_KEYS[@]}"; do
    [[ "$k" == "$r" ]] && return 0
  done
  return 1
}

ENV_FILE="$PROJECT_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  EXTRA_LINES=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"

    [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] && continue
    is_reserved "$key" && continue

    # Strip surrounding quotes if present
    if [[ "$val" =~ ^\"(.*)\"[[:space:]]*$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^\'(.*)\'[[:space:]]*$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi

    EXTRA_LINES+="export $key=\"$val\"
"
  done < "$ENV_FILE"

  if [[ -n "$EXTRA_LINES" ]]; then
    log_info "Injecting additional env vars from .env"
    sbx exec "$NAME" bash -c "cat >> /etc/sandbox-persistent.sh <<ENVEOF
$EXTRA_LINES
ENVEOF" || die "Failed to inject additional env vars"
  fi
fi

# Wire up home directory symlinks inside the sandbox
log_info "Creating home directory symlinks inside sandbox"
sbx exec "$NAME" bash -lc "$ABS_SCRIPTS/create_home_symlinks.sh" || \
  die "create_home_symlinks.sh failed inside sandbox"


log_info "Sandbox '$NAME' configured."

log_info "Sandbox '$NAME' created and configured."
log_info " Run: ./admin_scripts/02_sandbox_shell.sh $NAME"
log_info " Run: ./admin_scripts/03_sandbox_run.sh $NAME"

# If Probe 1 shows /etc/sandbox-persistent.sh is NOT auto-sourced by the
# template you are using, uncomment the hook below:
#
# sbx exec -d "$NAME" bash -c \
#   "grep -q 'sandbox-persistent' /etc/bash.bashrc || \
#    echo 'source /etc/sandbox-persistent.sh' >> /etc/bash.bashrc"
