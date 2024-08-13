#!/bin/bash

rm -rf /tmp/*
# Find all devices matching /dev/accel*
devices=$(ls /dev/accel* 2>/dev/null)

# Check if any devices are found
if [ -z "$devices" ]; then
  echo "No devices found matching /dev/accel*"
  exit 0
fi

# Get the list of processes using the devices
pids=$(lsof $devices | awk 'NR>1 {print $2}' | sort | uniq)

# Check if any processes are found
if [ -z "$pids" ]; then
  echo "No processes found using /dev/accel* devices"
  exit 0
fi

# Kill the processes
echo "Killing the following processes: $pids"
for pid in $pids; do
  kill -9 $pid
done

echo "Processes killed."
