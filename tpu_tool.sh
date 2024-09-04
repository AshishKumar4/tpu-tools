#!/bin/bash

# Default configurations
ACCELERATOR_TYPE="v4-8"
RUNTIME_VERSION="tpu-ubuntu2204-base"
ZONE="us-central2-b" # Default zone, change as needed
DISK_NAME="tpu-dev-disk"
DISK_MODE="read-write"
SSH_CONFIG_FILE="$HOME/.ssh/config"
GITHUB_KEY="$HOME/.ssh/tpukey"

function show_help {
    echo "TPU Tool - Simplify Google Cloud TPU VM management"
    echo "Usage: $0 [command] [args...]"
    echo "Commands:"
    echo "  create [name] [accelerator_type] [runtime_version] [--no-attach] [--spot] [--queued] Create a TPU VM with the given name"
    echo "  delete [name]                                       Delete the TPU VM with the given name"
    echo "  start [name]                                        Start the TPU VM with the given name"
    echo "  stop [name]                                         Stop the TPU VM with the given name"
    echo "  update-ssh-config [name]                            Update SSH config for the TPU VM with the given name"
    echo "  ssh [name]                                          SSH into the TPU VM with the given name with port forwarding"
    echo "  attach-disk [name] [disk]                           Attach a disk to the TPU VM with the given name"
    echo "  copy-github-key [name]                              Copy GitHub SSH key to the TPU VM with the given name"
    echo "  list                                                List all TPU VMs"
    echo "  copy [name] [source] [destination]                  Copy files from source to destination on the TPU VM"
    echo "  execute [name] [command]                            Execute a command on the TPU VM with the given name"
    echo "  setup [name]                                        Setup the TPU VM with the given name"
    echo "  help                                                Show this help message"
    echo "Arguments in brackets [] are optional."
}

function get_external_ip {
    local name=$1
    gcloud compute tpus tpu-vm describe "$name" --zone "$ZONE" --format='get(networkEndpoints[0].accessConfig.externalIp)'
}

function create_tpu {   
    local name=$1
    local accelerator_type=${2:-$ACCELERATOR_TYPE}
    local runtime_version=${3:-$RUNTIME_VERSION} 
    local no_attach_flag=false
    local spot_flag=false
    local queued=false

    shift 3
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --no-attach|-n) no_attach_flag=true ;;
            --spot|-s) spot_flag=true ;;
            --queued) queued=true ;;
            *) echo "Unknown flag: $1" ; exit 1 ;;
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


    echo "Creating TPU VM '$name' with accelerator type '$accelerator_type' and runtime version '$runtime_version' with additional args: $additional_args..."
    # echo "Additional arguments: $additional_args, no_attach_flag: $no_attach_flag"

    if [[ $no_attach_flag = true ]]; then
        echo "Creating TPU VM without attaching a disk..."
        if $create_cmd \
            --zone "$ZONE" \
            --accelerator-type "$accelerator_type" \
            $additional_args ; then
            echo "TPU VM '$name' created."
        else
            echo "Error: Failed to create TPU VM '$name'."
            exit 1
        fi
    else
        echo "Creating TPU VM with attaching a disk..."
        if  $create_cmd \
            --zone "$ZONE" \
            --accelerator-type "$accelerator_type" \
            --metadata startup-script="#! /bin/bash
              sudo mkdir -p /home/mrwhite0racle/persist
              sudo mount /dev/sdb /home/mrwhite0racle/persist
              sudo useradd -m -s /bin/bash mrwhite0racle
              echo 'mrwhite0racle ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/mrwhite0racle
              sudo chown -R mrwhite0racle:mrwhite0racle /home/mrwhite0racle/persist
              echo '/dev/sdb /home/mrwhite0racle/persist ext4 defaults 0 0' | sudo tee -a /etc/fstab" \
            --data-disk source=projects/$(gcloud config get-value project)/zones/$ZONE/disks/$DISK_NAME,mode=$DISK_MODE\
            $additional_args ; then
            echo "TPU VM '$name' created."
        else
            echo "Error: Failed to create TPU VM '$name'."
            exit 1
        fi
    fi

    # Update SSH config file
    update_ssh_config $name
    echo "TPU VM '$name' created."
    
    # Copy GitHub SSH key to the TPU VM
    copy_github_key $name
}

function setup_tpu {
    local name=$1
    local mount_gcs=$2
    local external_ip
    external_ip=$(get_external_ip "$name")

    echo "Setting up TPU VM/Pod '$name'..."

    copy $name "setup_tpu.sh" "/home/mrwhite0racle/setup_tpu.sh"
    copy $name "reset_tpu.sh" "/home/mrwhite0racle/reset_tpu.sh"
    copy $name "$HOME/.netrc"
    execute $name "chmod +x /home/mrwhite0racle/setup_tpu.sh"
    execute $name "chmod +x /home/mrwhite0racle/reset_tpu.sh"
    execute $name "/home/mrwhite0racle/setup_tpu.sh --mount-gcs=$mount_gcs"
    echo "TPU VM/Pod '$name' setup complete."
}

