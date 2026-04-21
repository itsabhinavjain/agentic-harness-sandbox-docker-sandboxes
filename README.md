## Objective 
- Being able to run ai agents in sandboxed environments 
- Being able to control networks and environment 
- Many skills and agents can install cli tools (binaries, npm, uvx etc) and have 

## Approaches
- Sandboxing : Create a microVM based sandbox. Docker containers are easy but share the kernel which has potential security issues.
- File Management
  - Mounting home_mounts/ within the image and creating symlinks for specific files and directories 
  - Connecting to the sandbox using sshd 

## Directory Structure 
```
- README.md 
- USAGE.md
- .env  
- env.example
- admin_scripts/
    - 01_sandbox_init.sh 
    - 02_sandbox_shell.sh 
    - 03_sandbox_run.sh  
    - 04_sandbox_stop.sh
    - 05_sandbox_remove.sh
- agent_machine/
    - working_directory/ 
    - home_mounts/
    - scripts/ 
      - create_home_symlinks.sh
      - remove_home_symlinks.sh
```
## Conventions
- Agent machine folder (main folder) should have the following :  
  - `home_mounts/` `scripts/` `working_directory/` folders : The names of these folders should not be changed
- Environment variables within the sandbox 
  - `SANDBOX_SCRIPTS_FOLDER_PATH`
  - `SANDBOX_HOME_MOUNT_FOLDER_PATH`
  - `SANDBOX_WORKING_DIRECTORY_FOLDER_PATH`
- Note that the directories inside the sandbox are mounted using the absolute paths on the host machine, therefore one should be careful while changing the directory of the repo on the host machine. 

## Scripts 
- All scripts on the host machine runs from the project root 
- All scripts inside the sandbox runs from the home directory `/home/agent`

### 01_sandbox_init.sh 
#### Sample usage
`./admin_scripts/01_sandbox_init.sh claude abhinav-test ./agent_machine`
Parameters - 
    - Kind of sandbox
    - The name of the sandbox 
    - The main folder 

#### What the script does
Validate the inputs 
Check if sbx etc is installed 
Check if the environment variables are set 
Create the sandbox 
`sbx create --name abhinav-test claude ./agent_machine/working_directory ./agent_machine/scripts ./agent_machine/home_mounts `

Setup the environment variables in sandbox (Make sure that the environment variables have absolute paths)
```
sbx exec -d abhinav-test bash -c "echo 'export SANDBOX_SCRIPTS_FOLDER_PATH=your_key' >> /etc/sandbox-persistent.sh"
sbx exec -d abhinav-test bash -c "echo 'export SANDBOX_HOME_MOUNT_FOLDER_PATH=your_key' >> /etc/sandbox-persistent.sh"
sbx exec -d abhinav-test bash -c "echo 'export SANDBOX_WORKING_DIRECTORY_FOLDER_PATH=your_key' >> /etc/sandbox-persistent.sh"
```


Run the create_home_symlinks.sh script for ~/.claude

### 02_sandbox_shell.sh 
#### Sample usage
`./admin_scripts/02_sandbox_shell.sh abhinav-test`
sbx exec -it abhinav-test bash

#### What the script does
Validates if the sandbox with that name exists
Validates if the variables environment variables are set
Validates if the mount is available at the various locations mentioned in the environment variables
Executes bash  

### 03_sandbox_run.sh 
#### Sample usage 
./admin_scripts/03_sandbox_run.sh abhinav-test

#### What the script does
Validates if the sandbox with that name exists
Validates if the variables environment variables are set
Validates if the mount is available at the various locations mentioned in the environment variables
sbx run abhinav-test

### 04_sandbox_stop.sh
#### Sample usage
./admin_scripts/04_sandbox_stop.sh abhinav-test

#### What the script does
Validates if the sandbox with that name exists
Validates if the variables environment variables are set
Validates if the mount is available at the various locations mentioned in the environment variables
sbx stop abhinav-test

### 05_sandbox_remove.sh
#### Sample usage
./admin_scripts/05_sandbox_remove.sh abhinav-test

#### What the script does
Validates if the sandbox with that name exists
Validates if the variables environment variables are set
Validates if the mount is available at the various locations mentioned in the environment variables
sbx rm abhinav-test 

### create_home_symlinks.sh
#### Sample usage
Called from within the sandbox 

#### What the script does
Looks at the folder in the home directory within the sandbox. If it finds the folder, it then creates the actual folders in home_mount directory and create a symbolic link in the home directory. This will ensure that the folder is persistent between runs and also when the sandbox is removed. 

### remove_home_symlinks.sh
#### Sample usage
Called from within the sandbox 

#### What the script does
Looks at the folder in home_mount directly and move it back to the /home/agent directory. The folder will not persist in that case. 


## USAGE and TROUBLESHOOTING 
- Sandbox lifecycle 
- Others
  - Creating home_mount symbolic links (agent home to home_mount) 
  - Removing home_mount symbolic links (home_mount to agent home)
  - Adding environment variables 
    - `sbx exec -d <sandbox-name> bash -c "echo 'export BRAVE_API_KEY=your_key' >> /etc/sandbox-persistent.sh"`
  - Accessing services on the host machine 
    - `sbx policy allow network localhost:11434`
    - `curl http://host.docker.internal:11434` (From inside the sandbox)
  - Accessing websites that are blocked by default 
    - `sbx policy ls`
    - `sbx policy allow network <host>`
    - `sbx policy deny network <host>`
    - `sbx policy reset`
  - Exposing services to the outside world - host machine, private network , internet 
  - Sudo work inside the sandbox 
    - `sbx exec -u root my-sandbox apt-get update`
- Templates 
  - `claude`, `codex`, `copilot`, `gemini`, `kiro`, `opencode`
  - `shell`
  - Creating a custom template : https://docs.docker.com/ai/sandboxes/agents/custom-environments/
- Common `home_mounts/` folders
  - `.claude` : To get user level installations of skills and plugins etc 

## Notes 
https://docs.docker.com/ai/sandboxes/
- Check who is the user in the sandbox : `agent` 
- sbx mounting 
  - The first parameter is the one which is mounted and where the agent will start  
  - The rest of the folders are mounted in the absolute path as on the host machine 
  - The volumes are mounted inside the sandbox at a location that is the absolute path on the host machine
  - inside sandbox 
    - While executing :- 
      - Agent enters here : `/home/agent/workspace` (Defined in the base template - provided as default)
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

## Things to do 
1) Write symbolic linking scripts
   1) Test the symbolic linking script 
   2) Test the symbolic unlinking script 
2) Create the script admin_scripts scripts 

https://claude.ai/chat/ab7bdc5d-c0aa-426a-8855-236eb6baf64e
https://docs.docker.com/ai/sandboxes/agents/claude-code/

## Check later 
- Might want to be able to add networking (Tailscale or a subrouter) and sshd on the sandbox 
