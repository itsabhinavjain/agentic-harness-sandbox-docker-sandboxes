# PRD: Docker Sandbox Lifecycle Scripts

## Context

You are implementing a set of bash scripts that wrap Docker Sandboxes (`sbx`) to provide a convention-driven lifecycle for running AI coding agents in microVMs. The README in this repository describes the overall architecture and user-facing behavior. This PRD specifies the exact behavior, interface, and acceptance criteria for each script you will implement.

Read `README.md` end-to-end before writing any code. It is the source of truth for conventions (folder names, env var names, execution context). This PRD specifies how the scripts implement those conventions.

## Scope

Deliver these files:

1. `.gitignore`
2. `env.example`
3. `admin_scripts/_lib.sh`
4. `admin_scripts/01_sandbox_init.sh`
5. `admin_scripts/02_sandbox_shell.sh`
6. `admin_scripts/03_sandbox_run.sh`
7. `admin_scripts/04_sandbox_start.sh`
8. `admin_scripts/05_sandbox_stop.sh`
9. `admin_scripts/06_sandbox_remove.sh`
10. `agent_machine/scripts/create_home_symlinks.sh`
11. `agent_machine/scripts/remove_home_symlinks.sh`

Do NOT deliver:

- `USAGE.md` — will be written separately.
- `README.md` — already exists; do not modify unless explicitly instructed.
- Python rewrites — v1 is bash only.
- Custom sandbox templates — use the stock `claude` template and others provided by `sbx`.

## Global requirements for every bash script

These apply to ALL scripts in this deliverable. Do not repeat; internalize.

1. **Shebang:** `#!/usr/bin/env bash`
2. **Strict mode:** `set -euo pipefail` as the first executable line after the shebang.
3. **Line endings:** LF only. No CRLF.
4. **Executable bit:** `chmod +x` on every delivered `.sh` file except `_lib.sh`. `_lib.sh` is sourced, not executed.
5. **Shellcheck-clean:** scripts must pass `shellcheck` with no warnings at default strictness.
6. **Fail loudly:** strict-by-default. Any missing folder, unset required env var, or failed `sbx` operation must produce a specific error message and `exit 1`. No silent degradation.
7. **Argument validation first:** validate before doing any work. Never perform partial operations and then discover a problem.
8. **No interactive prompts except where explicitly specified.** Only `06_sandbox_remove.sh` prompts (and only without `-y`).
9. **Consistent logging:** use `log_info`, `log_warn`, `log_error`, `die` from `_lib.sh`. No bare `echo` for status messages.
10. **Idempotence where specified.** `create_home_symlinks.sh`, `remove_home_symlinks.sh`, and `ensure_ports_published` must be safely re-runnable.
11. **Quoting:** quote all variable expansions. Assume paths contain spaces. `"$VAR"`, never `$VAR`.
12. **No hardcoded absolute paths** except the sandbox-internal `/etc/sandbox-persistent.sh` and `/home/agent` which are sandbox conventions.
13. **No hardcoded sandbox names.** Every script that acts on a sandbox takes the name as input (CLI arg or env var).

## File-by-file specifications

### 1. `.gitignore`

Must contain at minimum:

```
.env
.sbx/
```

Add standard macOS/editor noise (`.DS_Store`, `*.swp`) at your discretion.

### 2. `env.example`

A committed template that documents every environment variable the scripts read. User copies to `.env` and fills in. Must include:

