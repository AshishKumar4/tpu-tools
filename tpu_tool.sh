#!/bin/bash

# ======================================================
# TPU Tool - A comprehensive utility for managing GCP TPU VMs
# ======================================================

# Terminal color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly UNDERLINE='\033[4m'
readonly BLINK='\033[5m'
readonly REVERSE='\033[7m'
readonly NC='\033[0m' # No Color

# Default configurations
ACCELERATOR_TYPE="v4-8"
RUNTIME_VERSION="tpu-ubuntu2204-base"
ZONE="us-central2-b" # Default zone, change as needed
DISK_NAME="tpu-dev-disk"
DISK_MODE="read-write"
SSH_CONFIG_FILE="$HOME/.ssh/config"
GITHUB_KEY="$HOME/.ssh/tpukey"
TMUX_SESSION_NAME="tpu-cluster"
SCRIPT_VERSION="1.0.0"

# ======================================================
# Helper Functions
# ======================================================

# Common argument parsing for all commands that support --zone
function parse_args {
    local zone=$ZONE
    local remaining_args=()

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --zone)
                zone="$2"
                shift 2
                ;;
            --zone=*)
                zone="${1#*=}"
                shift
                ;;
            *)
                remaining_args+=("$1")
                shift
                ;;
        esac
    done

    # If a zone was explicitly provided as a positional arg (for backwards compatibility)
    # and --zone was not used, use the positional arg
    if [[ -n "${remaining_args[1]}" && "$zone" == "$ZONE" ]]; then
        # Check if the second argument looks like a zone (not starting with --)
        if [[ "${remaining_args[1]}" != --* ]]; then
            zone="${remaining_args[1]}"
            unset remaining_args[1]
            # Reindex the array to ensure no gaps
            remaining_args=("${remaining_args[@]}")
        fi
    fi

    echo "${zone}|${remaining_args[*]}"
}

