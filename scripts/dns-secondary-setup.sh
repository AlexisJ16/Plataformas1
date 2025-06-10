#!/bin/bash
set -eux

echo "--- Configuring DNS Secondary ---"
PRIMARY_DNS_IPV4="192.168.56.10"
PRIMARY_DNS_IPV6="fd00:cafe:beef::10"

sudo apt-get update -y
sudo apt-get install -y bind9 bind9utils bind9-doc

sudo cp /vagrant/configs/dns-secondary/named.conf.options /etc/bind/
sudo cp /vagrant/configs/dns-secondary/named.conf.local /etc/bind/

# Update resolv.conf to use itself (once synced) then primary, then public
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV4}" | sudo tee -a /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV6}" | sudo tee -a /etc/resolv.conf
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf # Fallback

sudo named-checkconf

# Firewall
sudo ufw allow 53/tcp comment 'DNS TCP'
sudo ufw allow 53/udp comment 'DNS UDP'
sudo ufw reload

# Usar 'named.service' directamente
sudo systemctl restart named.service
sudo systemctl enable named.service
sudo systemctl status named.service

echo "--- DNS Secondary Configured ---"
echo "Check /var/log/syslog or BIND logs for successful zone transfer from primary."