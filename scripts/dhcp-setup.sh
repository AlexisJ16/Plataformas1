#!/bin/bash
set -eux

echo "--- Configuring DHCP Server (Kea) ---"
KEA_CONF_DIR="/etc/kea"
PRIMARY_DNS_IPV4="192.168.56.10"
PRIMARY_DNS_IPV6="fd00:cafe:beef::10"
SECONDARY_DNS_IPV4="192.168.56.11"
SECONDARY_DNS_IPV6="fd00:cafe:beef::11"
DOMAIN="grindavik.xyz"

# Install Kea (may require ISC repository or compile from source depending on OS version)
# For Ubuntu 20.04+, it should be in standard repos.
# sudo add-apt-repository ppa:isc/kea -y # If older Ubuntu
sudo apt-get update -y
sudo apt-get install -y kea-dhcp4-server kea-dhcp6-server

# Create Kea configuration directory if it doesn't exist
sudo mkdir -p "$KEA_CONF_DIR"

# Copy pre-configured files
sudo cp /vagrant/configs/dhcp/kea-dhcp4.conf "$KEA_CONF_DIR/"
sudo cp /vagrant/configs/dhcp/kea-dhcp6.conf "$KEA_CONF_DIR/"

# Modify configuration files with actual IPs (optional if configs are generic enough)
sudo sed -i "s/PRIMARY_DNS_IPV4_PLACEHOLDER/${PRIMARY_DNS_IPV4}/g" "$KEA_CONF_DIR/kea-dhcp4.conf"
sudo sed -i "s/PRIMARY_DNS_IPV6_PLACEHOLDER/${PRIMARY_DNS_IPV6}/g" "$KEA_CONF_DIR/kea-dhcp4.conf"
sudo sed -i "s/SECONDARY_DNS_IPV4_PLACEHOLDER/${SECONDARY_DNS_IPV4}/g" "$KEA_CONF_DIR/kea-dhcp4.conf"
sudo sed -i "s/SECONDARY_DNS_IPV6_PLACEHOLDER/${SECONDARY_DNS_IPV6}/g" "$KEA_CONF_DIR/kea-dhcp4.conf"
sudo sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" "$KEA_CONF_DIR/kea-dhcp4.conf"

sudo sed -i "s/PRIMARY_DNS_IPV6_PLACEHOLDER/${PRIMARY_DNS_IPV6}/g" "$KEA_CONF_DIR/kea-dhcp6.conf"
sudo sed -i "s/SECONDARY_DNS_IPV6_PLACEHOLDER/${SECONDARY_DNS_IPV6}/g" "$KEA_CONF_DIR/kea-dhcp6.conf"
sudo sed -i "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" "$KEA_CONF_DIR/kea-dhcp6.conf"


# Firewall rules for DHCP
sudo ufw allow 67/udp comment 'DHCPv4 Server'
sudo ufw allow 68/udp comment 'DHCPv4 Client' # Though server typically doesn't act as client for this
sudo ufw allow 547/udp comment 'DHCPv6 Server'
sudo ufw allow 546/udp comment 'DHCPv6 Client'
sudo ufw reload

# Enable and start Kea services
# Kea needs write access to its log/lease files, ensure correct user/group if not default
sudo systemctl enable kea-dhcp4-server
sudo systemctl enable kea-dhcp6-server
sudo systemctl restart kea-dhcp4-server
sudo systemctl restart kea-dhcp6-server

sudo systemctl status kea-dhcp4-server
sudo systemctl status kea-dhcp6-server

# Update resolv.conf (DHCP server itself usually uses static DNS or local resolver)
echo "nameserver ${PRIMARY_DNS_IPV4}" | sudo tee /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV6}" | sudo tee -a /etc/resolv.conf
echo "nameserver ${SECONDARY_DNS_IPV4}" | sudo tee -a /etc/resolv.conf # Secondary DNS
echo "search ${DOMAIN}" | sudo tee -a /etc/resolv.conf


echo "--- DHCP Server (Kea) Configured ---"