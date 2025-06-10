#!/bin/bash
set -eux # Exit on error, print commands

# Ahora solo esperamos 2 argumentos: IPv6 y Hostname
EXPECTED_IPV6_ADDRESS=$1 # e.g., fd00:cafe:beef::10
HOSTNAME_FQDN=$2         # e.g., dns-primary.example.com
# La IP IPv4 se obtiene del entorno de la VM que configura Vagrant

echo "--- Running bootstrap.sh for ${HOSTNAME_FQDN} ---"
echo "Target IPv6: ${EXPECTED_IPV6_ADDRESS}"

# Set Timezone to avoid prompts
export DEBIAN_FRONTEND=noninteractive
sudo ln -fs /usr/share/zoneinfo/America/Bogota /etc/localtime
sudo apt-get update -y > /dev/null
# Instalar tzdata explícitamente y luego reconfigurar sin prompt.
# Evitar error de "stdin: Not a typewriter" si apt-get lo hace interactivamente
sudo apt-get install -y tzdata > /dev/null
sudo dpkg-reconfigure --frontend noninteractive tzdata

# Update package list
sudo apt-get update -y
# sudo apt-get upgrade -y # Opcional, puede tomar tiempo

# Install common utilities
sudo apt-get install -y vim net-tools dnsutils curl wget ca-certificates ufw software-properties-common

# Configure hostname (Vagrant lo hace, esto es un refuerzo)
echo "${HOSTNAME_FQDN}" | sudo tee /etc/hostname
# Actualizar /etc/hosts con el nuevo hostname y eliminar cualquier entrada de 127.0.1.1 anterior
SHORT_HOSTNAME=$(echo "${HOSTNAME_FQDN}" | cut -d. -f1)
sudo sed -i "/127.0.1.1/d" /etc/hosts # Eliminar la linea antigua si existe
echo "127.0.1.1 ${HOSTNAME_FQDN} ${SHORT_HOSTNAME}" | sudo tee -a /etc/hosts


# Static IP assignment for the servers in /etc/hosts (se añade al final, evita duplicados por set -e)
# Primero removemos el bloque antiguo si existe, para evitar duplicados en reprovisionamientos
sudo sed -i '/# Server IPs for project-plataformas1/,/# End Server IPs/d' /etc/hosts
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
# End Server IPs
EOF

# Descubrir la interfaz de red privada (la que tiene la IP de Vagrant private_network)
# Asume que Vagrant ha configurado la IP IPv4 para la red privada.
# Esta expresion busca la interfaz que tiene una IP en el rango 192.168.56.x
DETECTED_PRIVATE_INTERFACE=$(ip -4 addr show | grep -oP 'inet 192\.168\.56\.\d+/\d+.* brd \d+\.\d+\.\d+\.\d+ scope global \K[a-zA-Z0-9]+')

if [ -z "$DETECTED_PRIVATE_INTERFACE" ]; then
    echo "ERROR: Could not automatically detect the private network interface for 192.168.56.0/24."
    # Fallback más genérico: la segunda interfaz ethernet activa después de lo.
    # Puede ser enp0s8, eth1, etc.
    DETECTED_PRIVATE_INTERFACE=$(ip -o link show | awk -F': ' '$2 !~ /lo|vir|docker|veth|br-/{print $2; exit_status=NR; if(exit_status==2) exit}' | head -n1) # Tomar la segunda no loopback
    if [ -z "$DETECTED_PRIVATE_INTERFACE" ]; then
        echo "ERROR: Fallback interface detection also failed. Exiting."
        exit 1
    fi
    echo "Warning: Using fallback interface detection. Detected: $DETECTED_PRIVATE_INTERFACE"
fi

echo "Detected private interface for IPv6 assignment: $DETECTED_PRIVATE_INTERFACE"
echo "Assigning IPv6 ${EXPECTED_IPV6_ADDRESS}/64 to ${DETECTED_PRIVATE_INTERFACE}"
sudo ip addr add "${EXPECTED_IPV6_ADDRESS}/64" dev "${DETECTED_PRIVATE_INTERFACE}"

# Persist IPv6 address using netplan
# Buscar el archivo de configuración de Netplan de Vagrant o uno por defecto
NETPLAN_FILE_PATH=""
if ls /etc/netplan/*vagrant*.yaml 1> /dev/null 2>&1; then
    NETPLAN_FILE_PATH=$(sudo ls /etc/netplan/*vagrant*.yaml | head -n 1)
elif ls /etc/netplan/*.yaml 1> /dev/null 2>&1; then
    # Tomar el primer yaml si no hay uno específico de vagrant (menos ideal)
    NETPLAN_FILE_PATH=$(sudo ls /etc/netplan/*.yaml | head -n 1)
fi

if [ -n "$NETPLAN_FILE_PATH" ]; then
    echo "Attempting to modify Netplan file: $NETPLAN_FILE_PATH for interface $DETECTED_PRIVATE_INTERFACE"
    # Comprobar si la interfaz ya está definida en el archivo netplan
    if sudo grep -qP "^\s*${DETECTED_PRIVATE_INTERFACE}:" "$NETPLAN_FILE_PATH"; then
        # La interfaz está definida, añadir la dirección IPv6
        # Eliminar cualquier configuración IPv6 anterior para esta IP para evitar duplicados
        sudo sed -i "/^\s*${DETECTED_PRIVATE_INTERFACE}:/,/^\s*[a-zA-Z0-9]\+:/ { /${EXPECTED_IPV6_ADDRESS}\/64/d; }" "$NETPLAN_FILE_PATH"

        # Comprobar si la clave 'addresses:' existe para esta interfaz
        if sudo awk "/^ *${DETECTED_PRIVATE_INTERFACE}:/,/^ *[a-zA-Z0-9]+:/" "$NETPLAN_FILE_PATH" | grep -q "addresses:"; then
            # 'addresses:' existe, añadir la IP
            sudo sed -i "/^\s*${DETECTED_PRIVATE_INTERFACE}:/,/addresses:/s|\(addresses:\)|\1\n        - ${EXPECTED_IPV6_ADDRESS}/64|" "$NETPLAN_FILE_PATH"
        else
            # 'addresses:' no existe, añadirla (debajo de dhcp4 o similar)
            sudo sed -i "/^\s*${DETECTED_PRIVATE_INTERFACE}:/a \      addresses:\n        - ${EXPECTED_IPV6_ADDRESS}/64" "$NETPLAN_FILE_PATH"
        fi
    else
        echo "Warning: Interface $DETECTED_PRIVATE_INTERFACE not found in $NETPLAN_FILE_PATH. Creating a new section."
        # Interfaz no definida, añadir una nueva sección para ella
        cat <<EOF | sudo tee -a "$NETPLAN_FILE_PATH"

    ${DETECTED_PRIVATE_INTERFACE}:
      # dhcp4: no # Vagrant gestiona la IPv4
      addresses:
        - ${EXPECTED_IPV6_ADDRESS}/64
EOF
    fi
    echo "Applying netplan configuration..."
    sudo netplan apply
else
  echo "Warning: Could not find any .yaml Netplan config file in /etc/netplan/."
  echo "IPv6 address for ${DETECTED_PRIVATE_INTERFACE} will be temporary."
  # Se podría crear un archivo nuevo aquí si es deseable, pero puede entrar en conflicto.
fi

# Basic UFW setup (allow SSH)
sudo ufw allow OpenSSH
sudo ufw --force enable # '--force' para no preguntar en scripts

echo "--- bootstrap.sh for ${HOSTNAME_FQDN} completed ---"