# Print a colorful header
function print_header {
    local message=$1
    local padding=$(printf '%*s' $(( (60 - ${#message}) / 2 )) "")
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}${padding}${BOLD}${MAGENTA}${message}${NC}${padding}${BOLD}${BLUE} ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Print a success message
function print_success {
    echo -e "${GREEN}✓ ${1}${NC}"
}

# Print an error message
function print_error {
    echo -e "${RED}✗ ${1}${NC}"
}

# Print a warning message
function print_warning {
    echo -e "${YELLOW}⚠ ${1}${NC}"
}

# Print an info message
function print_info {
    echo -e "${BLUE}ℹ ${1}${NC}"
}

# Show a spinner while a process is running
function show_spinner {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    local message="${2:-Processing...}"
    local position=0
    
    echo -ne "${CYAN}${message} ${NC}"
    
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        position=$(( (position + 1) % 4 ))
        local temp=${spinstr:$position:1}
        echo -ne "\r${CYAN}${message} ${BOLD}${temp}${NC}"
        sleep $delay
    done
    echo -ne "\r${CYAN}${message} ${GREEN}✓${NC}\n"
}

# Display a progress bar
function progress_bar {
    local duration=$1
    local prefix=${2:-"Progress"}
    local size=40
    local completed=0
    local step=$(( duration / size ))
    
    echo -ne "${prefix} [${DIM}"
    
    for ((i=0; i<size; i++)); do
        echo -ne " "
    done
    
    echo -ne "${NC}] 0%"
    
    for ((i=0; i<=size; i++)); do
        sleep $step
        completed=$(( i * 100 / size ))
        
        echo -ne "\r${prefix} ["
        
        for ((j=0; j<size; j++)); do
            if [ $j -lt $i ]; then
                echo -ne "${GREEN}█${NC}"
            else
                echo -ne "${DIM} ${NC}"
            fi
        done
        
        echo -ne "] ${completed}%"
    done
    
    echo -ne "\r${prefix} [${GREEN}"
    
    for ((i=0; i<size; i++)); do
        echo -ne "█"
    done
    
    echo -e "${NC}] ${GREEN}100%${NC}"
}

function show_help {
    print_header "TPU Tool v${SCRIPT_VERSION}"
    
    echo -e "${BOLD}DESCRIPTION:${NC}"
    echo -e "  A comprehensive utility to simplify Google Cloud TPU VM management"
    echo ""
    
    echo -e "${BOLD}USAGE:${NC}"
    echo -e "  $0 ${UNDERLINE}command${NC} [${UNDERLINE}arguments${NC}...]"
    echo ""
    
    echo -e "${BOLD}COMMANDS:${NC}"
    echo -e "  ${CYAN}create${NC} ${YELLOW}[name] [accelerator_type] [runtime_version] [--no-attach] [--spot] [--queued] [--zone ZONE]${NC}"
    echo -e "      Create a TPU VM with the given name"
    echo -e "  ${CYAN}delete${NC} ${YELLOW}[name]${NC}"
    echo -e "      Delete the TPU VM with the given name"
    echo -e "  ${CYAN}start${NC} ${YELLOW}[name]${NC}"
    echo -e "      Start the TPU VM with the given name"
    echo -e "  ${CYAN}stop${NC} ${YELLOW}[name]${NC}"
    echo -e "      Stop the TPU VM with the given name"
    echo -e "  ${CYAN}update-ssh-config${NC} ${YELLOW}[name]${NC}"
    echo -e "      Update SSH config for the TPU VM with the given name"
    echo -e "  ${CYAN}ssh${NC} ${YELLOW}[name]${NC}"
    echo -e "      SSH into the TPU VM with the given name with port forwarding"
    echo -e "  ${CYAN}attach-disk${NC} ${YELLOW}[name] [disk]${NC}"
    echo -e "      Attach a disk to the TPU VM with the given name"
    echo -e "  ${CYAN}copy-github-key${NC} ${YELLOW}[name]${NC}"
    echo -e "      Copy GitHub SSH key to the TPU VM with the given name"
    echo -e "  ${CYAN}list${NC}"
    echo -e "      List all TPU VMs"
    echo -e "  ${CYAN}copy${NC} ${YELLOW}[name] [source] [destination]${NC}"
    echo -e "      Copy files from source to destination on the TPU VM"
    echo -e "  ${CYAN}execute${NC} ${YELLOW}[name] [command]${NC}"
    echo -e "      Execute a command on the TPU VM with the given name"
    echo -e "  ${CYAN}setup${NC} ${YELLOW}[name]${NC}"
    echo -e "      Setup the TPU VM with the given name"
    echo -e "  ${CYAN}spawn${NC} ${YELLOW}[base_name] [count] [accelerator_type] [command] [--no-attach] [--spot] [--queued] [--zone ZONE]${NC}"
    echo -e "      Create and setup multiple TPU VMs in parallel with tmux session"
    echo -e "  ${CYAN}help${NC}"
    echo -e "      Show this help message"
    echo ""
    
    echo -e "${BOLD}EXAMPLES:${NC}"
    echo -e "  $0 ${CYAN}create${NC} ${YELLOW}my-tpu v4-8${NC}"
    echo -e "      Creates a TPU VM with name 'my-tpu' and accelerator type 'v4-8'"
    echo ""
    echo -e "  $0 ${CYAN}spawn${NC} ${YELLOW}training-cluster 4 v4-8 \"python /home/user/train.py\"${NC}"
    echo -e "      Creates 4 TPUs with names 'training-cluster-0' through 'training-cluster-3'"
    echo -e "      and runs the training script on each one"
    echo ""
    
    echo -e "${BOLD}FLAGS:${NC}"
    echo -e "  ${YELLOW}--no-attach${NC}  Do not attach a persistent disk"
    echo -e "  ${YELLOW}--spot${NC}       Create spot TPUs (lower cost, preemptible)"
    echo -e "  ${YELLOW}--queued${NC}     Use the queued resources API"
    echo -e "  ${YELLOW}--zone${NC}       Specify a zone (default: ${ZONE})"
    echo ""
}

# ======================================================
# Core Functions
# ======================================================

function get_external_ip {
    local name=$1
    local zone=${2:-$ZONE}
    gcloud compute tpus tpu-vm describe "$name" --zone "$zone" --format='get(networkEndpoints[0].accessConfig.externalIp)' 2>/dev/null
}

function create_tpu {   
    local name=$1
    local accelerator_type=${2:-$ACCELERATOR_TYPE}
    local runtime_version=${3:-$RUNTIME_VERSION} 
    local no_attach_flag=false
    local spot_flag=false
    local queued=false
    local zone=$ZONE

    shift 3
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --no-attach|-n) no_attach_flag=true ;;
            --spot|-s) spot_flag=true ;;
            --queued) queued=true ;;
            --zone) 
                zone="$2"
                shift ;;
            *) print_error "Unknown flag: $1" ; return 1 ;;
        esac
        shift
    done

    local additional_args=""
    
    local create_cmd="gcloud compute tpus tpu-vm create $name --version $runtime_version";

    if [[ $spot_flag = true ]]; then
        additional_args="--spot"
    fi

    if [[ $queued = true ]]; then
        create_cmd="gcloud compute tpus queued-resources create resource-$name --runtime-version $runtime_version --node-id $name";
    fi

    print_header "Creating TPU VM: ${name}"
    print_info "Accelerator Type: ${CYAN}${accelerator_type}${NC}"
    print_info "Runtime Version: ${CYAN}${runtime_version}${NC}"
    print_info "Zone: ${CYAN}${zone}${NC}"
    
    if [[ $spot_flag = true ]]; then
        print_info "Mode: ${YELLOW}Spot Instance${NC}"
    fi
    
    if [[ $queued = true ]]; then
        print_info "Mode: ${MAGENTA}Queued Resource${NC}"
    fi
    
    if [[ $no_attach_flag = true ]]; then
        print_info "Disk: ${RED}None${NC}"
        
        if $create_cmd \
            --zone "$zone" \
            --accelerator-type "$accelerator_type" \
            $additional_args ; then
            print_success "TPU VM '${BOLD}${name}${NC}${GREEN}' created successfully"
        else
            print_error "Failed to create TPU VM '${name}'"
            return 1
        fi
    else
        print_info "Disk: ${GREEN}${DISK_NAME}${NC} (${DISK_MODE})"
        
        if  $create_cmd \
            --zone "$zone" \
            --accelerator-type "$accelerator_type" \
            --metadata startup-script="#! /bin/bash
              sudo mkdir -p /home/$USER/persist
              sudo mount /dev/sdb /home/$USER/persist
              sudo useradd -m -s /bin/bash $USER
              echo '$USER ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/$USER
              sudo chown -R $USER:$USER /home/$USER/persist
              echo '/dev/sdb /home/$USER/persist ext4 defaults 0 0' | sudo tee -a /etc/fstab" \
            --data-disk source=projects/$(gcloud config get-value project)/zones/$zone/disks/$DISK_NAME,mode=$DISK_MODE\
            $additional_args ; then
            print_success "TPU VM '${BOLD}${name}${NC}${GREEN}' created successfully"
        else
            print_error "Failed to create TPU VM '${name}'"
            return 1
        fi
    fi

    # Update SSH config file
    update_ssh_config $name $zone

    # SSH into TPU VM Using Google's SSH to propogate the key
    gcloud compute tpus tpu-vm ssh $name --zone "$zone" --worker=all --command="echo 'SSH key added'" &>/dev/null
    
    # Copy GitHub SSH key to the TPU VM
    copy_github_key $name $zone
    
    return 0
}

function delete_tpu {
    local name=$1
    local zone=${2:-$ZONE}
    
    print_header "Deleting TPU VM: ${name}"
    print_info "Zone: ${CYAN}${zone}${NC}"
    
    if gcloud compute tpus tpu-vm delete "$name" --zone="$zone" --quiet; then
        print_success "TPU VM '${BOLD}${name}${NC}${GREEN}' deleted successfully"
        
        # Remove from SSH config
        if grep -q "Host $name" "$SSH_CONFIG_FILE"; then
            sed -i "/Host $name/,/IdentityFile/d" "$SSH_CONFIG_FILE"
            print_info "Removed ${name} from SSH config file"
        fi
    else
        print_error "Failed to delete TPU VM '${name}'"
        return 1
    fi
    
    return 0
}