function reset_tpu {
    local name=$1
    local external_ip
    external_ip=$(get_external_ip "$name")

    echo "Resetting TPU VM/Pod '$name'..."

    execute $name "/home/mrwhite0racle/reset_tpu.sh"
    echo "TPU VM/Pod '$name' reset complete."
}

function update_ssh_config {
    local name=$1
    local external_ip
    external_ip=$(get_external_ip "$name")
    echo "Updating SSH config file with entry for '$name', external IP: $external_ip..."
    
    # Remove existing entry for the same TPU name
    sed -i.bak "/^Host $name$/,/^$/d" "$SSH_CONFIG_FILE"
    
    # Add new entry
    echo -e "Host $name\n  HostName $external_ip\n  IdentityFile ~/.ssh/google_compute_engine\n  User mrwhite0racle" >> "$SSH_CONFIG_FILE"
    echo "SSH config updated."
}

function ssh_tpu {
    local name=$1
    echo "SSH into TPU VM '$name' with port forwarding..."
    gcloud compute tpus tpu-vm ssh "$name" --zone "$ZONE" --ssh-flag="-4 -L 9001:localhost:9001"
}

function attach_disk {
    local name=$1
    local disk=${2:-$DISK_NAME}
    echo "Attaching disk '$disk' to TPU VM '$name'..."
    gcloud alpha compute tpus tpu-vm attach-disk "$name" --zone "$ZONE" --disk "$disk" --mode "$DISK_MODE"
    echo "Disk '$disk' attached to TPU VM '$name'."
}

function copy_github_key {
    local name=$1
    local external_ip
    external_ip=$(get_external_ip "$name")

    echo "Copying GitHub SSH key to TPU VM '$name'..."
    
    # Copy the SSH key to the TPU VM
    scp $GITHUB_KEY "$name:/home/mrwhite0racle/.ssh/id_rsa"
    scp "${GITHUB_KEY}.pub" "$name:/home/mrwhite0racle/.ssh/id_rsa.pub"

    # Add the SSH key to the SSH agent on the TPU VM
    gcloud compute tpus tpu-vm ssh "$name" --zone "$ZONE" --command "sudo chown -R mrwhite0racle:mrwhite0racle /home/mrwhite0racle/.ssh && sudo chmod 600 /home/mrwhite0racle/.ssh/id_rsa && sudo chmod 644 /home/mrwhite0racle/.ssh/id_rsa.pub && eval \$(ssh-agent -s) && ssh-add /home/mrwhite0racle/.ssh/id_rsa"
    
    echo "GitHub SSH key copied and added to the SSH agent on TPU VM '$name'."
}

function list_tpus {
    echo "Listing all TPU VMs..."
    gcloud compute tpus tpu-vm list --zone "$ZONE"
}

function start_tpu {
    local name=$1
    echo "Starting TPU VM '$name'..."
    gcloud compute tpus tpu-vm start "$name" --zone "$ZONE"
    echo "TPU VM '$name' started."
    update_ssh_config $name
}

function stop_tpu {
    local name=$1
    local external_ip
    external_ip=$(get_external_ip "$name")
    echo "Stopping TPU VM '$name'..."
    gcloud compute tpus tpu-vm stop "$name" --zone "$ZONE"
    remove_known_host $external_ip
    echo "TPU VM '$name' stopped."
}

function delete_tpu {
    local name=$1
    echo "Deleting TPU VM '$name'..."
    gcloud compute tpus tpu-vm delete "$name" --zone "$ZONE"
    echo "TPU VM '$name' deleted."
}

function copy {
    local name=$1
    local source=$2
    local destination=$3
    local external_ip=$(get_external_ip "$name")

    echo "Copying files from '$source' to '$destination' on TPU VM '$name'..."
    gcloud compute tpus tpu-vm scp $source $name:$destination --zone "$ZONE" --worker=all
    echo "Files copied."
}

function execute {
    local name=$1
    shift
    local command="$@"
    local external_ip=$(get_external_ip "$name")

    echo "Executing command '$command' on TPU VM '$name'..."
    gcloud compute tpus tpu-vm ssh $name --zone "$ZONE" --worker=all --command="$command" 
    echo "Command executed."
}

function execute_persistent {
    local name=$1
    shift
    local command="$@"
    local session_name="persistent_session"
    local log_file="/tmp/screen_output.log"

    echo "Executing command '$command' persistently on TPU VM '$name'..."
    formatted_command=$(printf "%q" "$command")
    echo "Formatted command: $formatted_command"
    gcloud compute tpus tpu-vm ssh $name --zone "$ZONE" --worker=all --command="rm -rf $log_file && touch $log_file && screen -L -Logfile $log_file -dmS $session_name bash -c $formatted_command && tail -f $log_file"
    echo "Persistent command executed. Streaming output..."
}

