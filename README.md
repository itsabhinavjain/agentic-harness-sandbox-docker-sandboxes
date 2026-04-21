## Objective 
- Run AI agents in microVM-based sandboxes with strong isolation from the host.
- Being able to control networks and environment 
- Many agents and skills tend to install cli tools (binaries, npm, uvx etc) and context files in the home directory, the setup allows us to track and manage the changes. 
- Persist agent configuration, skills, and plugins across `sbx rm` / recreate cycles without rebuilding custom images.
- Persist port mappings across `sbx stop` / `sbx start` cycles (which `sbx` itself does not do).
- Standardize folder layout and environment variables so lifecycle scripts are predictable and composable.

## Approaches
- Sandboxing : Docker Sandboxes run as microVMs rather than containers. Containers share the host kernel, which is adequate for many workloads but weaker isolation for agents that have `sudo`, execute arbitrary downloaded tools, and run their own Docker daemon. The microVM boundary is meaningful for the threat model of "agent executes untrusted code."
- File Management : Mounting home_mounts/ within the image and creating symlinks for specific files and directories 

## State preservation 
A sandbox has three persistence tiers:

1. **Host-mounted directories** — survive everything. Your working files live here.
2. **Sandbox-internal filesystem** — survives `sbx stop` / `sbx start`. Wiped by `sbx rm`.
3. **Home directory state bridged to host** via symlinks from `~/` into the mounted `home_mounts/` directory. This is how agent skills, credentials, and config survive `sbx rm`.

**Ports are a separate concern.** `sbx` does not persist port mappings across stops and daemon restarts. This project works around that by storing ports in `.env` as `SANDBOX_PORTS` and re-publishing them every time you invoke `02_sandbox_shell.sh`, `03_sandbox_run.sh`, or `04_sandbox_start.sh` — giving the user the illusion of persistent ports.

## Directory Structure 
```
project-root/
├── README.md                           # this file
├── USAGE.md                            # command reference and troubleshooting
├── .env                                # gitignored; real config
├── env.example                         # committed; documents .env schema
├── .gitignore                          # includes .env and .sbx/
├── admin_scripts/                      # host-side lifecycle orchestration
│   ├── _lib.sh                         # shared validators, logging, config loader
│   ├── 01_sandbox_init.sh
│   ├── 02_sandbox_shell.sh
│   ├── 03_sandbox_run.sh
│   ├── 04_sandbox_start.sh
│   ├── 05_sandbox_stop.sh
│   └── 06_sandbox_remove.sh
└── agent_machine/                      # mounted into the sandbox
    ├── working_directory/              # primary workspace; agent starts here
    ├── home_mounts/                    # persistent ~/ state (symlink targets)
    └── scripts/                        # scripts that run inside the sandbox
        ├── create_home_symlinks.sh
        └── remove_home_symlinks.sh
```

## Conventions

**Folder names are fixed.** Inside `agent_machine/`, the three subdirectories MUST be named exactly:

- `working_directory/`
- `home_mounts/`
- `scripts/`

These names are assumed by every script. The parent folder (`agent_machine/` by default) can be renamed or relocated, but the three children cannot.

**Paths mount at their host absolute paths.** `sbx` mirrors host paths inside the sandbox. If `agent_machine/` resolves to `/Users/abhinav/projects/foo/agent_machine/`, then inside the sandbox the mounts live at exactly that path. Moving the project on the host after creating a sandbox will break the mounts — you must `sbx rm` and re-create.

**Sandbox environment variables.** `01_sandbox_init.sh` injects these into `/etc/sandbox-persistent.sh` inside the sandbox, set to absolute paths:

| Variable | Points to |
|---|---|
| `SANDBOX_WORKING_DIRECTORY_FOLDER_PATH` | Mounted `working_directory/` |
| `SANDBOX_SCRIPTS_FOLDER_PATH` | Mounted `scripts/` |
| `SANDBOX_HOME_MOUNT_FOLDER_PATH` | Mounted `home_mounts/` |
| `SANDBOX_HOME_MOUNT_DIRS` | Space-separated list of `$HOME`-relative paths to symlink (e.g. `.claude .ssh`) |

**Script execution context.**
- `admin_scripts/*.sh` always run on the host from the project root.
- `agent_machine/scripts/*.sh` always run inside the sandbox, typically from `/home/agent`.

## Configuration 

The project uses a **hybrid config model**: `.env` provides defaults, CLI arguments override them.

### `.env` schema

See `env.example` for the full committed template. Key variables:

```bash
# Sandbox identity
SANDBOX_NAME=abhinav-test
SANDBOX_AGENT=claude                      # claude|codex|copilot|gemini|kiro|opencode|shell
AGENT_MACHINE_DIR=./agent_machine         # parent of working_directory/, scripts/, home_mounts/

# Home directories to persist via symlink (space-separated, relative to $HOME)
SANDBOX_HOME_MOUNT_DIRS=".claude"

# Port forwarding — re-published automatically on start/run/shell
# Format: space-separated HOST_PORT:SANDBOX_PORT pairs
SANDBOX_PORTS="8080:3000"

# Extra env vars to inject into the sandbox
# Uncomment and set as needed
# BRAVE_API_KEY=
# ANTHROPIC_API_KEY=
```

