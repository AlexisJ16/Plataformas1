#!/bin/bash
set -eux

echo "--- Configuring DNS Primary ---"
PRIMARY_DNS_IPV4="192.168.56.10"
PRIMARY_DNS_IPV6="fd00:cafe:beef::10"
SECONDARY_DNS_IPV4="192.168.56.11"
SECONDARY_DNS_IPV6="fd00:cafe:beef::11"
SMTP_IPV4="192.168.56.12"
SMTP_IPV6="fd00:cafe:beef::12"
DOMAIN="example.com"

sudo apt-get update -y
sudo apt-get install -y bind9 bind9utils bind9-doc

# Generate TSIG key for zone transfers (Primary and Secondary must share this)
# Store it somewhere accessible to dns-secondary setup if automated
# For this example, we'll pre-generate and put it in named.conf.local
# You would typically run: tsig-keygen -a hmac-sha256 transfer-key > /etc/bind/transfer.key
# And then include 'transfer.key' in named.conf.local
# For simplicity here, we'll hardcode a key.
TSIG_KEY_NAME="transfer-key"
TSIG_KEY_SECRET="vPhK2lMEVBEwGfdeI8too1rFH1LU7M2y11MnTXGo8oU=" # REPLACE with a real generated key

# === Prepare configuration files ===
# BIND9 uses /etc/bind/
# Copy pre-configured files from /vagrant/configs/dns-primary
sudo cp /vagrant/configs/dns-primary/named.conf.options /etc/bind/
sudo cp /vagrant/configs/dns-primary/named.conf.local /etc/bind/
sudo cp /vagrant/configs/dns-primary/db.example.com /etc/bind/
sudo cp /vagrant/configs/dns-primary/db.168.192.in-addr.arpa /etc/bind/
sudo cp /vagrant/configs/dns-primary/db.f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa /etc/bind/ # Rename this to your IPv6 reverse

# Update placeholders in zone files if necessary (e.g., serial numbers)
# For now, assume they are correct.
# The SECRET in named.conf.local for the key should match TSIG_KEY_SECRET

# Update resolv.conf to use itself and then a public resolver
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV6}" | sudo tee -a /etc/resolv.conf # If BIND listens on IPv6
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf # Fallback

# Check configuration
sudo named-checkconf
sudo named-checkzone ${DOMAIN} /etc/bind/db.${DOMAIN}
sudo named-checkzone 56.168.192.in-addr.arpa /etc/bind/db.168.192.in-addr.arpa
# Add check for IPv6 reverse zone file

# Firewall
sudo ufw allow 53/tcp comment 'DNS TCP'
sudo ufw allow 53/udp comment 'DNS UDP'
sudo ufw reload

sudo systemctl restart bind9
sudo systemctl enable bind9
sudo systemctl status bind9

echo "--- DNS Primary Configured ---"
echo "IMPORTANT: The TSIG key named '${TSIG_KEY_NAME}' with secret '${TSIG_KEY_SECRET}' must be used on the secondary DNS."