function update_ssh_config {
    local name=$1
    local zone=${2:-$ZONE}
    
    print_info "Updating SSH config for TPU VM: ${CYAN}${name}${NC}"
    
    local external_ip=$(get_external_ip "$name" "$zone")
    
    if [[ -z "$external_ip" ]]; then
        print_error "Could not get external IP for ${name}"
        return 1
    fi
    
    # Create SSH config directory if it doesn't exist
    mkdir -p "$(dirname "$SSH_CONFIG_FILE")"
    touch "$SSH_CONFIG_FILE"
    
    # Check if there's already a config for this host and remove it
    if grep -q "Host $name" "$SSH_CONFIG_FILE"; then
        print_info "Updating existing SSH config for ${name}"
        sed -i "/Host $name/,/IdentityFile/d" "$SSH_CONFIG_FILE"
    else
        print_info "Adding new SSH config for ${name}"
    fi
    
    # Append the new config
    cat <<EOF >> "$SSH_CONFIG_FILE"
Host $name
    HostName $external_ip
    User $USER
    IdentityFile ~/.ssh/google_compute_engine
EOF
    
    print_success "SSH config updated for ${name} (${external_ip})"
    return 0
}

function ssh_to_tpu {
    local name=$1
    local zone=${2:-$ZONE}
    
    print_header "Connecting to TPU VM: ${name}"
    print_info "Zone: ${CYAN}${zone}${NC}"
    
    local external_ip=$(get_external_ip "$name" "$zone")
    
    if [[ -z "$external_ip" ]]; then
        print_error "Could not get external IP for ${name}"
        return 1
    fi
    
    # Update SSH config first
    update_ssh_config "$name" "$zone"
    
    print_info "Connecting to ${BOLD}${name}${NC} (${external_ip})..."
    
    # SSH with port forwarding
    ssh -A \
        -L 8888:localhost:8888 \
        -L 8889:localhost:8889 \
        -L 8890:localhost:8890 \
        -L 8891:localhost:8891 \
        -L 8892:localhost:8892 \
        -L 9090:localhost:9090 \
        -L 6006:localhost:6006 \
        -L 6007:localhost:6007 \
        -L 6008:localhost:6008 \
        -L 6009:localhost:6009 \
        -o StrictHostKeyChecking=no \
        "$name"
        
    if [[ $? -ne 0 ]]; then
        print_error "Failed to SSH into ${name}"
        return 1
    fi
    
    return 0
}

function attach_disk {
    local name=$1
    local disk_name=${2:-$DISK_NAME}
    local zone=${3:-$ZONE}
    
    print_header "Attaching Disk to TPU VM: ${name}"
    print_info "Zone: ${CYAN}${zone}${NC}"
    print_info "Disk: ${CYAN}${disk_name}${NC}"
    
    if gcloud compute tpus tpu-vm attach-disk "$name" \
        --zone="$zone" \
        --disk="projects/$(gcloud config get-value project)/zones/$zone/disks/$disk_name" \
        --mode="$DISK_MODE"; then
        print_success "Disk ${disk_name} attached to ${name} successfully"
    else
        print_error "Failed to attach disk ${disk_name} to ${name}"
        return 1
    fi
    
    return 0
}

function copy_github_key {
    local name=$1
    local zone=${2:-$ZONE}
    
    print_info "Copying GitHub SSH key to TPU VM: ${CYAN}${name}${NC}"
    
    local external_ip=$(get_external_ip "$name" "$zone")
    
    if [[ -z "$external_ip" ]]; then
        print_error "Could not get external IP for ${name}"
        return 1
    fi
    
    if [[ ! -f "$GITHUB_KEY" ]]; then
        print_warning "GitHub SSH key not found at ${GITHUB_KEY}, skipping"
        return 1
    fi
    
    # Update SSH config first
    update_ssh_config "$name" "$zone"
    
    # Create .ssh directory on TPU VM
    ssh -o StrictHostKeyChecking=no "$name" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" &>/dev/null
    
    # Copy the key
    scp -o StrictHostKeyChecking=no "$GITHUB_KEY" "$name:~/.ssh/id_ed25519" &>/dev/null
    
    if [[ $? -eq 0 ]]; then
        # Set proper permissions
        ssh -o StrictHostKeyChecking=no "$name" "chmod 600 ~/.ssh/id_ed25519" &>/dev/null
        print_success "GitHub SSH key copied to ${name}"
        
        # Add GitHub to known_hosts
        ssh -o StrictHostKeyChecking=no "$name" \
            "ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts 2>/dev/null" &>/dev/null
        
        print_info "Added GitHub to known_hosts on ${name}"
    else
        print_error "Failed to copy GitHub SSH key to ${name}"
        return 1
    fi
    
    return 0
}

function list_tpus {
    local zone=${1:-$ZONE}
    
    print_header "TPU VMs in Zone: ${zone}"
    
    echo -e "${BOLD}${UNDERLINE}ID\tNAME\tACCELERATOR\tSTATE\tIP ADDRESS${NC}"
    
    local tpu_list=$(gcloud compute tpus tpu-vm list --zone="$zone" --format="table[no-heading](id,name,acceleratorType,state,networkEndpoints[0].accessConfig.externalIp)")
    
    if [[ -z "$tpu_list" ]]; then
        print_info "No TPU VMs found in zone ${zone}"
    else
        local id name accelerator_type state ip
        
        while IFS=$'\t' read -r id name accelerator_type state ip; do
            local state_color
            
            case "$state" in
                READY) state_color="${GREEN}" ;;
                CREATING) state_color="${YELLOW}" ;;
                STOPPING|STOPPED) state_color="${BLUE}" ;;
                PREEMPTED) state_color="${MAGENTA}" ;;
                *) state_color="${RED}" ;;
            esac
            
            echo -e "${id}\t${BOLD}${name}${NC}\t${CYAN}${accelerator_type}${NC}\t${state_color}${state}${NC}\t${ip}"
        done <<< "$tpu_list"
    fi
}