```bash
# -----------------------------------------------------------------------------
# Sandbox identity
# -----------------------------------------------------------------------------
# Default sandbox name used when no CLI arg is passed to admin_scripts
SANDBOX_NAME=my-sandbox

# Default agent template. One of: claude, codex, copilot, gemini, kiro, opencode, shell
SANDBOX_AGENT=claude

# Path to the parent folder containing working_directory/, scripts/, home_mounts/
# Relative to the project root. Will be converted to absolute via realpath at runtime.
AGENT_MACHINE_DIR=./agent_machine

# -----------------------------------------------------------------------------
# Home directory persistence
# -----------------------------------------------------------------------------
# Space-separated list of directories (relative to $HOME) to symlink from
# the sandbox's $HOME into $SANDBOX_HOME_MOUNT_FOLDER_PATH for persistence
# across sandbox recreation.
SANDBOX_HOME_MOUNT_DIRS=".claude"

# -----------------------------------------------------------------------------
# Port forwarding
# -----------------------------------------------------------------------------
# Space-separated list of port mappings, HOST_PORT:SANDBOX_PORT.
# Re-published automatically by 02_sandbox_shell.sh, 03_sandbox_run.sh, and
# 04_sandbox_start.sh because sbx does not persist port mappings across
# sandbox stops or Docker daemon restarts.
#
# IMPORTANT: services inside the sandbox MUST bind to 0.0.0.0 (not 127.0.0.1)
# to be reachable through a published port. Pass --host 0.0.0.0 or equivalent
# to your dev server.
#
# Example: SANDBOX_PORTS="8080:3000 9000:9000"
SANDBOX_PORTS=""

# -----------------------------------------------------------------------------
# Extra env vars injected into /etc/sandbox-persistent.sh inside the sandbox
# -----------------------------------------------------------------------------
# Uncomment and set as needed. These will be exported inside the sandbox.
# Any KEY=VALUE in .env that is NOT one of the SANDBOX_* vars above is
# auto-injected during 01_sandbox_init.sh.
# BRAVE_API_KEY=
# ANTHROPIC_API_KEY=
# OPENAI_API_KEY=
```

Comment generously. This file is read by humans, not scripts.

### 3. `admin_scripts/_lib.sh`

Sourced by every `admin_scripts/*.sh`. Never executed directly.

**Must provide these functions:**

#### `log_info <msg...>`
Print `[INFO] <msg>` to stderr. Use color (cyan or similar) if stderr is a TTY, plain otherwise.

#### `log_warn <msg...>`
Print `[WARN] <msg>` to stderr. Yellow if TTY.

#### `log_error <msg...>`
Print `[ERROR] <msg>` to stderr. Red if TTY.

#### `die <msg...>`
Call `log_error`, then `exit 1`.

#### `resolve_project_root`
Echo the project root to stdout. Implementation:
1. Try `git rev-parse --show-toplevel` if in a git repo.
2. Fallback: compute as the parent directory of `admin_scripts/` (use `BASH_SOURCE` / `dirname` chain).
3. `die` if neither works.

#### `load_env`
If `$PROJECT_ROOT/.env` exists, source it with safe handling of comments and blank lines. If absent, return silently (no error — hybrid config allows missing `.env`). Do NOT overwrite variables that are already set in the environment; `.env` provides defaults only. Use a helper pattern like:

```bash
while IFS='=' read -r key val; do
  [[ -z "$key" || "$key" =~ ^# ]] && continue
  if [[ -z "${!key:-}" ]]; then
    export "$key=$val"
  fi
done < <(grep -v '^\s*#' "$PROJECT_ROOT/.env" | grep -v '^\s*$')
```

Handle quoted values (single and double quotes) correctly.

#### `validate_sbx_installed`
`command -v sbx >/dev/null 2>&1 || die "sbx CLI not found on PATH. Install Docker Desktop 4.58+."`

#### `validate_sandbox_exists <n>`
Use `sbx ls` to check if the named sandbox exists. If `sbx ls` supports `--format`, prefer that. Otherwise parse output. Die with specific message if not found.

#### `validate_sandbox_env_vars <n>`
For each of the three required vars (`SANDBOX_WORKING_DIRECTORY_FOLDER_PATH`, `SANDBOX_SCRIPTS_FOLDER_PATH`, `SANDBOX_HOME_MOUNT_FOLDER_PATH`):
1. `sbx exec "$name" bash -c "echo \$VAR_NAME"` — capture value.
2. If empty, die: `"$VAR_NAME not set in sandbox $name (was init run?)"`.
3. `sbx exec "$name" test -d "$VAR_VALUE"` — die if directory does not exist in sandbox (indicates mount failure).

#### `ensure_ports_published <n>`
Read `SANDBOX_PORTS` from the environment. If empty or unset, return 0 silently (no ports configured, nothing to do).

