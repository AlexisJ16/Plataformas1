#!/bin/bash
set -eux

echo "--- Configuring DNS Primary ---"
PRIMARY_DOMAIN="grindavik.xyz" # Usar el nuevo dominio

PRIMARY_DNS_IPV4="192.168.56.10"
PRIMARY_DNS_IPV6="fd00:cafe:beef::10"

TSIG_KEY_NAME="transfer-key"
TSIG_KEY_SECRET="vPhK2lMEVBEwGfdeI8too1rFH1LU7M2y11MnTXGo8oU=" # CONFIRMA TU CLAVE GENERADA

sudo apt-get update -y
sudo apt-get install -y bind9 bind9utils bind9-doc # bind9utils incluye dnssec-tools

# === Prepare configuration files ===
sudo cp "/vagrant/configs/dns-primary/named.conf.options" /etc/bind/
# El named.conf.local copiado ahora tiene auto-dnssec maintain SIN inline-signing ni journal
sudo cp "/vagrant/configs/dns-primary/named.conf.local" /etc/bind/

# Copiar archivos de zona (estos son los archivos fuente, no firmados)
sudo cp "/vagrant/configs/dns-primary/db.${PRIMARY_DOMAIN}" "/etc/bind/db.${PRIMARY_DOMAIN}"
sudo cp "/vagrant/configs/dns-primary/db.168.192.in-addr.arpa" /etc/bind/
sudo cp "/vagrant/configs/dns-primary/db.f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa" /etc/bind/

# --- Directorios y Permisos para BIND y DNSSEC ---
# BIND necesita escribir en su 'directory' (definido como /var/cache/bind en named.conf.options)
# para gestionar las claves, las zonas firmadas dinámicas, y los archivos de managed-keys.
# El paquete de instalación de BIND ya debería configurar los permisos de /var/cache/bind para el usuario 'bind'.
# Vamos a asegurarnos de crear los subdirectorios y reafirmar permisos por si acaso.

sudo mkdir -p "/var/cache/bind/keys/${PRIMARY_DOMAIN}"
sudo mkdir -p "/var/cache/bind/keys/56.168.192.in-addr.arpa"
sudo mkdir -p "/var/cache/bind/keys/f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa"
sudo mkdir -p "/var/cache/bind/dynamic" # Para managed-keys

# El directorio principal /var/cache/bind/ es donde BIND almacenará
# las versiones firmadas (.signed) y sus journals (.jnl) si no se especifica 'inline-signing'.
# Es crucial que el usuario 'bind' tenga control aquí.
# La instalación de BIND generalmente crea /var/cache/bind con propietario bind:bind y permisos adecuados.
# Por si acaso, aseguramos que el usuario 'bind' es el propietario de todo bajo /var/cache/bind
sudo chown -R bind:bind "/var/cache/bind/"
sudo chmod -R u+rwx,g+rx,o-rwx "/var/cache/bind/" # Propietario:rwx, Grupo:rx, Otros:nada (típico para BIND)

# Los archivos fuente en /etc/bind/ SOLO necesitan ser legibles por BIND.
# No intentaremos que BIND escriba aquí (se quitó 'inline-signing' de la zona).
sudo chmod 644 /etc/bind/db.* # rw-r--r--

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
echo "BIND will auto-generate DNSSEC keys and signed zone files (e.g., .signed) in /var/cache/bind/ (or its subdirs)."
echo "Keys for ${PRIMARY_DOMAIN} will be in /var/cache/bind/keys/${PRIMARY_DOMAIN}/"
echo "To get the DS record for GoDaddy (use the KSK with flags: 257):"
KSK_DIR="/var/cache/bind/keys/${PRIMARY_DOMAIN}"
if [ -d "${KSK_DIR}" ]; then
    echo "  1. Wait ~1 minute, then list keys: sudo ls -l ${KSK_DIR}"
    echo "  2. Identify KSK (e.g., K${PRIMARY_DOMAIN}.+ALG+TAG.key, check for flags: 257 inside)"
    echo "  3. Generate DS: sudo dnssec-dsfromkey -f ${KSK_DIR}/<KSK_FILENAME.key> -a SHA-256"
    echo "Attempting to find KSKs and suggest DS generation commands (may take a moment for keys to appear)..."
    sleep 20
    FOUND_KSK=0
    for keyfile_path in $(sudo find "${KSK_DIR}" -maxdepth 1 -type f -name "K${PRIMARY_DOMAIN}*.key" 2>/dev/null); do
        if sudo grep -q "flags: 257" "$keyfile_path"; then
            FOUND_KSK=1
            key_alg_num=$(basename "$keyfile_path" | cut -d+ -f2)
            key_filename=$(basename "$keyfile_path")
            DIGEST_ALG="SHA-256"
            if [[ "$key_alg_num" == "014" ]]; then DIGEST_ALG="SHA-384"; fi
            echo "  Possible DS for key ${key_filename} (Algorithm Num ${key_alg_num}):"
            echo "    sudo dnssec-dsfromkey -f \"${KSK_DIR}/\" -a ${DIGEST_ALG} \"${key_filename}\""
        fi
    done
    if [ "$FOUND_KSK" -eq 0 ]; then
        echo "No KSK files found yet. Check ${KSK_DIR} manually after a few minutes, BIND generates them in background."
    fi
else
    echo "Warning: Key directory ${KSK_DIR} not found immediately after BIND start."
fi