### Argument precedence

```bash
./admin_scripts/01_sandbox_init.sh                             # all from .env
./admin_scripts/01_sandbox_init.sh my-project                  # name from arg, rest from .env
./admin_scripts/01_sandbox_init.sh my-project claude ./other   # all from args
```

CLI args always win over `.env`. `.env` always wins over script defaults. If both are missing and no default exists, the script fails loudly.


## Port forwarding

`sbx` does not persist port mappings — stopping and starting a sandbox, or restarting the Docker daemon, loses all published ports. This project works around that declaratively.

**Format:** `SANDBOX_PORTS="HOST1:SANDBOX1 HOST2:SANDBOX2 ..."`

**Example:** `SANDBOX_PORTS="8080:3000 9000:9000"` — host port 8080 forwards to sandbox port 3000, and 9000 to 9000.

**When ports are published:** automatically at the end of `02_sandbox_shell.sh`, `03_sandbox_run.sh`, and `04_sandbox_start.sh`. NOT during `01_init` (nothing running yet), `05_stop`, or `06_remove`.

**Idempotence:** re-publishing an already-published port is a no-op with a log line. You can safely re-run any of these scripts.

**Critical gotcha:** services inside the sandbox MUST bind to `0.0.0.0`, not `127.0.0.1`. Most dev servers default to loopback; you'll usually need a flag like `--host 0.0.0.0` or equivalent. A port "published" to a service bound on 127.0.0.1 is silently unreachable from the host. The scripts log a reminder each time ports are published.


## Host Side Scripts 
- All scripts on the host machine runs from the project root 

### _lib.sh
Shared library sourced by every `admin_scripts/*.sh`. Provides:

- `log_info` / `log_warn` / `log_error` — prefixed, color-aware logging
- `die "message"` — log error and `exit 1`
- `load_env` — source `.env` from project root if present (silent if absent)
- `resolve_project_root` — git-aware root discovery
- `validate_sbx_installed` — aborts if `sbx` CLI missing
- `validate_sandbox_exists <name>` — aborts if named sandbox not found
- `validate_sandbox_env_vars <name>` — confirms the three `SANDBOX_*_FOLDER_PATH` vars are set AND resolve to real directories inside the sandbox

Not executable; sourced only.

### `01_sandbox_init.sh`

Create a new sandbox and configure it end-to-end.

**Usage:**
```bash
./admin_scripts/01_sandbox_init.sh [SANDBOX_NAME] [AGENT] [AGENT_MACHINE_DIR]
```

**Flow:**
1. Load `.env`; merge with CLI args (CLI wins).
2. Resolve `AGENT_MACHINE_DIR` to an absolute path via `realpath`.
3. Validate the three required subdirectories exist on host.
4. Validate `sbx` is installed and sandbox does NOT already exist.
5. Run `sbx create --name "$NAME" "$AGENT" <working_directory> <scripts> <home_mounts>`.
6. Inject the four `SANDBOX_*` env vars plus any extras from `.env` into `/etc/sandbox-persistent.sh` (single `exec` call).
7. Invoke `$SANDBOX_SCRIPTS_FOLDER_PATH/create_home_symlinks.sh` inside the sandbox to wire up the configured home dir symlinks.

Does NOT publish ports — the agent isn't running yet.

### `02_sandbox_shell.sh`

Open an interactive bash shell inside a running sandbox.

**Usage:** `./admin_scripts/02_sandbox_shell.sh [SANDBOX_NAME]`

**Flow:** Load `.env`, validate sandbox exists, validate mount env vars, `ensure_ports_published`, `exec sbx exec -it "$NAME" bash`.

#### `03_sandbox_run.sh`

Attach to the agent's interactive session.

**Usage:** `./admin_scripts/03_sandbox_run.sh [SANDBOX_NAME]`

**Flow:** Load `.env`, validate sandbox exists, validate mount env vars, `ensure_ports_published`, `exec sbx run "$NAME"`.

### `04_sandbox_start.sh`

Start a previously-stopped sandbox without attaching. Useful for CI, or when you want ports up before connecting.

**Usage:** `./admin_scripts/04_sandbox_start.sh [SANDBOX_NAME]`

**Flow:** Load `.env`, validate sandbox exists, `sbx start "$NAME"`, validate mount env vars, `ensure_ports_published`.

### `05_sandbox_stop.sh`

Pause a running sandbox. Sandbox-internal state is preserved; ports are lost (and will be republished on next start/run/shell).

**Usage:** `./admin_scripts/05_sandbox_stop.sh [SANDBOX_NAME]`

**Flow:** Load `.env`, validate sandbox exists, `sbx stop "$NAME"`.

### `06_sandbox_remove.sh`

