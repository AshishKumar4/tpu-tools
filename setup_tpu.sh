#!/bin/bash

# Check for --mount-gcs argument
for arg in "$@"
do
    case $arg in
        --mount-gcs=*)
        GCS_BUCKET="${arg#*=}"
        shift
        ;;
        --dev)
        DEV_MODE=true
        shift
        ;;
        --install-knot)
        INSTALL_KNOT=true
        shift
        ;;
    esac
done

# Install miniconda
mkdir -p ~/miniconda3
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda3/miniconda.sh
bash ~/miniconda3/miniconda.sh -b -u -p ~/miniconda3
rm ~/miniconda3/miniconda.sh
source ~/miniconda3/bin/activate
conda init --all

# Accept conda TOS (required for newer conda versions)
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true

# Create a new conda environment
conda create -n flaxdiff python=3.12 -y

# Activate using full path (conda activate fails in non-interactive shells)
export PATH=$HOME/miniconda3/envs/flaxdiff/bin:$HOME/miniconda3/bin:$PATH
export CONDA_DEFAULT_ENV=flaxdiff

# Verify we're using the right Python
echo "Python: $(which python) ($(python --version 2>&1))"

# Install JAX and Flax
pip install jax[tpu]==0.5.3 flax[all] -f https://storage.googleapis.com/jax-releases/libtpu_releases.html

pip install --pre torch torchvision --index-url https://download.pytorch.org/whl/nightly/cpu

# Install CPU version of tensorflow
# Pin transformers and diffusers to versions compatible with Flax models
pip install tensorflow[cpu] "diffusers==0.29.2" orbax optax clu grain augmax albumentations datasets "transformers==4.41.2" opencv-python pandas tensorflow-datasets jupyterlab python-dotenv scikit-learn termcolor wrapt wandb importlib_resources

pip install flaxdiff gcsfs decord video-reader-rs colorlog

# Add env vars to .bashrc for future SSH sessions
echo "export PATH=\$HOME/miniconda3/envs/flaxdiff/bin:\$HOME/miniconda3/bin:\$PATH" >> ~/.bashrc
echo "export TOKENIZERS_PARALLELISM=false" >> ~/.bashrc

ulimit -n 65535

# Increase the limits of number of open files to unlimited
# Add the limits to /etc/security/limits.conf
limits_conf="/etc/security/limits.conf"
sudo bash -c "cat <<EOF >> $limits_conf
* soft nofile unlimited
* hard nofile unlimited
EOF"

# Create a systemd override directory if it doesn't exist
systemd_override_dir="/etc/systemd/system.conf.d"
sudo mkdir -p $systemd_override_dir

# Add the limits to the systemd service configuration
systemd_limits_conf="$systemd_override_dir/99-nofile.conf"
sudo bash -c "cat <<EOF > $systemd_limits_conf
[Manager]
DefaultLimitNOFILE=infinity
EOF"

# Reload the systemd configuration
sudo systemctl daemon-reload


# Installing and setting up gcsfuse
export GCSFUSE_REPO=gcsfuse-`lsb_release -c -s`
echo "deb [signed-by=/usr/share/keyrings/cloud.google.asc] https://packages.cloud.google.com/apt $GCSFUSE_REPO main" | sudo tee /etc/apt/sources.list.d/gcsfuse.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo tee /usr/share/keyrings/cloud.google.asc
sudo apt update
sudo apt install -y gcsfuse libgl1

# Define the file name
gcsfuse_conf="$HOME/gcsfuse.yml"

# Define the contents of the file
gcsfuse_conf_content=$(cat <<EOF
file-cache:
  max-size-mb: 40960
  cache-file-for-range-read: True
metadata-cache:
  stat-cache-max-size-mb: 4096
  ttl-secs: 60
  type-cache-max-size-mb: 4096
file-system:
  kernel-list-cache-ttl-secs: 60
  ignore-interrupts: True
EOF
)

# Create the file and write the contents
echo "$gcsfuse_conf_content" > $gcsfuse_conf

if [ "$INSTALL_KNOT" = true ]; then
    wget https://secure.nic.cz/files/knot-resolver/knot-resolver-release.deb
    sudo dpkg -i knot-resolver-release.deb
    sudo apt update
    sudo apt install -y knot-resolver
    sudo sh -c 'echo `hostname -I` `hostname` >> /etc/hosts'
    sudo sh -c 'echo nameserver 127.0.0.1 > /etc/resolv.conf'

    # Backup the original resolv.conf
    sudo cp /etc/resolv.conf /etc/resolv.conf.bak

    # Define the new nameservers
    nameservers=(
      "nameserver 127.0.0.1"
      "nameserver 8.8.8.8"
      "nameserver 8.8.4.4"
      "nameserver 76.76.2.0"
      "nameserver 76.76.10.0"
      "nameserver 9.9.9.9"
      "nameserver 1.1.1.1"
      "nameserver 1.0.0.1"
    )

    # Clear the existing resolv.conf file
    sudo sh -c '> /etc/resolv.conf'

    # Add each nameserver to the resolv.conf file
    for ns in "${nameservers[@]}"; do
      sudo sh -c "echo \"$ns\" >> /etc/resolv.conf"
    done
    echo "Nameservers added to /etc/resolv.conf"

    sudo systemctl stop systemd-resolved

    sudo systemctl start kresd@{1..240}.service
fi

if [ -n "$GCS_BUCKET" ]; then
    # URL of the file to download
    FILE_URL="https://raw.githubusercontent.com/AshishKumar4/FlaxDiff/main/datasets/gcsfuse.sh"
    # Local path to save the downloaded file
    LOCAL_FILE="gcsfuse.sh"

    # Download the file
    curl -o $LOCAL_FILE $FILE_URL

    # Make the script executable
    chmod +x $LOCAL_FILE
    echo "Mounting GCS bucket: $GCS_BUCKET to $HOME/gcs_mount"
    # Run the script with the specified arguments
    ./$LOCAL_FILE DATASET_GCS_BUCKET=$GCS_BUCKET MOUNT_PATH=$HOME/gcs_mount
fi

if [ "$DEV_MODE" = true ]; then
    # Create 'research' directory in the home folder
    mkdir -p $HOME/research

    # Clone the repository into the 'research' directory
    git clone git@github.com:AshishKumar4/FlaxDiff.git $HOME/research
else
    # Download the training.py file into the home folder
    wget -O $HOME/training.py https://github.com/AshishKumar4/FlaxDiff/raw/main/training.py
fi