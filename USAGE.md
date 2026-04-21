## USAGE and TROUBLESHOOTING 
### Sandbox lifecycle 
- Create .env file 
- Specify the name of the sandbox 
- Specify the name of the agent
- Specify the agent machine directory (Should contain `working_directory`, `scripts`, `home_mounts`)
- Specify the directories that should be mounted to `home_mounts` 
- Specify the ports that should be exposed
- Other API Keys 
- `./admin_scripts/01_sandbox_init.sh [SANDBOX_NAME] [AGENT] [AGENT_MACHINE_DIR]` : Create a sandbox 
- `./admin_scripts/02_sandbox_shell.sh [SANDBOX_NAME]` : Open an interative shell
- `./admin_scripts/03_sandbox_run.sh [SANDBOX_NAME]` : Attach to an agent session 
- `./admin_scripts/04_sandbox_start.sh [SANDBOX_NAME]` : Start a previously-stopped sandbox without attaching. Useful for CI, or when you want ports up before connecting.
- `./admin_scripts/05_sandbox_stop.sh [SANDBOX_NAME]` : Pause a running sandbox. 
- `./admin_scripts/06_sandbox_delete.sh [SANDBOX_NAME]` : Permanently delete a sandbox.

### Troubleshooting 
- Sandbox Scripts 
  - Creating home_mount symbolic links (agent home to home_mount) - within the sandbox
    - `SANDBOX_SCRIPTS_FOLDER_PATH/create_home_symlinks.sh [DIR...]`
  - Removing home_mount symbolic links (home_mount to agent home) - within the sandbox 
    - `SANDBOX_SCRIPTS_FOLDER_PATH/remove_home_symlinks.sh [DIR...]`
  - In case the scripts dont run, make sure that you have `chmod +x` the scripts in the sandbox or the host machine 
- Host scripts
  - Adding environment variables (Persists)
    - `sbx exec -d [SANDBOX_NAME] bash -c "echo 'export BRAVE_API_KEY=your_key' >> /etc/sandbox-persistent.sh"`
  - Accessing services on the host machine 
    - `sbx policy allow network localhost:11434`
    - `curl http://host.docker.internal:11434` (From inside the sandbox)
  - Accessing websites that are blocked by default 
    - `sbx policy ls`
    - `sbx policy allow network <host>`
    - `sbx policy deny network <host>`
    - `sbx policy reset`
  - Exposing services to the outside world - host machine, private network, internet - Port doesn't persist 
  - Sudo work inside the sandbox 
    - `sbx exec -u root my-sandbox apt-get update`

### Templates 
- `claude`, `codex`, `copilot`, `gemini`, `kiro`, `opencode`
- `shell`
- Creating a custom template : https://docs.docker.com/ai/sandboxes/agents/custom-environments/


### Common home directories that are mounted 
| Directory | Purpose |
|---|---|
| `.claude` | Claude Code user-level skills, plugins, agents, auth |
| `.config/claude` | Claude Code config on XDG-compliant setups |
| `.gitconfig` | User's git identity and aliases |
| `.ssh` | SSH keys for git operations |
| `.aws` | AWS CLI credentials and config |
| `.npmrc` | npm auth tokens |

Pick per project. The default in `.env` is just `.claude`.

 