function copy_to_tpu {
    local name=$1
    local source=$2
    local destination=$3
    local zone=${4:-$ZONE}
    
    print_header "Copying Files to TPU VM: ${name}"
    print_info "Source: ${CYAN}${source}${NC}"
    print_info "Destination: ${CYAN}${destination}${NC}"
    print_info "Zone: ${CYAN}${zone}${NC}"
    
    # Update SSH config first
    update_ssh_config "$name" "$zone"
    
    # Check if source exists
    if [[ ! -e "$source" ]]; then
        print_error "Source file/directory does not exist: ${source}"
        return 1
    fi
    
    # Copy the file/directory
    if [[ -d "$source" ]]; then
        # It's a directory, add the -r flag
        scp -o StrictHostKeyChecking=no -r "$source" "$name:$destination"
    else
        # It's a file
        scp -o StrictHostKeyChecking=no "$source" "$name:$destination"
    fi
    
    if [[ $? -eq 0 ]]; then
        print_success "Successfully copied ${source} to ${name}:${destination}"
    else
        print_error "Failed to copy ${source} to ${name}"
        return 1
    fi
    
    return 0
}

function execute_on_tpu {
    local name=$1
    local command=$2
    local zone=${3:-$ZONE}
    
    print_header "Executing Command on TPU VM: ${name}"
    print_info "Command: ${CYAN}${command}${NC}"
    print_info "Zone: ${CYAN}${zone}${NC}"
    
    # Update SSH config first
    update_ssh_config "$name" "$zone"
    
    # Execute the command
    print_info "Executing on ${name}..."
    
    # Display command output with a distinctive border
    echo -e "${BLUE}╭─────── Command Output ───────╮${NC}"
    ssh -o StrictHostKeyChecking=no "$name" "$command"
    local exit_code=$?
    echo -e "${BLUE}╰───────────────────────────────╯${NC}"
    
    if [[ $exit_code -eq 0 ]]; then
        print_success "Command executed successfully on ${name}"
    else
        print_error "Command execution failed on ${name} (exit code: ${exit_code})"
        return $exit_code
    fi
    
    return 0
}

function setup_tpu {
    local name=$1
    local zone=${2:-$ZONE}
    local gcs_bucket=$3
    
    print_header "Setting Up TPU VM: ${name}"
    print_info "Zone: ${CYAN}${zone}${NC}"
    
    # Update SSH config first
    update_ssh_config "$name" "$zone"
    
    # Copy setup script
    print_info "Copying setup_tpu.sh to ${name}..."
    copy_to_tpu "$name" "setup_tpu.sh" "/home/$USER/setup_tpu.sh" "$zone"
    copy_to_tpu "$name" "$HOME/.netrc" "/home/$USER/.netrc" "$zone"
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to copy setup script to ${name}"
        return 1
    fi
    
    # Make script executable
    print_info "Making script executable..."
    execute_on_tpu "$name" "chmod +x /home/$USER/setup_tpu.sh" "$zone"
    
    if [[ $? -ne 0 ]]; then
        print_error "Failed to make script executable on ${name}"
        return 1
    fi
    
    # Execute setup script
    print_info "Executing setup script on ${name}..."
    print_warning "This may take a while..."
    local cmd="/home/$USER/setup_tpu.sh --dev"
    if [[ -n "$gcs_bucket" ]]; then
        cmd="$cmd --mount-gcs=$gcs_bucket"
    fi
    execute_on_tpu "$name" "$cmd" "$zone"
    
    if [[ $? -eq 0 ]]; then
        print_success "TPU VM ${name} has been successfully set up"
    else
        print_error "Setup failed on ${name}"
        return 1
    fi
    
    return 0
}

# ======================================================
# Tmux Session Management Functions
# ======================================================

function init_tmux_session {
    local session_name=$1
    local window_name=${2:-"main"}
    
    # If session exists but needs to be killed and recreated
    if [[ -n "$FORCE_RECREATE_SESSION" ]]; then
        if tmux has-session -t "$session_name" 2>/dev/null; then
            print_warning "Force recreating session ${BOLD}${session_name}${NC}"
            tmux kill-session -t "$session_name" 2>/dev/null
        fi
    fi
    
    # Check if the session already exists
    if tmux has-session -t "$session_name" 2>/dev/null; then
        print_warning "Session ${BOLD}${session_name}${NC}${YELLOW} already exists"
        return 0
    fi
    
    # Create a new session
    if ! tmux new-session -d -s "$session_name" -n "$window_name"; then
        print_error "Failed to create tmux session: ${BOLD}${session_name}${NC}"
        return 1
    fi
    
    # Give tmux a moment to initialize the session properly
    sleep 0.5
    
    print_success "Created new tmux session: ${BOLD}${session_name}${NC}${GREEN} with window: ${BOLD}${window_name}${NC}"
    return 0
}

function create_tmux_window {
    local session_name=$1
    local window_name=$2
    
    # Check if session exists
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        print_error "Tmux session ${BOLD}${session_name}${NC} does not exist"
        return 1
    fi
    
    # Check if the window already exists
    if tmux list-windows -t "$session_name" -F "#{window_name}" 2>/dev/null | grep -q "^$window_name$"; then
        print_warning "Window ${BOLD}${window_name}${NC}${YELLOW} already exists in session ${BOLD}${session_name}${NC}"
        return 0
    fi
    
    # Create a new window
    if ! tmux new-window -t "$session_name" -n "$window_name"; then
        print_error "Failed to create window ${BOLD}${window_name}${NC} in session ${BOLD}${session_name}${NC}"
        return 1
    fi
    
    # Give tmux a moment to initialize the window
    sleep 0.2
    
    print_success "Created new window: ${BOLD}${window_name}${NC}${GREEN} in session: ${BOLD}${session_name}${NC}"
    return 0
}

