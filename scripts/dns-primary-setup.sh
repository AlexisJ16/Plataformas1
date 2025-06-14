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
sudo cp "/vagrant/configs/dns-primary/named.conf.local" /etc/bind/ # El que tiene inline-signing y journal

# Copiar archivos de zona (fuente)
sudo cp "/vagrant/configs/dns-primary/db.${PRIMARY_DOMAIN}" "/etc/bind/db.${PRIMARY_DOMAIN}"
sudo cp "/vagrant/configs/dns-primary/db.168.192.in-addr.arpa" /etc/bind/
sudo cp "/vagrant/configs/dns-primary/db.f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa" /etc/bind/

# --- Directorios y Permisos para BIND y DNSSEC ---
# Crear TODOS los directorios necesarios donde BIND escribirá
sudo mkdir -p "/var/cache/bind/keys/${PRIMARY_DOMAIN}"
sudo mkdir -p "/var/cache/bind/keys/56.168.192.in-addr.arpa"
sudo mkdir -p "/var/cache/bind/keys/f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa"
sudo mkdir -p "/var/cache/bind/dynamic"     # Para managed-keys (trust anchors)
sudo mkdir -p "/var/cache/bind/journals"    # Para los archivos .jnl

# Asignar propietario 'bind' y grupo 'bind' a TODO /var/cache/bind/
# La instalación de BIND ya debería hacer esto para /var/cache/bind, pero reafirmamos
# para nuestros subdirectorios.
sudo chown -R bind:bind "/var/cache/bind/"

# Dar permisos rwx al usuario 'bind' (propietario) y rx al grupo 'bind' para TODO /var/cache/bind/
# Esto asegura que BIND pueda leer, escribir y crear archivos/directorios donde lo necesite
# dentro de su directorio de trabajo principal y subdirectorios que hemos creado.
sudo chmod -R u+rwx,g+rx,o-rwx "/var/cache/bind/"

# Los archivos fuente en /etc/bind/ solo necesitan ser legibles por el usuario bind
sudo chmod 644 /etc/bind/db.* # rw-r--r-- para root, r-- para grupo, r-- para otros. bind lee como 'otros' o miembro del grupo si 'bind' es grupo del archivo.

# Update resolv.conf
echo "search ${PRIMARY_DOMAIN}" | sudo tee /etc/resolv.conf
echo "nameserver 127.0.0.1" | sudo tee -a /etc/resolv.conf
echo "nameserver ${PRIMARY_DNS_IPV6}" | sudo tee -a /etc/resolv.conf
echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf

# Check configuration
sudo named-checkconf # Esperamos que pase sin el error de 'auto-dnssec maintain'
# Si hay problemas aquí, el script fallará (set -e)

# Solo si named-checkconf pasa, procedemos a verificar las zonas.
echo "named-checkconf passed. Checking zones..."
sudo named-checkzone "${PRIMARY_DOMAIN}" "/etc/bind/db.${PRIMARY_DOMAIN}"
sudo named-checkzone "56.168.192.in-addr.arpa" "/etc/bind/db.168.192.in-addr.arpa"
# Nombre de zona con punto final para checkzone de reversa IPv6
sudo named-checkzone "f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa." "/etc/bind/db.f.e.e.b.e.f.a.c.0.0.d.f.ip6.arpa"

# Firewall
sudo ufw allow 53/tcp comment 'DNS TCP'
sudo ufw allow 53/udp comment 'DNS UDP'
sudo ufw reload

# Usar 'named.service' directamente
sudo systemctl restart named.service
sudo systemctl enable named.service
sudo systemctl status named.service # Ver el estado, el script continúa incluso si hay un error de 'Active: failed' aquí

echo "--- DNS Primary Configured for ${PRIMARY_DOMAIN} ---"
echo "IMPORTANTe TSIG key... (resto del mensaje igual)"
# ... (Sección informativa de DNSSEC Key) ...
# La lógica de `sleep` y `find` para las claves KSK al final está bien.
echo "--- DNSSEC Key Information ---"
echo "BIND will auto-generate DNSSEC keys and signed zone files."
echo "Keys for ${PRIMARY_DOMAIN} will be in /var/cache/bind/keys/${PRIMARY_DOMAIN}/"
echo "Journal files will be in /var/cache/bind/journals/"
echo "To get the DS record for GoDaddy (use the KSK with flags: 257):"
KSK_DIR="/var/cache/bind/keys/${PRIMARY_DOMAIN}"
if [ -d "${KSK_DIR}" ]; then
    echo "  1. Wait ~1 minute, then list keys: sudo ls -l ${KSK_DIR}"
    echo "  2. Identify KSK (e.g., K${PRIMARY_DOMAIN}.+ALG+TAG.key, check for flags: 257 inside)"
    echo "  3. Generate DS: sudo dnssec-dsfromkey -f ${KSK_DIR}/<KSK_FILENAME.key> -a SHA-256"
    echo "Attempting to find KSKs and suggest DS generation commands (may take a moment for keys to appear)..."
    sleep 25 # Damos un poco más de tiempo
    FOUND_KSK=0
    for keyfile_path in $(sudo find "${KSK_DIR}" -maxdepth 1 -type f -name "K${PRIMARY_DOMAIN}*.key" 2>/dev/null); do
        if sudo grep -q "flags: 257" "$keyfile_path"; then
            FOUND_KSK=1; key_alg_num=$(basename "$keyfile_path" | cut -d+ -f2); key_filename=$(basename "$keyfile_path")
            DIGEST_ALG="SHA-256"; if [[ "$key_alg_num" == "014" ]]; then DIGEST_ALG="SHA-384"; fi
            echo "  Possible DS for key ${key_filename} (Alg Num ${key_alg_num}): sudo dnssec-dsfromkey -f \"${KSK_DIR}/\" -a ${DIGEST_ALG} \"${key_filename}\""
        fi
    done
    if [ "$FOUND_KSK" -eq 0 ]; then echo "No KSK files found yet. Check ${KSK_DIR} manually after BIND has run for a few minutes."; fi
else
    echo "Warning: Key directory ${KSK_DIR} not found immediately after BIND start. Check BIND logs for errors."; fi