function fetch_output {
    local name=$1
    local session_name="persistent_session"
    local log_file="/tmp/screen_output.log"

    echo "Fetching latest output from persistent process on TPU VM '$name'..."
    gcloud compute tpus tpu-vm ssh $name --zone "$ZONE" --worker=all --command="tail -f $output_file" #screen -S $session_name -X hardcopy $output_file && cat $output_file"
    echo "Output fetched."
}

function remove_known_host {
    local external_ip=$1
    echo "Removing known host entry for '$external_ip'..."
    ssh-keygen -R "$external_ip"
    echo "Known host entry removed."
}

# Bash completion for the CLI
_tpu_tool_completions() {
    local cur prev words cword
    _init_completion || return

    local commands="create delete start stop update-ssh-config ssh attach-disk copy-github-key list help"
    local create_flags="--no-attach --spot -n -s"

    case "${prev}" in
        create)
            if [[ ${cword} -eq 3 ]]; then
                COMPREPLY=( $(compgen -W "$(gcloud alpha compute tpus queued-resources list --format='value(name)')" -- "${cur}") )
            elif [[ ${cword} -gt 3 ]]; then
                COMPREPLY=( $(compgen -W "${create_flags}" -- "${cur}") )
            fi
            return
            ;;
        delete|start|stop|ssh|update-ssh-config|copy-github-key)
            COMPREPLY=( $(compgen -W "$(gcloud compute tpus tpu-vm list --format='value(name)')" -- "${cur}") )
            return
            ;;
        attach-disk)
            if [[ ${cword} -eq 3 ]]; then
                COMPREPLY=( $(compgen -W "$(gcloud compute tpus tpu-vm list --format='value(name)')" -- "${cur}") )
            elif [[ ${cword} -eq 4 ]]; then
                COMPREPLY=( $(compgen -W "$(gcloud compute disks list --format='value(name)')" -- "${cur}") )
            fi
            return
            ;;
    esac

    if [[ ${cword} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
    fi
}

complete -F _tpu_tool_completions tpu_tool.sh

if [ $# -lt 1 ]; then
    show_help
    exit 1
fi

case $1 in
    create)
        if [ $# -lt 2 ]; then
            echo "Error: 'create' command requires a name argument."
            show_help
            exit 1
        fi
        create_tpu $2 $3 $4 "${@:5}"
        ;;
    delete)
        if [ $# -ne 2 ]; then
            echo "Error: 'delete' command requires a name argument."
            show_help
            exit 1
        fi
        delete_tpu $2
        ;;
    start)
        if [ $# -ne 2 ]; then
            echo "Error: 'start' command requires a name argument."
            show_help
            exit 1
        fi
        start_tpu $2
        ;;
    stop)
        if [ $# -ne 2 ]; then
            echo "Error: 'stop' command requires a name argument."
            show_help
            exit 1
        fi
        stop_tpu $2
        ;;
    reset)
        if [ $# -ne 2 ]; then
            echo "Error: 'reset' command requires a name argument."
            show_help
            exit 1
        fi
        reset_tpu $2
        ;;
    setup)
        if [ $# -lt 2 ]; then
            echo "Error: 'setup' command requires a name argument. ==> $@ $1, $2, $3 , ${@:5}, $#"
            show_help
            exit 1
        fi
        setup_tpu $2 $3
        ;;
    update-ssh-config)
        if [ $# -ne 2 ]; then
            echo "Error: 'update-ssh-config' command requires a name argument."
            show_help
            exit 1
        fi
        update_ssh_config $2
        ;;
    ssh)
        if [ $# -ne 2 ]; then
            echo "Error: 'ssh' command requires a name argument."
            show_help
            exit 1
        fi
        ssh_tpu $2
        ;;
    attach-disk)
        if [ $# -lt 2 ]; then
            echo "Error: 'attach-disk' command requires a name argument."
            show_help
            exit 1
        fi
        attach_disk $2 $3
        ;;
    copy-github-key)
        if [ $# -ne 2 ]; then
            echo "Error: 'copy-github-key' command requires a name argument."
            show_help
            exit 1
        fi
        copy_github_key $2
        ;;
    list)
        list_tpus
        ;;
    copy)
        if [ $# -lt 3 ]; then
            echo "Error: 'copy' command requires a name, source, and destination arguments."
            show_help
            exit 1
        fi

        copy $2 $3 $4
        ;;
    execute)
        if [ $# -lt 3 ]; then
            echo "Error: 'execute' command requires a name and command arguments."
            show_help
            exit 1
        fi

        execute $2 $3
        ;;
    execute-persistent)
        if [ $# -lt 3 ]; then
            echo "Error: 'execute-persistent' command requires a name and command arguments."
            show_help
            exit 1
        fi

        execute_persistent $2 $3
        ;;
    fetch-output)
        if [ $# -ne 2 ]; then
            echo "Error: 'fetch-output' command requires a name argument."
            show_help
            exit 1
        fi

        fetch_output $2
        ;;
    help)
        show_help
        ;;
    *)
        echo "Error: Unknown command '$1'."
        show_help
        exit 1
        ;;
esac
