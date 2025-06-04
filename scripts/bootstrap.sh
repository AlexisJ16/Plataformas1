#!/bin/bash
set -eux # Exit on error, print commands

IPV6_ADDRESS=$1 # e.g., fd00:cafe:beef::10
INTERFACE_NAME=$2 # e.g., eth1
HOSTNAME_FQDN=$3 # e.g., dns-primary.example.com

echo "--- Running bootstrap.sh ---"

# Set Timezone to avoid prompts
export DEBIAN_FRONTEND=noninteractive
sudo ln -fs /usr/share/zoneinfo/America/Bogota /etc/localtime
sudo apt-get update -y > /dev/null
sudo apt-get install -y tzdata > /dev/null
sudo dpkg-reconfigure --frontend noninteractive tzdata

# Update package list and upgrade
sudo apt-get update -y
# sudo apt-get upgrade -y # Puede tomar tiempo, opcional

# Install common utilities
sudo apt-get install -y vim net-tools dnsutils curl wget ca-certificates ufw software-properties-common

# Configure hostname (Vagrant ya lo hace, pero por si acaso)
# sudo hostnamectl set-hostname "$HOSTNAME_FQDN" # Redundante con Vagrant
echo "$HOSTNAME_FQDN" | sudo tee /etc/hostname
sudo sed -i "/127.0.1.1/c\127.0.1.1 $HOSTNAME_FQDN $(echo $HOSTNAME_FQDN | cut -d. -f1)" /etc/hosts


# Static IP assignment for the servers in /etc/hosts
# This helps services resolve each other before DNS is fully up, or if there's an issue
# Note: Client machines should use DNS for these, not /etc/hosts
cat <<EOF | sudo tee -a /etc/hosts
# Server IPs for project-plataformas1
192.168.56.10   dns-primary.example.com dns-primary
fd00:cafe:beef::10 dns-primary.example.com dns-primary

192.168.56.11   dns-secondary.example.com dns-secondary
fd00:cafe:beef::11 dns-secondary.example.com dns-secondary

192.168.56.12   mail.example.com mail
fd00:cafe:beef::12 mail.example.com mail

192.168.56.13   dhcp.example.com dhcp
fd00:cafe:beef::13 dhcp.example.com dhcp
EOF

# Add IPv6 address to the private network interface (eth1, or adjust if different)
echo "Assigning IPv6 ${IPV6_ADDRESS}/64 to ${INTERFACE_NAME}"
sudo ip addr add "${IPV6_ADDRESS}/64" dev "${INTERFACE_NAME}"

# Persist IPv6 address using netplan (for Ubuntu 20.04+)
# Vagrant's default netplan config for eth1 usually looks like 50-vagrant.yaml
# We need to append the IPv6 address to it.
NETPLAN_CONFIG_FILE=$(sudo ls /etc/netplan/ | grep 'vagrant.yaml' | head -n 1) # Find the vagrant netplan file
if [ -n "$NETPLAN_CONFIG_FILE" ]; then
  sudo sed -i "/${INTERFACE_NAME}:/a \ \ \ \ \ \ \ \ addresses:\n\ \ \ \ \ \ \ \ \ \ - ${IPV6_ADDRESS}/64" "/etc/netplan/${NETPLAN_CONFIG_FILE}"
  sudo netplan apply
else
  echo "Warning: Could not find Vagrant's netplan config file to persist IPv6 address for ${INTERFACE_NAME}."
  echo "Creating a new netplan config file: /etc/netplan/60-custom-ipv6.yaml"
  cat <<EOF | sudo tee /etc/netplan/60-custom-ipv6.yaml
network:
  version: 2
  ethernets:
    ${INTERFACE_NAME}:
      dhcp4: no # Assuming Vagrant sets IPv4
      addresses:
        - ${IPV6_ADDRESS}/64
EOF
  sudo netplan apply
fi

# Basic UFW setup (allow SSH)
sudo ufw allow OpenSSH
sudo ufw --force enable

echo "--- bootstrap.sh completed ---"