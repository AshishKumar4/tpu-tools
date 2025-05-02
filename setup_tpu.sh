#!/bin/bash

# Check the Miniconda site for the *absolute latest* URL
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh 
chmod +x Miniconda3-latest-Linux-x86_64.sh
./Miniconda3-latest-Linux-x86_64.sh -b -p $HOME/miniconda3

conda create --name flaxdiff python=3.11
conda init
conda activate flaxdiff

# # Install JAX and Flax
pip install jax[tpu]==0.5.3 flax[all] -f https://storage.googleapis.com/jax-releases/libtpu_releases.html

pip install --pre torch torchvision --index-url https://download.pytorch.org/whl/nightly/cpu

pip install 'torch_xla[tpu] @ https://storage.googleapis.com/pytorch-xla-releases/wheels/tpuvm/torch_xla-2.7.0.dev-cp311-cp311-linux_x86_64.whl' \
  -f https://storage.googleapis.com/libtpu-releases/index.html \
  -f https://storage.googleapis.com/libtpu-wheels/index.html
  
# Install CPU version of tensorflow
pip install tensorflow[cpu] diffusers keras orbax optax clu grain augmax albumentations datasets transformers opencv-python pandas tensorflow-datasets jupyterlab python-dotenv scikit-learn termcolor wrapt wandb

pip install flaxdiff gcsfs decord video-reader-rs colorlog

# pip install -U numpy>=2.0.1

# Add the env var "TOKENIZERS_PARALLELISM=false" to the .bashrc file
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
  enable-parallel-downloads: True
  parallel-downloads-per-file: 128
  download-chunk-size-mb: 256
  max-parallel-downloads: -1
metadata-cache:
  stat-cache-max-size-mb: 4096
  ttl-secs: 60
  type-cache-max-size-mb: 4096
file-system:
  kernel-list-cache-ttl-secs: 60
  ignore-interrupts: True
cache-dir: "/tmp/gcsfuse" 
EOF
)

# Create the file and write the contents
echo "$gcsfuse_conf_content" > $gcsfuse_conf

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

$ systemctl start kresd@{1..240}.service

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
    esac
done

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