function split_tmux_window {
    local session_name=$1
    local window_name=$2
    local pane_count=$3
    local layout=${4:-"tiled"}
    
    # Ensure session and window exist
    if ! tmux has-session -t "$session_name:$window_name" 2>/dev/null; then
        print_error "Window ${BOLD}${window_name}${NC} in session ${BOLD}${session_name}${NC} does not exist"
        return 1
    fi
    
    # First ensure we're in the right window
    tmux select-window -t "$session_name:$window_name"
    
    # If only one pane needed, nothing to do
    if [[ $pane_count -eq 1 ]]; then
        print_success "Only one pane needed in ${BOLD}${window_name}${NC}, skipping splits"
        return 0
    fi
    
    # Calculate splits based on pane_count
    local remaining=$((pane_count - 1))
    
    # Create the panes
    while [[ $remaining -gt 0 ]]; do
        if ! tmux split-window -t "$session_name:$window_name" -d; then
            print_warning "Failed to create all requested panes, continuing with current layout"
            break
        fi
        # Small delay between splits to avoid race conditions
        sleep 0.1
        remaining=$((remaining - 1))
    done
    
    # Apply layout
    tmux select-layout -t "$session_name:$window_name" "$layout" || true
    
    # Give tmux a moment to stabilize
    sleep 0.5
    
    print_success "Created $pane_count panes in window: ${BOLD}${window_name}${NC}${GREEN}, session: ${BOLD}${session_name}${NC}${GREEN} with layout: ${layout}"
    return 0
}

function run_in_tmux_pane {
    local session_name=$1
    local window_name=$2
    local pane_index=$3
    local command=$4
    
    # Check if the pane exists before sending keys
    if ! tmux has-session -t "$session_name:$window_name.$pane_index" 2>/dev/null; then
        print_error "Pane ${pane_index} in window ${window_name} does not exist"
        return 1
    fi
    
    # Wrap the command in error handling to catch issues
    local quoted_command=$(echo "$command" | sed 's/"/\\"/g')
    tmux send-keys -t "$session_name:$window_name.$pane_index" "$quoted_command" C-m
    
    # Brief pause to let command execute
    sleep 0.1
    
    return 0
}

function update_status_pane {
    local session_name=$1
    local window_name=$2
    local pane_index=$3
    local status_message=$4
    
    # Check if the pane exists before updating
    if ! tmux has-session -t "$session_name:$window_name.$pane_index" 2>/dev/null; then
        print_error "Status pane ${pane_index} in window ${window_name} does not exist"
        return 1
    fi
    
    # Escape double quotes in the status message
    local escaped_message=$(echo "$status_message" | sed 's/"/\\"/g')
    
    # First clear the pane to avoid clutter
    tmux send-keys -t "$session_name:$window_name.$pane_index" "clear" C-m
    sleep 0.1
    
    # Then send the message
    tmux send-keys -t "$session_name:$window_name.$pane_index" "echo -e \"$escaped_message\"" C-m
    sleep 0.1
    
    return 0
}

function get_cluster_status {
    local tpu_names=("$@")
    local zone=$ZONE  # Default to global ZONE
    local zone_param=""
    
    # Check if the last argument is a zone parameter (starts with "zone=")
    if [[ "${tpu_names[-1]}" == zone=* ]]; then
        zone="${tpu_names[-1]#zone=}"
        zone_param="zone=$zone"
        # Remove the zone parameter from the array
        unset 'tpu_names[${#tpu_names[@]}-1]'
    fi
    
    local status="${BOLD}${MAGENTA}TPU Cluster Status at $(date)${NC}\n"
    status+="${BLUE}=================================${NC}\n\n"
    
    local ready_count=0
    local creating_count=0
    local failed_count=0
    local other_count=0
    
    for tpu_name in "${tpu_names[@]}"; do
        # Pass the zone parameter explicitly
        local tpu_info=$(gcloud compute tpus tpu-vm describe "$tpu_name" --zone "$zone" --format="csv[no-heading](name,acceleratorType,state,networkEndpoints[0].accessConfig.externalIp)" 2>/dev/null)
        
        if [[ -n "$tpu_info" ]]; then
            IFS=',' read -r name accelerator_type state ip <<< "$tpu_info"
            
            local state_color
            local state_icon
            
            case "$state" in
                READY) 
                    state_color="${GREEN}"
                    state_icon="✓"
                    ((ready_count++))
                    ;;
                CREATING) 
                    state_color="${YELLOW}"
                    state_icon="⟳"
                    ((creating_count++))
                    ;;
                STOPPING|STOPPED) 
                    state_color="${BLUE}"
                    state_icon="■"
                    ((other_count++))
                    ;;
                PREEMPTED) 
                    state_color="${MAGENTA}"
                    state_icon="!"
                    ((other_count++))
                    ;;
                *) 
                    state_color="${RED}"
                    state_icon="✗"
                    ((failed_count++))
                    ;;
            esac
            
            status+="${state_color}${state_icon}${NC} ${BOLD}${name}${NC} | ${CYAN}${accelerator_type}${NC} | ${state_color}${state}${NC} | ${ip}\n"
        else
            status+="${RED}✗${NC} ${BOLD}${tpu_name}${NC} | ${DIM}unknown${NC} | ${RED}NOT_FOUND${NC} | ${DIM}N/A${NC}\n"
            ((failed_count++))
        fi
    done
    
    # Add summary
    status+="\n${BOLD}Summary:${NC} ${#tpu_names[@]} TPUs in cluster\n"
    
    if [[ $ready_count -gt 0 ]]; then
        status+="${GREEN}✓ $ready_count Ready${NC} | "
    fi
    
    if [[ $creating_count -gt 0 ]]; then
        status+="${YELLOW}⟳ $creating_count Creating${NC} | "
    fi
    
    if [[ $failed_count -gt 0 ]]; then
        status+="${RED}✗ $failed_count Failed${NC} | "
    fi
    
    if [[ $other_count -gt 0 ]]; then
        status+="${BLUE}○ $other_count Other${NC}"
    fi
    
    echo "$status"
}

# ======================================================
# Main Spawning Function
# ======================================================

