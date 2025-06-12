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
sudo cp "/vagrant/configs/dns-primary/named.conf.local" /etc/bind/

# Copiar archivos de zona renombrados
sudo cp "/vagrant/configs/dns-primary/db.${PRIMARY_DOMAIN}" "/etc/bind/db.${PRIMARY_DOMAIN}"
sudo cp "/vagrant/configs/dns-primary/db.168.192.in-addr.arpa" /etc/bind/
sudo cp "/vagrant/configs/dns-primary/db.f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa" /etc/bind/

# --- Directorios y Permisos para BIND y DNSSEC ---
# Crear directorios para las claves DNSSEC
sudo mkdir -p "/var/cache/bind/keys/${PRIMARY_DOMAIN}"
sudo mkdir -p "/var/cache/bind/keys/56.168.192.in-addr.arpa" # Para reversa IPv4
sudo mkdir -p "/var/cache/bind/keys/f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa" # Para reversa IPv6
sudo mkdir -p "/var/cache/bind/dynamic" # Para managed-keys (trust anchors)
sudo mkdir -p "/var/cache/bind/journals" # <--- NUEVO DIRECTORIO PARA JOURNALS

# Asignar propietario 'bind' y grupo 'bind'
sudo chown -R bind:bind "/var/cache/bind/keys/"
sudo chown -R bind:bind "/var/cache/bind/dynamic/"
sudo chown -R bind:bind "/var/cache/bind/journals/" # <--- DAR PERMISOS AL NUEVO DIRECTORIO

# Dar permisos adecuados (770 permite rwx para usuario y grupo, nada para otros)
sudo chmod -R 770 "/var/cache/bind/keys/"
sudo chmod -R 770 "/var/cache/bind/dynamic/"
sudo chmod -R 770 "/var/cache/bind/journals/" # <--- DAR PERMISOS AL NUEVO DIRECTORIO

# Dar permisos al grupo 'bind' para escribir en /etc/bind/ (para archivos .jnl)
sudo chgrp bind /etc/bind
sudo chmod g+w /etc/bind
# Asegurar que los archivos de zona copiados sean legibles por bind (generalmente ya lo son por umask)
sudo chmod 644 /etc/bind/db.* # rw-r--r-- (o 664 si el grupo bind necesita escribir en ellos, raro)

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
sudo systemctl status named.service # Es bueno tenerlo, pero el script seguirá aunque falle el status (set -e no lo captura así)

echo "--- DNS Primary Configured for ${PRIMARY_DOMAIN} ---"
echo "IMPORTANT: The TSIG key named '${TSIG_KEY_NAME}' with secret '${TSIG_KEY_SECRET}' must be used on the secondary DNS."
echo "--- DNSSEC Key Information ---"
echo "BIND will auto-generate DNSSEC keys. This may take a moment after the first start."
echo "Keys for ${PRIMARY_DOMAIN} will be in /var/cache/bind/keys/${PRIMARY_DOMAIN}/"
echo "To get the DS record for GoDaddy (use the KSK with flags: 257):"
KSK_DIR="/var/cache/bind/keys/${PRIMARY_DOMAIN}"
# Darle tiempo a BIND para que genere las claves puede requerir ejecutar esto manualmente después del primer aprovisionamiento.
# Esta sección informativa es para guiarte.
if [ -d "${KSK_DIR}" ]; then
    echo "  1. Wait ~1 minute, then list keys: sudo ls -l ${KSK_DIR}"
    echo "  2. Identify KSK (e.g., K${PRIMARY_DOMAIN}.+ALG+TAG.key, check for flags: 257 inside)"
    echo "  3. Generate DS: sudo dnssec-dsfromkey -f ${KSK_DIR}/<KSK_FILENAME.key> -a SHA-256"

    # Intento de mostrar comandos DS después de una breve espera (mejorado)
    echo "Attempting to find KSKs and suggest DS generation commands (may take a moment for keys to appear)..."
    sleep 20 # Aumentar un poco la espera
    FOUND_KSK=0
    for keyfile_path in $(sudo find "${KSK_DIR}" -maxdepth 1 -type f -name "K${PRIMARY_DOMAIN}*.key" 2>/dev/null); do
        if sudo grep -q "flags: 257" "$keyfile_path"; then
            FOUND_KSK=1
            key_alg_num=$(basename "$keyfile_path" | cut -d+ -f2)
            key_filename=$(basename "$keyfile_path")
            # Convertir algoritmo numérico a nombre de algoritmo digest para dnssec-dsfromkey
            # 8 (RSA/SHA-256) -> SHA-256 ; 13 (ECDSA/P256/SHA256) -> SHA-256
            # 14 (ECDSA/P384/SHA384) -> SHA-384 ; 10 (DSA/SHA-256) -> SHA-256
            DIGEST_ALG="SHA-256" # Por defecto para los algoritmos más comunes
            if [[ "$key_alg_num" == "014" ]]; then DIGEST_ALG="SHA-384"; fi

            echo "  Possible DS for key ${key_filename} (Algorithm Num ${key_alg_num}):"
            echo "    sudo dnssec-dsfromkey -f \"${KSK_DIR}/\" -a ${DIGEST_ALG} \"${key_filename}\""
        fi
    done
    if [ "$FOUND_KSK" -eq 0 ]; then
        echo "No KSK files found yet or error listing. Check directory ${KSK_DIR} manually after a few minutes."
    fi
else
    echo "Warning: Key directory ${KSK_DIR} not found."
fi