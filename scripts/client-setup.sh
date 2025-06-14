#!/bin/bash
set -eux

echo "--- Provisioning Client Machine ---"

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -y
sudo apt-get install -y thunderbird net-tools dnsutils

echo "--- Client Provisioning Complete ---"
