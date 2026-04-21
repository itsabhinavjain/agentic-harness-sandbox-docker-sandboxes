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
- README.md 
- USAGE.md
- .env  
- env.example
- admin_scripts/
    - 01_init.sh 
    - 02_shell.sh 
    - 03_run.sh  
    - 04_stop.sh
    - 05_remove.sh
- agent_machine/
    - workspace/ 
    - home_mounts/
    - scripts/ 
      - create_home_symlinks.sh
      - remove_home_symlinks.sh

## Scripts 
- All scripts on the host machine runs from the project root 
- All scripts inside the sandbox runs from the home directory or the user (agent)

### 01_init.sh 
./admin_scripts/01_init.sh claude abhinav-test /Users/abhinavjain/Documents/03-Sandboxes/docker-sandboxes-microvms/test/agent_machine
Parameters - 
    - Kind of sandbox
    - The name of the sandbox 
    - The main folder 

Validate the inputs 

Check if sbx etc is installed 

Check if the environment variables are set 


Create the sandbox 
sbx create --name abhinav-test claude ./agent_machine/workspace ./agent_machine/scripts ./agent_machine/home_mounts 

Setup the environment variables in sandbox 
sbx exec -d abhinav-test bash -c "echo 'export BRAVE_API_KEY=your_key' >> /etc/sandbox-persistent.sh"
sbx exec -it abhinav-test bash

Run the create_home_symlinks.sh script (For Claude)

### 02_shell.sh 
./admin_scripts/02_shell.sh abhinav-test
sbx exec -it abhinav-test bash

### 03_run.sh  
./admin_scripts/03_run.sh abhinav-test
sbx run abhinav-test

### 04_stop.sh
./admin_scripts/04_stop.sh abhinav-test
sbx stop abhinav-test

### 05_remove.sh
./admin_scripts/05_remove.sh abhinav-test
sbx rm abhinav-test 

### create_home_symlinks.sh
### remove_home_symlinks.sh

## USAGE and TROUBLESHOOTING 
- Sandbox lifecycle 
- Others
  - Creating home_mount symbolic links (agent home to home_mount) 
  - Removing home_mount symbolic links (home_mount to agent home)
  - Adding environment variables 
  - Accessing services on the host machine 
  - Accessing websites that are blocked by default 
  - Exposing services to the outside world - host machine, private network , internet 
  - Sudo work inside the sandbox 
    - `sbx exec -u root my-sandbox apt-get update`
- Creating a custom template 

## Check later 
- Might want to be able to add networking and sshd on the sandbox 

## Notes 
- Check who is the user in the sandbox
- How to run sudo commands 
  - `sbx exec -u root my-sandbox apt-get update`
- sbx Sandbox details
  - sbx network policies are global
    - `sbx policy ls`
    - `sbx policy allow network <host>`
    - `sbx policy deny network <host>`
    - `sbx policy reset`
  - sbx calling host services from within the sandbox
    - `sbx policy allow network localhost:11434`
    - `curl http://host.docker.internal:11434`
  - sbx templates 
    - claude, codex, copilot, gemini, kiro, opencode
    - shell
    - https://docs.docker.com/ai/sandboxes/agents/claude-code/
    - https://docs.docker.com/ai/sandboxes/agents/custom-environments/
  - sbx mounting 
    - The first parameter is mounted in /workspace 
    - The rest of the folders are mounted in the absolute path as on the host machine 
  - Environment variables
    - `sbx exec -d <sandbox-name> bash -c "echo 'export BRAVE_API_KEY=your_key' >> /etc/sandbox-persistent.sh"`

## Testing and learning 
sbx create --name abhinav-test claude ./agent_machine/workspace ./agent_machine/scripts ./agent_machine/home_mounts 
sbx exec -d abhinav-test bash -c "echo 'export BRAVE_API_KEY=your_key' >> /etc/sandbox-persistent.sh"
sbx exec -it abhinav-test bash


Clarification needed :- 
- inside sandbox 
  - /home/agent/workspace 
  - /Users/abhinavjain/Documents/03-Sandboxes/docker-sandboxes-microvms/test/agent_machine/workspace 
  - /Users/abhinavjain/Documents/03-Sandboxes/docker-sandboxes-microvms/test/agent_machine/scripts
  - /Users/abhinavjain/Documents/03-Sandboxes/docker-sandboxes-microvms/test/agent_machine/home_mounts
  
1) Overall checks
   1) Check how 1 and 2 are different 
   2) When the agent works, which folder is the agent running in 
   3) Is it different when we create and exec or when we spcfically just run 
2) Test the symbolic linking script 
3) Test the symbolic unlinking script 
4) Create the script admin_scripts scripts 



https://claude.ai/chat/ab7bdc5d-c0aa-426a-8855-236eb6baf64e
https://docs.docker.com/ai/sandboxes/agents/claude-code/
