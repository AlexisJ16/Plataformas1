#!/bin/bash
set -eux

echo "--- Configuring DNS Primary ---"
PRIMARY_DOMAIN="grindavik.xyz" # Usar el nuevo dominio

PRIMARY_DNS_IPV4="192.168.56.10"
PRIMARY_DNS_IPV6="fd00:cafe:beef::10"
# ... otras IPs si las necesitas referenciar aquí

TSIG_KEY_NAME="transfer-key"
TSIG_KEY_SECRET="vPhK2lMEVBEwGfdeI8too1rFH1LU7M2y11MnTXGo8oU=" # ¡CONFIRMA QUE ES TU CLAVE GENERADA!

sudo apt-get update -y
sudo apt-get install -y bind9 bind9utils bind9-doc # bind9utils incluye dnssec-tools

# === Prepare configuration files ===
sudo cp "/vagrant/configs/dns-primary/named.conf.options" /etc/bind/
sudo cp "/vagrant/configs/dns-primary/named.conf.local" /etc/bind/ # Este ya debe estar para grindavik.xyz y DNSSEC

# Copiar archivos de zona renombrados
sudo cp "/vagrant/configs/dns-primary/db.${PRIMARY_DOMAIN}" "/etc/bind/db.${PRIMARY_DOMAIN}"
sudo cp /vagrant/configs/dns-primary/db.168.192.in-addr.arpa /etc/bind/
sudo cp /vagrant/configs/dns-primary/db.f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa /etc/bind/

# --- Crear directorios para las claves DNSSEC (y para dynamic keys de managed-keys) ---
sudo mkdir -p "/var/cache/bind/keys/${PRIMARY_DOMAIN}"
sudo mkdir -p "/var/cache/bind/dynamic" # Para managed-keys si se configura explícitamente

sudo chown -R bind:bind "/var/cache/bind/keys/"
sudo chown -R bind:bind "/var/cache/bind/dynamic/" # Dar permisos

sudo chmod -R 770 "/var/cache/bind/keys/"
sudo chmod -R 770 "/var/cache/bind/dynamic/"


# Update resolv.conf
echo "search ${PRIMARY_DOMAIN}" | sudo tee /etc/resolv.conf # Añadir search domain
echo "nameserver 127.0.0.1" | sudo tee -a /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV6}" | sudo tee -a /etc/resolv.conf # DNS primario IPv6
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf # Fallback

# Check configuration
sudo named-checkconf
# Usa variables para los nombres de archivo y zona
sudo named-checkzone "${PRIMARY_DOMAIN}" "/etc/bind/db.${PRIMARY_DOMAIN}"
sudo named-checkzone "56.168.192.in-addr.arpa" "/etc/bind/db.168.192.in-addr.arpa"
sudo named-checkzone "f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa" "/etc/bind/db.f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa"

# Firewall
sudo ufw allow 53/tcp comment 'DNS TCP'
sudo ufw allow 53/udp comment 'DNS UDP'
sudo ufw reload

# Usar 'named.service' directamente
sudo systemctl restart named.service
sudo systemctl enable named.service
sudo systemctl status named.service

echo "--- DNS Primary Configured for ${PRIMARY_DOMAIN} ---"
echo "IMPORTANT: The TSIG key named '${TSIG_KEY_NAME}' with secret '${TSIG_KEY_SECRET}' must be used on the secondary DNS."
echo "--- DNSSEC Key Information ---"
echo "BIND will auto-generate DNSSEC keys. This may take a moment after the first start."
echo "Keys for ${PRIMARY_DOMAIN} will be in /var/cache/bind/keys/${PRIMARY_DOMAIN}/"
echo "To get the DS record for GoDaddy (use the KSK with flags: 257):"
KSK_DIR="/var/cache/bind/keys/${PRIMARY_DOMAIN}"
echo "  1. Wait a minute for keys to generate, then list them: sudo ls -l ${KSK_DIR}"
echo "  2. Identify the KSK file (e.g., K${PRIMARY_DOMAIN}.+ALG+TAG.key where flags=257 inside)"
echo "  3. Generate DS: sudo dnssec-dsfromkey -f ${KSK_DIR}/<KSK_FILENAME.key> -a SHA-256 (or other alg as needed)"
# Pequeño script para intentar encontrar y mostrar el comando DS para KSKs SHA-256 (alg 8 o 13)
# Esto es informativo, la generación de claves es asíncrona por BIND.
# Darle tiempo a BIND para que genere las claves puede requerir ejecutar esto manualmente después.
sleep 15 # Espera 15 segundos a que BIND pueda generar las claves
echo "Possible KSK DS record generation commands (SHA-256 based algorithms):"
for keyfile_path in $(sudo find "${KSK_DIR}" -type f -name "K${PRIMARY_DOMAIN}*.key" 2>/dev/null); do
    if sudo grep -q "flags: 257" "$keyfile_path"; then # KSK tienen flag 257
        key_alg=$(basename "$keyfile_path" | cut -d+ -f2) # Extrae el algoritmo de Knombre.+ALG+tag.key
        if [[ "$key_alg" == "008" || "$key_alg" == "013" ]]; then # RSA/SHA256 (8) o ECDSA/P256/SHA256 (13)
            echo "  For key $(basename "$keyfile_path") (Algorithm $key_alg):"
            echo "    sudo dnssec-dsfromkey -f \"${KSK_DIR}/\" -a SHA-256 \"$(basename "$keyfile_path")\""
        fi
    fi
done || echo "No KSK files found or error listing. Check directory ${KSK_DIR} manually."