Permanently delete a sandbox. Only host-mounted workspace files survive.

**Usage:** `./admin_scripts/06_sandbox_remove.sh [SANDBOX_NAME] [-y|--yes]`

**Flow:** Load `.env`, validate sandbox exists, prompt for confirmation (unless `-y`), `sbx rm "$NAME"`.



## Sandbox Side Scripts
- All scripts inside the sandbox runs from the home directory `/home/agent`

#### `create_home_symlinks.sh`

Migrates a directory in `$HOME` into `$SANDBOX_HOME_MOUNT_FOLDER_PATH` and replaces it with a symlink. Idempotent — safe to re-run after `sbx rm` / recreate.

**Usage:**
```bash
create_home_symlinks.sh [DIR...]
# If no args: reads space-separated SANDBOX_HOME_MOUNT_DIRS env var
# DIR must be relative to $HOME (e.g. .claude, .config/claude)
```

**Argument validation:** Absolute paths and path-traversal (`..`) rejected.

**Behavior per directory, where `LINK=$HOME/$DIR` and `TARGET=$SANDBOX_HOME_MOUNT_FOLDER_PATH/$DIR`:**

| State | Action |
|---|---|
| Neither exists | Create empty `TARGET`, symlink `LINK → TARGET` |
| `LINK` is already a symlink to `TARGET` | No-op, log "already linked" |
| `LINK` is a real dir, `TARGET` missing | Move `LINK` to `TARGET`, symlink (first-time migration) |
| `LINK` is a real dir, `TARGET` exists | Fail loudly — refuse to clobber |
| `LINK` missing, `TARGET` exists | Symlink `LINK → TARGET` (sandbox-recreation case) |

Nested paths (e.g. `.config/claude`) are supported — parent directories of `LINK` are created with `mkdir -p` as needed.

#### `remove_home_symlinks.sh`

Inverse of `create_home_symlinks.sh`. Moves content back from `home_mounts/` into `$HOME`, replacing the symlink with the real directory. The content no longer persists across sandbox recreation.

**Usage:**
```bash
remove_home_symlinks.sh [DIR...]
# Same arg handling as create_home_symlinks.sh
```

**Behavior per directory:**

| State | Action |
|---|---|
| `LINK` is a symlink to `TARGET` | Remove symlink, move `TARGET` contents to `LINK` |
| `LINK` is not a symlink | Warn and skip |
| `LINK` missing | Warn and skip |


### Common `home_mounts/` targets
Refer to [USAGE.md](USAGE.md)

## Usage 
Refer to [USAGE.md](USAGE.md)

## Notes 
https://docs.docker.com/ai/sandboxes/
- Check who is the user in the sandbox : `agent` (non-root, has `sudo`).
- `sbx` port forwarding is ephemeral. The ports would need to be published whenever we restart the sandbox. 
- `sbx` mounting 
  - The first parameter is the one which is mounted and where the agent will start  
  - The rest of the folders are mounted in the absolute path as on the host machine 
  - The volumes are mounted inside the sandbox at a location that is the absolute path on the host machine
  - Ports
    - Services inside the sandbox must bind to `0.0.0.0` to be reachables via `sbx ports`
    - Published ports are not peristent. Re-publish with `sbx ports` after each start.
  - Inside sandbox 
    - While executing :- 
      - Agent enters here : `/home/agent/workspace` (Defined in the base template by the docker team - provided as default)
    - While running :- 
      - Claude starts here (mounted) : `/Users/abhinavjain/Documents/03-Sandboxes/docker-sandboxes-microvms/test/agent_machine/working_directory`
      - Additional mounts : `/Users/abhinavjain/Documents/03-Sandboxes/docker-sandboxes-microvms/test/agent_machine/scripts`
      - Additional mounts : `/Users/abhinavjain/Documents/03-Sandboxes/docker-sandboxes-microvms/test/agent_machine/home_mounts`


## Testing and learning 
```
sbx create --name abhinav-test claude ./agent_machine/working_directory ./agent_machine/scripts ./agent_machine/home_mounts 
sbx exec -d abhinav-test bash -c "echo 'export BRAVE_API_KEY=your_key' >> /etc/sandbox-persistent.sh"
sbx exec -it abhinav-test bash
```

## Future work
- Testing
  - Testing of ports 
  - Additional files and folders in the home directory of the sandbox 
- Enhancements
  - Networking: Tailscale or subrouter integration for agent-to-agent or agent-to-private-service connectivity.
  - `sshd` inside sandboxes for richer remote editing workflows.
  - Custom templates with `home_mounts` symlinks pre-configured in the base image.

## References

- [Docker Sandboxes docs](https://docs.docker.com/ai/sandboxes/)
- [Usage guide](https://docs.docker.com/ai/sandboxes/usage/)
- [Claude Code integration](https://docs.docker.com/ai/sandboxes/agents/claude-code/)
- [Custom environments](https://docs.docker.com/ai/sandboxes/agents/custom-environments/)
