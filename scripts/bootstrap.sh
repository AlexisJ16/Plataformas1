#!/bin/bash
set -eux # Exit on error, print commands

# Ahora solo esperamos 2 argumentos: IPv6 y Hostname
EXPECTED_IPV6_ADDRESS=$1 # e.g., fd00:cafe:beef::10
HOSTNAME_FQDN=$2         # e.g., ns1.grindavik.xyz
# La IP IPv4 se obtiene del entorno de la VM que configura Vagrant
PRIMARY_DOMAIN="grindavik.xyz" # Dominio principal

echo "--- Running bootstrap.sh for ${HOSTNAME_FQDN} ---"
echo "Target IPv6: ${EXPECTED_IPV6_ADDRESS}"

# Set Timezone to avoid prompts
export DEBIAN_FRONTEND=noninteractive
sudo ln -fs /usr/share/zoneinfo/America/Bogota /etc/localtime
sudo apt-get update -y > /dev/null
sudo apt-get install -y tzdata > /dev/null
sudo dpkg-reconfigure --frontend noninteractive tzdata

# Update package list
sudo apt-get update -y
# sudo apt-get upgrade -y # Opcional

# Install common utilities
sudo apt-get install -y vim net-tools dnsutils curl wget ca-certificates ufw software-properties-common chrony # <-- AÑADIR chrony

# Configure hostname
echo "${HOSTNAME_FQDN}" | sudo tee /etc/hostname
SHORT_HOSTNAME=$(echo "${HOSTNAME_FQDN}" | cut -d. -f1)
sudo sed -i "/127.0.1.1/d" /etc/hosts
echo "127.0.1.1 ${HOSTNAME_FQDN} ${SHORT_HOSTNAME}" | sudo tee -a /etc/hosts

# Static IP assignment for the servers in /etc/hosts
sudo sed -i '/# Server IPs for project-plataformas1/,/# End Server IPs/d' /etc/hosts
cat <<EOF | sudo tee -a /etc/hosts
# Server IPs for project-plataformas1
192.168.56.10   ns1.${PRIMARY_DOMAIN} ns1
fd00:cafe:beef::10 ns1.${PRIMARY_DOMAIN} ns1
192.168.56.11   ns2.${PRIMARY_DOMAIN} ns2
fd00:cafe:beef::11 ns2.${PRIMARY_DOMAIN} ns2
192.168.56.12   mail.${PRIMARY_DOMAIN} mail
fd00:cafe:beef::12 mail.${PRIMARY_DOMAIN} mail
192.168.56.13   dhcp.${PRIMARY_DOMAIN} dhcp
fd00:cafe:beef::13 dhcp.${PRIMARY_DOMAIN} dhcp
# End Server IPs
EOF

# Detect private network interface
DETECTED_PRIVATE_INTERFACE=$(ip -4 addr show | grep -oP 'inet 192\.168\.56\.\d+/\d+.* brd \d+\.\d+\.\d+\.\d+ scope global \K[a-zA-Z0-9]+')
if [ -z "$DETECTED_PRIVATE_INTERFACE" ]; then
    echo "ERROR: Could not automatically detect the private network interface for 192.168.56.0/24."
    DETECTED_PRIVATE_INTERFACE=$(ip -o link show | awk -F': ' '$2 !~ /lo|vir|docker|veth|br-/{print $2; exit_status=NR; if(exit_status==2) exit}' | head -n1)
    if [ -z "$DETECTED_PRIVATE_INTERFACE" ]; then
        echo "ERROR: Fallback interface detection also failed. Exiting."
        exit 1
    fi
    echo "Warning: Using fallback interface detection. Detected: $DETECTED_PRIVATE_INTERFACE"
fi
echo "Detected private interface for IPv6 assignment: $DETECTED_PRIVATE_INTERFACE"

# Add IPv6 address
echo "Assigning IPv6 ${EXPECTED_IPV6_ADDRESS}/64 to ${DETECTED_PRIVATE_INTERFACE}"
sudo ip addr add "${EXPECTED_IPV6_ADDRESS}/64" dev "${DETECTED_PRIVATE_INTERFACE}"

# Persist IPv6 address using netplan
NETPLAN_FILE_PATH=""
if ls /etc/netplan/*vagrant*.yaml 1> /dev/null 2>&1; then
    NETPLAN_FILE_PATH=$(sudo ls /etc/netplan/*vagrant*.yaml | head -n 1)
elif ls /etc/netplan/*.yaml 1> /dev/null 2>&1; then
    NETPLAN_FILE_PATH=$(sudo ls /etc/netplan/*.yaml | head -n 1)
fi
if [ -n "$NETPLAN_FILE_PATH" ]; then
    echo "Attempting to modify Netplan file: $NETPLAN_FILE_PATH for interface $DETECTED_PRIVATE_INTERFACE"
    if sudo grep -qP "^\s*${DETECTED_PRIVATE_INTERFACE}:" "$NETPLAN_FILE_PATH"; then
        sudo sed -i "/^\s*${DETECTED_PRIVATE_INTERFACE}:/,/^\s*[a-zA-Z0-9]\+:/ { /${EXPECTED_IPV6_ADDRESS}\/64/d; }" "$NETPLAN_FILE_PATH" # Remove old entry
        if sudo awk "/^ *${DETECTED_PRIVATE_INTERFACE}:/,/^ *[a-zA-Z0-9]+:/" "$NETPLAN_FILE_PATH" | grep -q "addresses:"; then
            sudo sed -i "/^\s*${DETECTED_PRIVATE_INTERFACE}:/,/addresses:/s|\(addresses:\)|\1\n        - ${EXPECTED_IPV6_ADDRESS}/64|" "$NETPLAN_FILE_PATH"
        else
            sudo sed -i "/^\s*${DETECTED_PRIVATE_INTERFACE}:/a \      addresses:\n        - ${EXPECTED_IPV6_ADDRESS}/64" "$NETPLAN_FILE_PATH"
        fi
    else
        echo "Warning: Interface $DETECTED_PRIVATE_INTERFACE not found in $NETPLAN_FILE_PATH. Creating a new section."
        cat <<EOF | sudo tee -a "$NETPLAN_FILE_PATH"

    ${DETECTED_PRIVATE_INTERFACE}:
      addresses:
        - ${EXPECTED_IPV6_ADDRESS}/64
EOF
    fi
    echo "Applying netplan configuration..."
    sudo netplan apply
else
  echo "Warning: Could not find any .yaml Netplan config file in /etc/netplan/."
  echo "IPv6 address for ${DETECTED_PRIVATE_INTERFACE} will be temporary."
fi

# --- NTP Client Configuration (Chrony) ---
echo "Configuring NTP client (chrony)..."
# La instalación de chrony ya se hizo arriba
# chrony usa por defecto los servidores del pool de ubuntu.pool.ntp.org
# Verificar que esté activo y habilitado
sudo systemctl enable chrony
sudo systemctl start chrony
# Mostrar estado (opcional en script, más para depuración manual)
# chronyc sources
# chronyc tracking

# Basic UFW setup (allow SSH)
sudo ufw allow OpenSSH
# Si UFW bloquea NTP (puerto 123/udp), se necesitaría: sudo ufw allow 123/udp comment 'NTP'
# Pero como cliente, generalmente las reglas outbound son permitidas por defecto.
sudo ufw --force enable

echo "--- bootstrap.sh for ${HOSTNAME_FQDN} completed ---"