function spawn_tpus {
    local base_name=$1
    local count=${2:-1}
    local accelerator_type=${3:-$ACCELERATOR_TYPE}
    local user_command=${4:-""}
    local no_attach_flag=false
    local spot_flag=false
    local queued=false
    local zone=$ZONE
    
    # Parse additional flags
    shift 4
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --no-attach|-n) no_attach_flag=true ;;
            --spot|-s) spot_flag=true ;;
            --queued) queued=true ;;
            --force-recreate) 
                FORCE_RECREATE_SESSION=true 
                ;;
            --zone) 
                zone="$2"
                shift ;;
            --zone=*)
                zone="${1#*=}"
                ;;
            *) print_error "Unknown flag: $1" ; return 1 ;;
        esac
        shift
    done
    
    # Define additional args for TPU creation
    local additional_args=""
    if [[ $no_attach_flag = true ]]; then
        additional_args="$additional_args --no-attach"
    fi
    if [[ $spot_flag = true ]]; then
        additional_args="$additional_args --spot"
    fi
    if [[ $queued = true ]]; then
        additional_args="$additional_args --queued"
    fi
    additional_args="$additional_args --zone $zone"
    
    print_header "Spawning TPU Cluster: ${base_name}"
    print_info "Number of TPUs: ${CYAN}${count}${NC}"
    print_info "Accelerator Type: ${CYAN}${accelerator_type}${NC}"
    print_info "Zone: ${CYAN}${zone}${NC}"
    
    if [[ -n "$user_command" ]]; then
        print_info "Command to execute: ${CYAN}${user_command}${NC}"
    fi
    
    # Check for dependencies
    if ! command -v tmux &> /dev/null; then
        print_error "tmux is required but not installed. Please install tmux first."
        return 1
    fi
    
    # Check for setup_tpu.sh in the current directory
    if [[ ! -f "setup_tpu.sh" ]]; then
        print_error "setup_tpu.sh not found in the current directory"
        print_warning "This file is required for TPU setup. Please ensure it exists and is executable."
        return 1
    fi
    
    # Initialize tmux session
    if ! init_tmux_session "$TMUX_SESSION_NAME"; then
        print_error "Failed to create tmux session. Try again with --force-recreate"
        print_info "You can run: $0 spawn $base_name $count $accelerator_type \"$user_command\" --force-recreate $additional_args"
        return 1
    fi
    
    # Create dashboard window for monitoring 
    if ! create_tmux_window "$TMUX_SESSION_NAME" "dashboard"; then
        print_error "Failed to create dashboard window"
        return 1
    fi
    
    # Create the dashboard layout - Split into two panes with proper error handling
    tmux select-window -t "$TMUX_SESSION_NAME:dashboard" 2>/dev/null || {
        print_error "Failed to select dashboard window"
        return 1
    }
    
    if ! tmux split-window -t "$TMUX_SESSION_NAME:dashboard" 2>/dev/null; then
        print_error "Failed to split dashboard window"
        return 1
    fi
    
    tmux select-layout -t "$TMUX_SESSION_NAME:dashboard" "even-vertical" 2>/dev/null || {
        print_warning "Failed to set dashboard layout, continuing anyway"
    }
    
    # Give tmux some time to stabilize
    sleep 0.5
    
    # Determine number of windows and panes needed
    local tpus_per_window=4  # Max 4 TPUs per window
    local window_count=$(( (count + tpus_per_window - 1) / tpus_per_window ))
    
    # Prepare arrays for TPU names and process IDs
    local tpu_names=()
    local pids=()
    
    # Create windows and panes for TPUs with proper error handling
    for ((i=0; i<window_count; i++)); do
        local window_name="tpus-$i"
        if ! create_tmux_window "$TMUX_SESSION_NAME" "$window_name"; then
            print_error "Failed to create window for TPU group $i"
            continue
        fi
        
        # Calculate number of panes for this window
        local panes_in_window=$(( i < window_count-1 ? tpus_per_window : count - i*tpus_per_window ))
        
        if ! split_tmux_window "$TMUX_SESSION_NAME" "$window_name" "$panes_in_window"; then
            print_error "Failed to create panes in window $window_name"
            continue
        fi
    done
    
    # Setup dashboard window with status pane
    run_in_tmux_pane "$TMUX_SESSION_NAME" "dashboard" "0" "echo -e '${BOLD}${MAGENTA}TPU Cluster Deployment Dashboard${NC}\n${BLUE}==================================${NC}'"
    run_in_tmux_pane "$TMUX_SESSION_NAME" "dashboard" "1" "echo -e '${BOLD}${BLUE}Cluster Status (Initializing)${NC}'"
    
    # Prepare for parallel creation
    for ((i=0; i<count; i++)); do
        local tpu_name="${base_name}-${i}"
        tpu_names+=("$tpu_name")
        local window_index=$((i / tpus_per_window))
        local pane_index=$((i % tpus_per_window))
        local window_name="tpus-$window_index"
        
        # Initialize pane with TPU name and pending status
        run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${YELLOW}⟳ Creating...${NC}'"
    done
    
    # Create initial dashboard status - using zone parameter explicitly
    local initial_status="${BOLD}${MAGENTA}TPU Cluster Status - Initializing Deployment${NC}\n"
    initial_status+="${BLUE}==================================${NC}\n\n"
    for tpu_name in "${tpu_names[@]}"; do
        initial_status+="${YELLOW}⟳${NC} ${BOLD}${tpu_name}${NC} | ${DIM}pending${NC} | ${YELLOW}CREATING${NC} | ${DIM}N/A${NC}\n"
    done
    initial_status+="\n${BOLD}Summary:${NC} ${count} TPUs will be created in zone ${zone}"
    
    update_status_pane "$TMUX_SESSION_NAME" "dashboard" "1" "$initial_status"
    
    # Setup a background job to periodically update the dashboard with cluster status
    (
        while true; do
            # Add zone parameter to the end of the tpu_names array for get_cluster_status
            local status_args=("${tpu_names[@]}" "zone=$zone")
            local cluster_status=$(get_cluster_status "${status_args[@]}")
            update_status_pane "$TMUX_SESSION_NAME" "dashboard" "1" "$cluster_status"
            sleep 30  # Update every 30 seconds
        done
    ) &
    local dashboard_pid=$!
    
    # Launch TPU creation in parallel
    for ((i=0; i<count; i++)); do
        local tpu_name="${tpu_names[$i]}"
        local window_index=$((i / tpus_per_window))
        local pane_index=$((i % tpus_per_window))
        local window_name="tpus-$window_index"
        
        # Start TPU creation in background
        (
            # Update pane to show creation in progress
            run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${YELLOW}⟳ Creating TPU...${NC}'"
            
            # Verbose logging for easier debugging
            local tpu_log="/tmp/tpu_create_${tpu_name}.log"
            echo "Starting creation of TPU ${tpu_name} at $(date)" > "$tpu_log"
            
            # Create the TPU with error handling
            if create_tpu "$tpu_name" "$accelerator_type" "$RUNTIME_VERSION" $additional_args >> "$tpu_log" 2>&1; then
                echo "Successfully created TPU ${tpu_name}" >> "$tpu_log"
                
                # Update pane to show setup in progress
                run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${GREEN}✓ TPU Created${NC}\n${YELLOW}⟳ Setting up...${NC}'"
                
                # Wait for SSH to be ready
                echo "Waiting for SSH to be ready on ${tpu_name}..." >> "$tpu_log"
                for retry in {1..10}; do
                    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "${tpu_name}" "echo SSH Ready" >> "$tpu_log" 2>&1; then
                        echo "SSH is ready on ${tpu_name}" >> "$tpu_log"
                        break
                    fi
                    echo "SSH not ready yet (attempt $retry), waiting..." >> "$tpu_log"
                    sleep 10
                done
                
                # Copy setup script to the TPU
                echo "Copying setup script to ${tpu_name}..." >> "$tpu_log"
                run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "echo 'Copying setup script...'"
                
                if ! scp -o StrictHostKeyChecking=no setup_tpu.sh "${tpu_name}:/home/$USER/setup_tpu.sh" >> "$tpu_log" 2>&1; then
                    echo "Failed to copy setup script to ${tpu_name}" >> "$tpu_log"
                    run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${GREEN}✓ TPU Created${NC}\n${RED}✗ Failed to copy setup script${NC}'"
                    continue
                fi
                
                # Make script executable
                echo "Making setup script executable on ${tpu_name}..." >> "$tpu_log"
                run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "echo 'Making setup script executable...'"
                
                if ! ssh -o StrictHostKeyChecking=no "${tpu_name}" "chmod +x /home/$USER/setup_tpu.sh" >> "$tpu_log" 2>&1; then
                    echo "Failed to make setup script executable on ${tpu_name}" >> "$tpu_log"
                    run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${GREEN}✓ TPU Created${NC}\n${RED}✗ Failed to make setup script executable${NC}'"
                    continue
                fi
                
                # Execute setup script and show output in the pane
                echo "Running setup script on ${tpu_name}..." >> "$tpu_log"
                run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${GREEN}✓ TPU Created${NC}\n${YELLOW}⟳ Running setup script...${NC}'"
                
                # Run the setup script and capture its output
                if ssh -o StrictHostKeyChecking=no "${tpu_name}" "/home/$USER/setup_tpu.sh"; then
                    echo "Setup script completed successfully on ${tpu_name}" >> "$tpu_log"
                    run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${GREEN}✓ TPU Created${NC}\n${GREEN}✓ Setup Completed${NC}'"
                    
                    # Execute user command if provided
                    if [[ -n "$user_command" ]]; then
                        echo "Executing user command on ${tpu_name}: $user_command" >> "$tpu_log"
                        run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${GREEN}✓ TPU Created${NC}\n${GREEN}✓ Setup Completed${NC}\n${YELLOW}⟳ Executing command...${NC}'"
                        
                        if ssh -o StrictHostKeyChecking=no "${tpu_name}" "$user_command" >> "$tpu_log" 2>&1; then
                            echo "User command executed successfully on ${tpu_name}" >> "$tpu_log"
                            run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${GREEN}✓ TPU Created${NC}\n${GREEN}✓ Setup Completed${NC}\n${GREEN}✓ Command Executed${NC}'"
                        else
                            echo "User command failed on ${tpu_name}" >> "$tpu_log"
                            run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${GREEN}✓ TPU Created${NC}\n${GREEN}✓ Setup Completed${NC}\n${RED}✗ Command Failed${NC}'"
                        fi
                    fi
                else
                    echo "Setup script failed on ${tpu_name}" >> "$tpu_log"
                    run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${GREEN}✓ TPU Created${NC}\n${RED}✗ Setup Failed${NC}'"
                fi
            else
                echo "Failed to create TPU ${tpu_name}" >> "$tpu_log"
                run_in_tmux_pane "$TMUX_SESSION_NAME" "$window_name" "$pane_index" "clear && echo -e '${BOLD}TPU: ${CYAN}${tpu_name}${NC}\n\n${RED}✗ Failed to create TPU${NC}'"
            fi
            
            # Log completion
            echo "Finished processing TPU ${tpu_name} at $(date)" >> "$tpu_log"
        ) &
        pids+=($!)
        
        # Brief pause between launches to avoid rate limiting
        sleep 1
    done
    
    # Update the first dashboard pane with deployment information
    run_in_tmux_pane "$TMUX_SESSION_NAME" "dashboard" "0" "clear"
    run_in_tmux_pane "$TMUX_SESSION_NAME" "dashboard" "0" "echo -e '${BOLD}${MAGENTA}TPU Cluster Deployment${NC}\n\n${GREEN}Cluster deployment initiated!${NC}\n\n${CYAN}Creating ${count} TPUs with base name ${base_name}${NC}\n\n${YELLOW}✅ Please wait while TPUs are provisioned...${NC}'"
    
    # Show the command to reconnect to this session if disconnected
    run_in_tmux_pane "$TMUX_SESSION_NAME" "dashboard" "0" "echo -e '\n${BOLD}${BLUE}To reconnect if disconnected:${NC}\n${CYAN}tmux attach -t ${TMUX_SESSION_NAME}${NC}'"
    
    # Switch to dashboard window for better visibility
    tmux select-window -t "$TMUX_SESSION_NAME:dashboard"
    
    # Attach to the tmux session
    print_info "TPU spawning initiated. Attaching to tmux session..."
    tmux attach-session -t "$TMUX_SESSION_NAME"
    
    # When the user detaches, clean up the dashboard background process
    if [[ -n "$dashboard_pid" ]]; then
        kill "$dashboard_pid" 2>/dev/null || true
    fi
    
    # Wait for all background processes to complete
    print_info "Waiting for all TPU operations to complete..."
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    print_success "TPU cluster deployment complete!"
    print_info "You can reconnect to the session with: tmux attach -t ${TMUX_SESSION_NAME}"
    
    return 0
}

