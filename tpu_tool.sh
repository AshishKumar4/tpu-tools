#!/bin/bash

# Default configurations
ACCELERATOR_TYPE="v4-8"
RUNTIME_VERSION="tpu-ubuntu2204-base"
ZONE="us-central2-b" # Default zone, change as needed
DISK_NAME="tpu-dev-disk"
DISK_MODE="read-write"
SSH_CONFIG_FILE="$HOME/.ssh/config"
GITHUB_KEY="~/.ssh/tpukey"

function show_help {
    echo "TPU Tool - Simplify Google Cloud TPU VM management"
    echo "Usage: $0 [command] [args...]"
    echo "Commands:"
    echo "  create [name] [accelerator_type] [runtime_version] [--no-attach]  Create a TPU VM with the given name"
    echo "  delete [name]                                       Delete the TPU VM with the given name"
    echo "  ssh [name]                                          SSH into the TPU VM with the given name with port forwarding"
    echo "  attach-disk [name] [disk]                           Attach a disk to the TPU VM with the given name"
    echo "  copy-github-key [name]                              Copy GitHub SSH key to the TPU VM with the given name"
    echo "  list                                                List all TPU VMs"
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
    local no_attach_flag=$4

    echo "Creating TPU VM '$name' with accelerator type '$accelerator_type' and runtime version '$runtime_version'..."
    
    if [[ $no_attach_flag == "--no-attach" ]]; then
        gcloud compute tpus tpu-vm create "$name" \
            --zone "$ZONE" \
            --accelerator-type "$accelerator_type" \
            --version "$runtime_version"
    else
        gcloud compute tpus tpu-vm create "$name" \
            --zone "$ZONE" \
            --accelerator-type "$accelerator_type" \
            --version "$runtime_version" \
            --metadata startup-script="#! /bin/bash
              sudo mkdir -p /home/mrwhite0racle
              sudo mount /dev/sdb /home/mrwhite0racle
              sudo useradd -m -s /bin/bash mrwhite0racle
              echo 'mrwhite0racle ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/mrwhite0racle
              sudo chown -R mrwhite0racle:mrwhite0racle /home/mrwhite0racle
              echo '/dev/sdb /home/mrwhite0racle ext4 defaults 0 0' | sudo tee -a /etc/fstab" \
            --data-disk source=projects/$(gcloud config get-value project)/zones/$ZONE/disks/$DISK_NAME,mode=$DISK_MODE
    fi

    # Update SSH config file
    update_ssh_config $name
    echo "TPU VM '$name' created."
    
    # Copy GitHub SSH key to the TPU VM
    copy_github_key $name
}

function update_ssh_config {
    local name=$1
    local external_ip
    external_ip=$(get_external_ip "$name")
    echo "Updating SSH config file with entry for '$name', external IP: $external_ip..."
    
    # Remove existing entry for the same TPU name
    sed -i.bak "/^Host $name$/,/^$/d" "$SSH_CONFIG_FILE"
    
    # Add new entry
    echo -e "Host $name\n  HostName $external_ip\n  IdentityFile ~/.ssh/id_rsa\n  User mrwhite0racle" >> "$SSH_CONFIG_FILE"
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
    scp -i ~/.ssh/id_rsa $GITHUB_KEY "mrwhite0racle@$external_ip:/home/mrwhite0racle/.ssh/id_rsa"
    scp -i ~/.ssh/id_rsa "${GITHUB_KEY}.pub" "mrwhite0racle@$external_ip:/home/mrwhite0racle/.ssh/id_rsa.pub"

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

function remove_known_host {
    local external_ip=$1
    echo "Removing known host entry for '$external_ip'..."
    ssh-keygen -R "$external_ip"
    echo "Known host entry removed."
}

# Bash completion for the CLI
_tpu_tool_completions()
{
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="create delete start stop ssh attach-disk copy-github-key list help"

    if [[ ${COMP_CWORD} == 1 ]] ; then
        COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
        return 0
    fi

    if [[ ${COMP_WORDS[1]} == "create" ]] && [[ ${COMP_CWORD} == 2 ]] ; then
        COMPREPLY=( $(compgen -W "$(gcloud alpha compute tpus queued-resources list --format='value(name)')" -- ${cur}) )
        return 0
    fi

    if [[ ${COMP_WORDS[1]} == "delete" || ${COMP_WORDS[1]} == "start" || ${COMP_WORDS[1]} == "stop" || ${COMP_WORDS[1]} == "ssh" ]] && [[ ${COMP_CWORD} == 2 ]] ; then
        COMPREPLY=( $(compgen -W "$(gcloud compute tpus tpu-vm list --format='value(name)')" -- ${cur}) )
        return 0
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
        create_tpu $2 $3 $4 $5
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
    help)
        show_help
        ;;
    *)
        echo "Error: Unknown command '$1'."
        show_help
        exit 1
        ;;
esac
