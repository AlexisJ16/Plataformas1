#!/bin/bash
set -eux

echo "--- Configuring DNS Secondary ---"
PRIMARY_DOMAIN="grindavik.xyz" # Usar el nuevo dominio
PRIMARY_DNS_IPV4="192.168.56.10"
PRIMARY_DNS_IPV6="fd00:cafe:beef::10"

sudo apt-get update -y
sudo apt-get install -y bind9 bind9utils bind9-doc

sudo cp "/vagrant/configs/dns-secondary/named.conf.options" /etc/bind/
sudo cp "/vagrant/configs/dns-secondary/named.conf.local" /etc/bind/ # Este ya debe estar para grindavik.xyz

# --- Crear directorios para managed-keys y claves de zonas esclavas (aunque BIND los crea para slaves, buena práctica) ---
sudo mkdir -p "/var/cache/bind/dynamic" # Para managed-keys
sudo mkdir -p "/var/cache/bind/slaves"  # BIND usará esta por defecto para archivos de zona esclava
sudo chown -R bind:bind "/var/cache/bind/dynamic/"
sudo chown -R bind:bind "/var/cache/bind/slaves/"
sudo chmod -R 770 "/var/cache/bind/dynamic/"
sudo chmod -R 770 "/var/cache/bind/slaves/"

# Update resolv.conf
echo "search ${PRIMARY_DOMAIN}" | sudo tee /etc/resolv.conf # Añadir search domain
echo "nameserver 127.0.0.1" | sudo tee -a /etc/resolv.conf
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

echo "--- DNS Secondary Configured for ${PRIMARY_DOMAIN} ---"
echo "Check /var/log/syslog or BIND logs for successful zone transfer from primary and DNSSEC validation."