# ======================================================
# Command-line processing
# ======================================================

# Display script banner
function show_banner {
    echo -e "${BOLD}${BLUE}"
    echo -e "████████╗██████╗ ██╗   ██╗    ████████╗ ██████╗  ██████╗ ██╗     "
    echo -e "╚══██╔══╝██╔══██╗██║   ██║    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     "
    echo -e "   ██║   ██████╔╝██║   ██║       ██║   ██║   ██║██║   ██║██║     "
    echo -e "   ██║   ██╔═══╝ ██║   ██║       ██║   ██║   ██║██║   ██║██║     "
    echo -e "   ██║   ██║     ╚██████╔╝       ██║   ╚██████╔╝╚██████╔╝███████╗"
    echo -e "   ╚═╝   ╚═╝      ╚═════╝        ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝"
    echo -e "${NC}"
    echo -e "${CYAN}Version ${SCRIPT_VERSION} - Simplify Google Cloud TPU VM Management${NC}"
    echo -e "${DIM}-----------------------------------------------------------${NC}"
    echo ""
}

# Check for minimal requirements
if ! command -v gcloud &> /dev/null; then
    print_error "This script requires the Google Cloud SDK (gcloud) to be installed."
    exit 1
fi

# Display the banner if not in silent mode
show_banner

# Process command-line arguments
if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