For each mapping in `SANDBOX_PORTS`:

1. **Validate format.** Mapping must match `^[0-9]+:[0-9]+$`. Die on invalid: `"Invalid port mapping in SANDBOX_PORTS: '$mapping' (expected HOST:SANDBOX)"`.
2. **Attempt publish.** Run `sbx ports "$name" --publish "$mapping"`. Capture stdout, stderr, and exit code.
3. **Disambiguate result:**
   - If exit 0 → log `"Published $mapping"`.
   - If non-zero → run `sbx ports "$name"` and check if `$mapping` appears in the output.
     - If present → log `"Already published: $mapping"` (idempotent re-run).
     - If absent → die: `"Failed to publish port mapping: $mapping"` and include captured stderr in the error.
4. **After the loop**, if at least one mapping was processed, log exactly once:
   `log_info "Reminder: services inside the sandbox must bind to 0.0.0.0 to be reachable through published ports"`

**Implementation note:** `sbx` may evolve its `--publish` error semantics. Write this function defensively — the "attempt, then verify via ls" pattern handles any "already published" error regardless of wording.

**Convention for using `_lib.sh`:**

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
PROJECT_ROOT="$(resolve_project_root)"
load_env
```

### 4. `admin_scripts/01_sandbox_init.sh`

**Usage:**
```
01_sandbox_init.sh [SANDBOX_NAME] [SANDBOX_AGENT] [AGENT_MACHINE_DIR]
```

Positional args override `.env` values. Missing values fall back to `.env`. Missing in both → die with usage hint.

**Steps (in order):**

1. Source `_lib.sh`, `load_env`, parse positional args.
2. Merge: `NAME = ${1:-$SANDBOX_NAME}`, same for agent and dir. Die if any resolves empty.
3. Resolve `AGENT_MACHINE_DIR` to absolute path with `realpath`. Die if path doesn't exist on host.
4. Compute absolute paths: `ABS_WD="$AGENT_MACHINE_DIR/working_directory"`, same for `scripts` and `home_mounts`.
5. Validate each of the three subdirectories exists on host. Die with specific missing path if not.
6. `validate_sbx_installed`.
7. Check if a sandbox with `$NAME` already exists. If yes, die with "sandbox $NAME already exists; use 06_sandbox_remove.sh first". Do NOT silently recreate.
8. Run:
   ```bash
   sbx create --name "$NAME" "$AGENT" "$ABS_WD" "$ABS_SCRIPTS" "$ABS_HOME_MOUNTS"
   ```
   Capture exit code; die on failure.
9. Inject the four standard env vars in a single `sbx exec -d` call writing to `/etc/sandbox-persistent.sh`. Use a heredoc:
   ```bash
   sbx exec -d "$NAME" bash -c "cat >> /etc/sandbox-persistent.sh <<'ENVEOF'
   export SANDBOX_WORKING_DIRECTORY_FOLDER_PATH=$ABS_WD
   export SANDBOX_SCRIPTS_FOLDER_PATH=$ABS_SCRIPTS
   export SANDBOX_HOME_MOUNT_FOLDER_PATH=$ABS_HOME_MOUNTS
   export SANDBOX_HOME_MOUNT_DIRS=\"$SANDBOX_HOME_MOUNT_DIRS\"
   ENVEOF"
   ```
   Quoting is critical here — values are interpolated on the host but must land verbatim in the sandbox file.
10. Inject any additional env vars present in `.env` beyond the known set. Scan `.env` for lines matching `^[A-Z_][A-Z0-9_]*=` that are NOT in the reserved set (`SANDBOX_NAME`, `SANDBOX_AGENT`, `AGENT_MACHINE_DIR`, `SANDBOX_HOME_MOUNT_DIRS`, `SANDBOX_PORTS`). Append each as `export KEY=VALUE` to `/etc/sandbox-persistent.sh`. This is how users inject API keys without per-variable plumbing.
11. Invoke symlink creation inside the sandbox:
    ```bash
    sbx exec "$NAME" bash -c "$ABS_SCRIPTS/create_home_symlinks.sh"
    ```
    (The script reads `SANDBOX_HOME_MOUNT_DIRS` from the injected env.)
12. Log success with exact next-step command: `log_info "Sandbox '$NAME' ready. Run: ./admin_scripts/03_sandbox_run.sh $NAME"`.

**Do NOT:**

- Call `validate_sandbox_env_vars` at the end. Trust the injection. (Per decision: "no post-injection verification.")
- Call `ensure_ports_published`. The agent isn't running yet; nothing to connect to. Ports are published on first shell/run/start.
- Prompt for confirmation.
- Run `sbx run` at the end. Creation and attachment are separate concerns.

### 5. `admin_scripts/02_sandbox_shell.sh`

**Usage:** `02_sandbox_shell.sh [SANDBOX_NAME]`

**Steps:**

1. Source `_lib.sh`, `load_env`.
2. `NAME="${1:-${SANDBOX_NAME:-}}"`; die if empty.
3. `validate_sbx_installed`.
4. `validate_sandbox_exists "$NAME"`.
5. `validate_sandbox_env_vars "$NAME"`.
6. `ensure_ports_published "$NAME"`.
7. `exec sbx exec -it "$NAME" bash`.

The `exec` is important — replaces the shell rather than forking, so Ctrl-C and exit behave naturally.

### 6. `admin_scripts/03_sandbox_run.sh`

**Usage:** `03_sandbox_run.sh [SANDBOX_NAME]`

Same validation chain as `02`, including `ensure_ports_published`. Final command: `exec sbx run "$NAME"`.

### 7. `admin_scripts/04_sandbox_start.sh`

**Usage:** `04_sandbox_start.sh [SANDBOX_NAME]`

Start a stopped sandbox without attaching. The start is the only way to re-publish ports without also opening a shell or attaching to the agent.

**Steps:**

1. Source `_lib.sh`, `load_env`.
2. `NAME="${1:-${SANDBOX_NAME:-}}"`; die if empty.
3. `validate_sbx_installed`.
4. `validate_sandbox_exists "$NAME"`.
5. Run `sbx start "$NAME"`. Die on non-zero exit.
6. `validate_sandbox_env_vars "$NAME"` (sandbox should now be running with mounts active).
7. `ensure_ports_published "$NAME"`.
8. Log next-step hint: `log_info "Sandbox '$NAME' started. Use ./admin_scripts/02_sandbox_shell.sh or 03_sandbox_run.sh to connect."`

### 8. `admin_scripts/05_sandbox_stop.sh`

**Usage:** `05_sandbox_stop.sh [SANDBOX_NAME]`

**Steps:**

1. Source `_lib.sh`, `load_env`.
2. `NAME="${1:-${SANDBOX_NAME:-}}"`; die if empty.
3. `validate_sbx_installed`.
4. `validate_sandbox_exists "$NAME"`.
5. Skip `validate_sandbox_env_vars` and `ensure_ports_published` — stopping doesn't need mounts to be healthy, and ports are about to be torn down anyway.
6. `sbx stop "$NAME"`.

### 9. `admin_scripts/06_sandbox_remove.sh`

**Usage:** `06_sandbox_remove.sh [SANDBOX_NAME] [-y|--yes]`

**Flag parsing:** accept `-y` or `--yes` in any position. Positional arg after flag stripping is the sandbox name.

**Steps:**

1. Parse args into `NAME` and `ASSUME_YES` (boolean).
2. `NAME="${NAME:-${SANDBOX_NAME:-}}"`; die if empty.
3. `validate_sbx_installed`.
4. `validate_sandbox_exists "$NAME"`.
5. Skip `validate_sandbox_env_vars` and `ensure_ports_published` — the sandbox might be broken, which is exactly when you'd want to remove it.
6. If `!ASSUME_YES`:
   - Read from `/dev/tty` (not stdin — allows `echo y | ...` to work in pipelines but ensures we're prompting the user):
     ```bash
     read -r -p "Remove sandbox '$NAME'? All sandbox-internal state will be lost. Type 'yes' to confirm: " confirm < /dev/tty
     [[ "$confirm" == "yes" ]] || die "Aborted."
     ```
7. `sbx rm "$NAME"`.

### 10. `agent_machine/scripts/create_home_symlinks.sh`

**Context:** runs INSIDE the sandbox, as user `agent`, cwd `/home/agent` by default. Must NOT source `_lib.sh` (that's host-side). Implement minimal inline logging.

**Usage:**
```
create_home_symlinks.sh [DIR...]
```

- If args provided, use them.
- If no args, split `$SANDBOX_HOME_MOUNT_DIRS` on whitespace.
- If both empty, die with usage message.

**Required env vars inside sandbox:**
- `SANDBOX_HOME_MOUNT_FOLDER_PATH` — die if unset.
- `HOME` — standard bash variable, always set.

**Argument validation per DIR:**
1. Reject empty.
2. Reject absolute paths (starts with `/`).
3. Reject any `..` component.

**Behavior per DIR (let `LINK="$HOME/$DIR"` and `TARGET="$SANDBOX_HOME_MOUNT_FOLDER_PATH/$DIR"`):**

| Condition | Action | Log |
|---|---|---|
| `LINK` is a symlink resolving to `TARGET` | Skip | `"[OK] already linked: $DIR"` |
| `LINK` is a symlink resolving elsewhere | Die | `"$LINK is a symlink but not to $TARGET; refusing to clobber"` |
| `LINK` is a real directory, `TARGET` missing | `mkdir -p "$(dirname "$TARGET")"; mv "$LINK" "$TARGET"; ln -s "$TARGET" "$LINK"` | `"[MIGRATED] $DIR -> $TARGET"` |
| `LINK` is a real directory, `TARGET` exists | Die | `"both $LINK and $TARGET exist; cannot merge automatically"` |
| `LINK` does not exist, `TARGET` exists | `mkdir -p "$(dirname "$LINK")"; ln -s "$TARGET" "$LINK"` | `"[RELINKED] $DIR -> $TARGET"` |
| Neither exists | `mkdir -p "$TARGET"; mkdir -p "$(dirname "$LINK")"; ln -s "$TARGET" "$LINK"` | `"[CREATED] $DIR -> $TARGET"` |
| `LINK` is a regular file (not dir, not symlink) | Die | `"$LINK is a file, not a directory; refusing to clobber"` |

Support nested paths (`.config/claude` → must `mkdir -p ~/.config` before symlinking).

Exit 0 if all DIRs processed successfully (including skipped-already-linked). Exit 1 on any failure.

### 11. `agent_machine/scripts/remove_home_symlinks.sh`

**Usage:** same as `create_home_symlinks.sh`.

**Behavior per DIR:**

| Condition | Action | Log |
|---|---|---|
| `LINK` is a symlink to `TARGET` | `rm "$LINK"; mv "$TARGET" "$LINK"` | `"[UNLINKED] $DIR"` |
| `LINK` is a symlink to something else | Warn and skip | `"[SKIP] $LINK points elsewhere"` |
| `LINK` is a real dir | Warn and skip | `"[SKIP] $LINK is not a symlink"` |
| `LINK` does not exist | Warn and skip | `"[SKIP] $LINK does not exist"` |

Do NOT delete the content in `$TARGET` beyond the move — the move itself is the restoration.

## Acceptance tests

After implementation, these manual tests must pass. Write them up as a checklist in your delivery.

### Setup

```bash
cp env.example .env
# Edit .env: set SANDBOX_NAME=test-sandbox, agent=claude, leave rest as default
# Set SANDBOX_PORTS="8080:3000" for T11
mkdir -p agent_machine/{working_directory,scripts,home_mounts}
# Scripts should have been delivered into agent_machine/scripts/ already
chmod +x admin_scripts/*.sh agent_machine/scripts/*.sh
```

### T1 — Init a fresh sandbox

```bash
./admin_scripts/01_sandbox_init.sh
# Expected: sandbox 'test-sandbox' created, env vars injected, .claude symlink created.
```

Verify inside sandbox:
```bash
./admin_scripts/02_sandbox_shell.sh
# Inside:
env | grep SANDBOX_    # all four SANDBOX_ vars set to absolute paths
ls -la ~/.claude       # is a symlink pointing into home_mounts/
cd "$SANDBOX_HOME_MOUNT_FOLDER_PATH" && ls .claude  # real directory exists on host too
```

### T2 — Idempotent re-symlink

Inside sandbox:
```bash
$SANDBOX_SCRIPTS_FOLDER_PATH/create_home_symlinks.sh
# Expected: "[OK] already linked: .claude"
```

### T3 — Persistence across recreation

```bash
# Inside sandbox:
touch ~/.claude/MARKER
exit
# On host:
./admin_scripts/06_sandbox_remove.sh test-sandbox -y
./admin_scripts/01_sandbox_init.sh
./admin_scripts/02_sandbox_shell.sh
ls ~/.claude/MARKER    # must still exist
```

### T4 — Ad-hoc additional symlink

Inside sandbox:
```bash
mkdir ~/.myconfig && echo "hello" > ~/.myconfig/data.txt
$SANDBOX_SCRIPTS_FOLDER_PATH/create_home_symlinks.sh .myconfig
# Expected: "[MIGRATED] .myconfig -> ..."
readlink ~/.myconfig   # returns the mount path
cat ~/.myconfig/data.txt   # still "hello"
```

### T5 — Strict validation on missing sandbox

```bash
./admin_scripts/02_sandbox_shell.sh nonexistent-sandbox
# Expected: exits 1 with clear error "[ERROR] Sandbox 'nonexistent-sandbox' does not exist"
```

### T6 — Argument validation

```bash
# Inside sandbox
$SANDBOX_SCRIPTS_FOLDER_PATH/create_home_symlinks.sh /etc/passwd
# Expected: exits 1 with "absolute path not allowed"

$SANDBOX_SCRIPTS_FOLDER_PATH/create_home_symlinks.sh ../foo
# Expected: exits 1 with "path traversal not allowed"
```

### T7 — CLI args override .env

```bash
./admin_scripts/01_sandbox_init.sh other-name claude ./agent_machine
# Uses other-name regardless of SANDBOX_NAME in .env
./admin_scripts/06_sandbox_remove.sh other-name -y
```

### T8 — Unset mount env var detection

Simulate a broken sandbox by removing entries from `/etc/sandbox-persistent.sh` inside the sandbox, then:
```bash
./admin_scripts/02_sandbox_shell.sh test-sandbox
# Expected: exits 1 with "[ERROR] SANDBOX_WORKING_DIRECTORY_FOLDER_PATH not set in sandbox..."
```

### T9 — Shellcheck clean

```bash
shellcheck admin_scripts/*.sh agent_machine/scripts/*.sh
# No warnings.
```

### T10 — Confirmation prompt on removal

```bash
./admin_scripts/06_sandbox_remove.sh test-sandbox
# Prompt appears; typing "no" aborts; typing "yes" removes.
./admin_scripts/06_sandbox_remove.sh test-sandbox -y
# No prompt; immediate removal.
```

### T11 — Port forwarding persistence across stop/start

Requires `SANDBOX_PORTS="8080:3000"` in `.env` and a test-sandbox initialized.

```bash
# 1. Fresh init, then shell to trigger first publish
./admin_scripts/01_sandbox_init.sh
./admin_scripts/02_sandbox_shell.sh
# Inside: verify port is published
exit

# On host, check from the sbx side:
sbx ports test-sandbox    # should show 8080 -> 3000

# 2. Start a python http server inside the sandbox, bound to 0.0.0.0, on port 3000:
./admin_scripts/02_sandbox_shell.sh
# Inside:
python3 -m http.server 3000 --bind 0.0.0.0 &
exit

# 3. From host, verify reachability:
curl http://localhost:8080/   # should return a directory listing

# 4. Stop and start, verify port re-publishes automatically
./admin_scripts/05_sandbox_stop.sh
./admin_scripts/04_sandbox_start.sh
sbx ports test-sandbox    # 8080 -> 3000 should still be there
curl http://localhost:8080/   # reachable again (python server may need to be restarted inside)
```

**Also verify** `02_sandbox_shell.sh` called on an already-running sandbox with ports already published logs `"Already published: 8080:3000"` rather than failing or duplicating.

### T12 — Invalid port format rejected

```bash
# Temporarily set SANDBOX_PORTS="bogus:value" in .env
./admin_scripts/04_sandbox_start.sh
# Expected: exits 1 with "Invalid port mapping in SANDBOX_PORTS: 'bogus:value'"
```

### T13 — `04_sandbox_start.sh` on a running sandbox

```bash
./admin_scripts/04_sandbox_start.sh test-sandbox   # when already running
# Expected: sbx start may warn that it's already running; script should not crash.
# ensure_ports_published still runs idempotently and logs "Already published".
```

Decide based on `sbx start` behavior whether to pre-check the running state or just let `sbx start` handle it. Document the chosen behavior inline.

## Open questions to resolve BEFORE implementation

### Probe 1 — `/etc/sandbox-persistent.sh` auto-sourcing

Before writing `01_sandbox_init.sh`, perform this probe:

```bash
# Requires an existing sandbox:
sbx create --name probe-sandbox claude ./probe_dir_a ./probe_dir_b ./probe_dir_c
# (create dummy dirs first)
sbx exec -d probe-sandbox bash -c "echo 'export TEST_VAR=hello' >> /etc/sandbox-persistent.sh"
sbx exec -it probe-sandbox bash -c 'echo "TEST_VAR=$TEST_VAR"'
```

- If output is `TEST_VAR=hello` → `/etc/sandbox-persistent.sh` is auto-sourced. Proceed as specified.
- If output is `TEST_VAR=` → the file is NOT auto-sourced. Before leaving `01_sandbox_init.sh`, add a sourcing hook:
  ```bash
  sbx exec -d "$NAME" bash -c \
    "grep -q 'sandbox-persistent' /etc/bash.bashrc || echo 'source /etc/sandbox-persistent.sh' >> /etc/bash.bashrc"
  ```

Clean up: `sbx rm probe-sandbox -y`. Document the probe result in a comment at the top of `01_sandbox_init.sh`.

### Probe 2 — `sbx ports` semantics

Before writing `ensure_ports_published`, probe:

```bash
# Against any running sandbox:
sbx ports <sandbox> --publish 8080:3000
sbx ports <sandbox> --publish 8080:3000   # second time — what does it do?
echo "exit: $?"
sbx ports <sandbox>                        # confirm mapping state
```

Document observed behavior (does the second call succeed, warn, or fail? what's the exit code?). Adjust the `ensure_ports_published` error handling accordingly. The specified "attempt, then verify via ls" pattern should handle any case, but the code can be simpler if re-publish is natively idempotent.

Also verify what `sbx ports` output looks like programmatically — the verification step needs to parse it reliably. Prefer `--format` flags if available.

## Deliverable format

Package as a set of file contents, each clearly labeled with its target path. Do not add extraneous files, scaffolding, or explanatory prose outside of script comments. Keep script comments terse — prefer clear code over narrated code.

After delivery, provide:

1. A short summary (≤10 lines) of what was implemented.
2. The result of Probe 1 and Probe 2 described above.
3. The acceptance test checklist with each item marked pass/fail/skipped.
4. Any deviation from this PRD with justification.

## Out of scope — do not implement

- Python versions of any script.
- A master CLI that dispatches to 01–06.
- `.env` encryption or secrets management beyond plain environment variables.
- Automated setup of shellcheck or pre-commit hooks.
- `USAGE.md`.
- Any modification to `README.md`.
- Custom `sbx` templates or image builds.
- Network policy configuration (`sbx policy allow/deny`).
- Ad-hoc port forwarding beyond `SANDBOX_PORTS` (users can still call `sbx ports` directly).
- Tailscale, sshd, or any networking extensions.
- Branch-mode Git worktree support (`--branch` flag).
- Named port mappings (`SANDBOX_PORT_WEB=...`) — only flat `SANDBOX_PORTS` list for v1.