case "$1" in
    create)
        shift
        name=$1
        accelerator_type=${2:-$ACCELERATOR_TYPE}
        runtime_version=${3:-$RUNTIME_VERSION}
        
        if [[ -z "$name" ]]; then
            print_error "TPU name is required"
            show_help
            exit 1
        fi
        
        shift 3 || true
        
        create_tpu "$name" "$accelerator_type" "$runtime_version" "$@"
        ;;
    
    delete)
        shift
        name=$1
        
        if [[ -z "$name" ]]; then
            print_error "TPU name is required"
            show_help
            exit 1
        fi
        
        shift 1
        
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        delete_tpu "$name" "$zone"
        ;;
        
    start)
        shift
        name=$1
        
        if [[ -z "$name" ]]; then
            print_error "TPU name is required"
            show_help
            exit 1
        fi
        
        shift 1
        
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        # Starting TPU implementation would go here
        print_error "Start command not implemented yet"
        ;;
        
    stop)
        shift
        name=$1
        
        if [[ -z "$name" ]]; then
            print_error "TPU name is required"
            show_help
            exit 1
        fi
        
        shift 1
        
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        # Stopping TPU implementation would go here
        print_error "Stop command not implemented yet"
        ;;
        
    update-ssh-config)
        shift
        name=$1
        
        if [[ -z "$name" ]]; then
            print_error "TPU name is required"
            show_help
            exit 1
        fi
        
        shift 1
        
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        update_ssh_config "$name" "$zone"
        ;;
    
    ssh)
        shift
        name=$1
        
        if [[ -z "$name" ]]; then
            print_error "TPU name is required"
            show_help
            exit 1
        fi
        
        shift 1
        
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        ssh_to_tpu "$name" "$zone"
        ;;
        
    attach-disk)
        shift
        name=$1
        disk_name=${2:-$DISK_NAME}
        
        if [[ -z "$name" ]]; then
            print_error "TPU name is required"
            show_help
            exit 1
        fi
        
        shift 2 || true
        
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        attach_disk "$name" "$disk_name" "$zone"
        ;;
        
    copy-github-key)
        shift
        name=$1
        
        if [[ -z "$name" ]]; then
            print_error "TPU name is required"
            show_help
            exit 1
        fi
        
        shift 1
        
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        copy_github_key "$name" "$zone"
        ;;
        
    list)
        shift
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        list_tpus "$zone"
        ;;
        
    copy)
        shift
        name=$1
        source=$2
        destination=$3
        
        if [[ -z "$name" || -z "$source" || -z "$destination" ]]; then
            print_error "TPU name, source, and destination are required"
            show_help
            exit 1
        fi
        
        shift 3
        
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        copy_to_tpu "$name" "$source" "$destination" "$zone"
        ;;
        
    execute)
        shift
        name=$1
        command=$2
        
        if [[ -z "$name" || -z "$command" ]]; then
            print_error "TPU name and command are required"
            show_help
            exit 1
        fi
        
        shift 2
        
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        execute_on_tpu "$name" "$command" "$zone"
        ;;
        
    setup)
        shift
        name=$1
        
        if [[ -z "$name" ]]; then
            print_error "TPU name is required"
            show_help
            exit 1
        fi
        
        shift 1
        
        # Parse arguments, extract zone and remaining args
        parsed_args=$(parse_args "$@")
        zone=$(echo "$parsed_args" | cut -d '|' -f1)
        
        setup_tpu "$name" "$zone"
        ;;
        
    spawn)
        shift
        base_name=$1
        count=$2
        accelerator_type=${3:-$ACCELERATOR_TYPE}
        user_command=$4
        
        if [[ -z "$base_name" || -z "$count" ]]; then
            print_error "Base name and count are required"
            show_help
            exit 1
        fi
        
        # Validate count is a number
        if ! [[ "$count" =~ ^[0-9]+$ ]]; then
            print_error "Count must be a positive integer"
            exit 1
        fi

        # Check for force-recreate flag
        for arg in "$@"; do
            if [[ "$arg" == "--force-recreate" ]]; then
                FORCE_RECREATE_SESSION=true
                print_warning "Force recreate tmux session enabled"
                break
            fi
        done
        
        shift 4 || true
        spawn_tpus "$base_name" "$count" "$accelerator_type" "$user_command" "$@"
        ;;
        
    help|--help|-h)
        show_help
        ;;
        
    version|--version|-v)
        echo "TPU Tool version $SCRIPT_VERSION"
        ;;
        
    *)
        print_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac